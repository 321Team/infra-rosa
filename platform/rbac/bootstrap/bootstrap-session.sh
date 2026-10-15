#!/usr/bin/env bash
# infra-rosa#5 — 임시 cluster-admin bootstrap 회차 래퍼 (첫 설정 순서 v3 §3)
#
# 하는 일: grant → (단계 파일 실행) → 항상 revoke → 회수 확인 → 종료 코드 결정.
#   - 성공·단계 실패·취소(INT)·종료 신호(TERM)·마감시각 초과 모두 같은 cleanup 하나로 끝난다.
#   - 취소/실패 뒤에는 다음 단계를 실행하지 않는다.
#   - revoke 실패나 회수 확인 실패·시간 초과면 최종 rc=1, CLEANUP_REQUIRED.
#
# 쓰는 법:
#   CLUSTER_ID=<id> API_URL=<url> DEADLINE_EPOCH=$(date -d '+90 min' +%s) \
#     ./bootstrap-session.sh steps.sh
#   steps.sh 는 run_steps 함수를 정의한다(각 단계 명령). 이 파일은 단계 내용과 분리한다.
#
# 보장 밖: SIGKILL·CloudShell 세션 통째 유실은 trap이 못 잡는다 → 두 번째 관리 세션에서 수동 revoke.
# 비밀: 비밀번호·token 원문을 인자·로그에 쓰지 않는다. WORKDIR 은 umask 077 / 700.
set -Eeuo pipefail

: "${CLUSTER_ID:?CLUSTER_ID required}"
: "${API_URL:?API_URL required}"
: "${DEADLINE_EPOCH:?DEADLINE_EPOCH required}"
U="${U:-hayeoung}"
WORKDIR="${WORKDIR:-$HOME/rosa-idp}"
VERIFY_TRIES="${VERIFY_TRIES:-10}"      # 회수 수렴 읽기 확인 횟수 (읽기 전용 대기, 쓰기 유예 아님)
VERIFY_INTERVAL="${VERIFY_INTERVAL:-60}" # 초
STEPS_FILE="${1:?usage: bootstrap-session.sh <steps.sh>}"
# `rosa list users` 표 머리글 정규식. **실제 ROSA CLI 1.2.53 출력으로 확정 전에는 실행본 아님.**
# 머리글이 맞지 않으면(형식 불명) 빈 매칭을 '부재'로 보지 않고 UNKNOWN 으로 처리한다.
ROSA_USERS_HEADER_RE="${ROSA_USERS_HEADER_RE:-^ID[[:space:]]+GROUPS[[:space:]]*$}"

umask 077
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
# 전용 kubeconfig: 기존(Shared OCP 등) context 를 건드리지 않는다.
# cleanup 에서 지우지 않는다 — 회수 전 세션으로 D-11b 를 수동 판정한 뒤 정리한다.
export KUBECONFIG="$WORKDIR/kubeconfig"

grant_attempted=0
watchdog_pid=""

log() { printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >&2; }

# 관리면 grant 확인 → 표준출력: ABSENT | PRESENT | UNKNOWN
#   ABSENT 는 rc0 + 머리글 형식 일치 + 대상 사용자 행에 cluster-admin 이 없을 때만.
check_mgmt_grant() {
  local out="$WORKDIR/verify-users.$1.out" err="$WORKDIR/verify-users.$1.err" rc=0
  rosa list users -c "$CLUSTER_ID" >"$out" 2>"$err" || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "MGMT_QUERY_FAILED rc=$rc"; echo UNKNOWN; return
  fi
  if ! head -n 1 "$out" | grep -Eq "$ROSA_USERS_HEADER_RE"; then
    log "MGMT_FORMAT_UNKNOWN (머리글 불일치)"; echo UNKNOWN; return
  fi
  if tail -n +2 "$out" | awk -v u="$U" '$1 == u' | grep -q 'cluster-admin'; then
    echo PRESENT
  else
    echo ABSENT
  fi
}

# 회수 전 세션의 SSAR → 표준출력: NO | YES | UNKNOWN
#   NO 는 rc1 + stdout 정확히 "no" + stderr 비어 있음일 때만. 오류·timeout·401 은 UNKNOWN(→ D-11a/b 수동 판정).
check_session_cani() {
  local out="$WORKDIR/verify-cani.$1.out" err="$WORKDIR/verify-cani.$1.err" rc=0
  oc auth can-i '*' '*' --all-namespaces >"$out" 2>"$err" || rc=$?
  if [[ $rc -eq 1 && "$(cat "$out")" == no && ! -s "$err" ]]; then
    echo NO
  elif [[ $rc -eq 0 && "$(cat "$out")" == yes ]]; then
    echo YES
  else
    log "SESSION_QUERY_UNKNOWN rc=$rc"; echo UNKNOWN
  fi
}

# 회수 확인(읽기 전용 수렴 대기). 둘 다 ABSENT/NO 일 때만 성공. 마지막 상태가 UNKNOWN 이면 그 사실을 남긴다.
verify_revoked() {
  local i m s
  for ((i = 1; i <= VERIFY_TRIES; i++)); do
    m=$(check_mgmt_grant "$i"); s=$(check_session_cani "$i")
    if [[ "$m" == ABSENT && "$s" == NO ]]; then
      log "VERIFY_OK try=$i mgmt=$m session=$s"
      return 0
    fi
    log "VERIFY_PENDING try=$i/$VERIFY_TRIES mgmt=$m session=$s"
    ((i < VERIFY_TRIES)) && sleep "$VERIFY_INTERVAL"
  done
  log "VERIFY_FINAL mgmt=$m session=$s"
  return 1
}

cleanup() {
  local rc=$?
  trap - EXIT ERR
  # 회수 중 Ctrl+C·TERM 은 무시한다(PR#37 이재환 리뷰 #1). 무시 상태는 자식(rosa/oc)에게도 상속되어
  # revoke·회수 확인이 끝까지 간다. 강제 종료(kill -9)·세션 유실은 막을 수 없으므로 두 번째 관리 세션에서 수동 revoke.
  trap '' INT TERM
  [[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null || true
  log "CLEANUP_START rc=$rc grant_attempted=$grant_attempted (회수 중 Ctrl+C 무시 — 멈춰야 하면 두 번째 관리 세션에서 수동 revoke)"
  if [[ "$grant_attempted" == 1 ]]; then
    if rosa revoke user cluster-admin --user "$U" -c "$CLUSTER_ID" -y; then
      log "REVOKE_CMD_OK"
      if verify_revoked; then
        log "REVOKE_VERIFIED"
      else
        log "CLEANUP_REQUIRED: 회수 확인 실패/시간 초과"
        rc=1
      fi
    else
      log "CLEANUP_REQUIRED: revoke 명령 실패"
      rc=1
    fi
  fi
  # SA token 원문(t)과 SA 전용 kubeconfig 는 성공·실패와 관계없이 항상 지운다(PR#40 보완 1).
  # 하영 세션 kubeconfig 는 남긴다 — post-revoke-check.sh 의 D-11b(회수 전 세션) 판정 뒤 그 스크립트가 지운다.
  if ! rm -f -- "$WORKDIR/t" "$WORKDIR/sa.kubeconfig"; then
    log "CLEANUP_REQUIRED: token 임시 파일 삭제 실패"
    rc=1
  fi
  if [[ -e "$WORKDIR/t" || -e "$WORKDIR/sa.kubeconfig" ]]; then
    log "CLEANUP_REQUIRED: token 임시 파일이 남아 있음"
    rc=1
  fi
  # 회수 성공이어도 원래 실패/취소 rc 는 보존한다(0 으로 덮지 않음).
  log "CLEANUP_END final_rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 대상 결속: 현재 oc 세션 server 가 승인 API URL 과 같아야 한다(로그인은 grant 뒤 단계 파일에서).
now=$(date +%s)
if ((now >= DEADLINE_EPOCH)); then
  log "STOP: 마감시각이 이미 지남"
  exit 124
fi

# 마감시각 watchdog: 단계 실행 중이어도 TERM 으로 끊고 cleanup 으로 간다.
# - 출력 fd 를 /dev/null 로 돌려 `| tee` 파이프를 붙잡지 않게 한다(붙잡으면 마감시각까지 종료 지연).
# - cleanup 이 watchdog 를 TERM 하면 자기 sleep 자식도 같이 끝낸다(고아 sleep 방지).
# - bash 는 foreground 명령이 끝난 뒤 trap 을 처리하므로, 오래 걸리는 단일 명령은 그 명령이 끝난 뒤 끊긴다.
(
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  sleep $((DEADLINE_EPOCH - now)) & s=$!
  wait "$s"
  echo "DEADLINE_REACHED $(date '+%F %T %Z')" >"$WORKDIR/deadline.txt"
  kill -TERM $$
) </dev/null >/dev/null 2>&1 &
watchdog_pid=$!

# shellcheck source=/dev/null
source "$STEPS_FILE"
declare -F run_steps >/dev/null || { log "STOP: run_steps 없음"; exit 2; }

# 첫 권한 쓰기 전에 ROSA 관리면의 ID/API 대응을 읽기 전용으로 확인한다.
if ! rosa describe cluster -c "$CLUSTER_ID" -o json >"$WORKDIR/preflight-cluster.json"; then
  log "STOP: CLUSTER_ID 조회 실패"; exit 1
fi
if ! actual_api=$(jq -er '.api.url | select(type == "string" and length > 0)' "$WORKDIR/preflight-cluster.json"); then
  log "STOP: CLUSTER_ID 의 API URL 판독 실패"; exit 1
fi
[[ "$actual_api" == "$API_URL" ]] || { log "STOP: CLUSTER_ID 의 API URL 불일치"; exit 1; }

grant_attempted=1   # 응답 유실·부분 성공도 회수 대상으로 보기 위해 grant 호출 '전에' 표시
log "GRANT_START user=$U cluster=$CLUSTER_ID"
rosa grant user cluster-admin --user "$U" -c "$CLUSTER_ID"
log "GRANT_OK"

run_steps
log "STEPS_DONE"
exit 0
