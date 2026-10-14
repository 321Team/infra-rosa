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

umask 077
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"

grant_attempted=0
watchdog_pid=""

log() { printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >&2; }

# 회수 확인: (1) 관리면 grant 기록 없음 (2) 현재 세션 SSAR 에서 '*' '*' 가 no (또는 세션 무효)
verify_revoked() {
  local i
  for ((i = 1; i <= VERIFY_TRIES; i++)); do
    if ! rosa list users -c "$CLUSTER_ID" | awk -v u="$U" '$1 == u' | grep -q 'cluster-admin'; then
      if ! oc auth can-i '*' '*' --all-namespaces -q >/dev/null 2>&1; then
        log "VERIFY_OK try=$i (관리면 grant 없음, SSAR '*' '*' = no)"
        return 0
      fi
    fi
    log "VERIFY_PENDING try=$i/$VERIFY_TRIES"
    ((i < VERIFY_TRIES)) && sleep "$VERIFY_INTERVAL"
  done
  return 1
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM ERR
  [[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null || true
  log "CLEANUP_START rc=$rc grant_attempted=$grant_attempted"
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
  if ! rm -f -- "$WORKDIR/t"; then
    log "CLEANUP_REQUIRED: token 임시 파일 삭제 실패"
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

grant_attempted=1   # 응답 유실·부분 성공도 회수 대상으로 보기 위해 grant 호출 '전에' 표시
log "GRANT_START user=$U cluster=$CLUSTER_ID"
rosa grant user cluster-admin --user "$U" -c "$CLUSTER_ID"
log "GRANT_OK"

run_steps
log "STEPS_DONE"
exit 0
