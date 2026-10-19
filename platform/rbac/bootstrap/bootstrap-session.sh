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
# 본문 각 행의 형식(PR#40 리뷰 R5). 머리글이 맞아도 본문 한 행이라도 이 형식이 아니면 UNKNOWN(부재로 승격하지 않음).
# [AFTER-CREATE] 실제 `rosa list users` 행 형식·그룹 이름으로 확정.
ROSA_USERS_ROW_RE="${ROSA_USERS_ROW_RE:-^[a-z0-9][a-z0-9._@-]*[[:space:]]+(cluster-admins|dedicated-admins)(,(cluster-admins|dedicated-admins))*[[:space:]]*$}"
# 빈 목록 출력(#5 A단계 실측, fds-rosa-hcp, 2026-10-18): 머리글 없이 stdout 에 아래 1줄만 나오고 rc0.
#   INFO: There are no users configured for cluster '<CLUSTER_ID>'
# rc0 + stderr 비어 있음 + stdout 정확히 이 1줄(이 회차 CLUSTER_ID)일 때만 부재로 본다. 다른 ID·추가 줄·stderr 는 UNKNOWN.
ROSA_USERS_EMPTY_LINE="INFO: There are no users configured for cluster '$CLUSTER_ID'"
users_list_empty() { # out err
  [[ ! -s "$2" && "$(wc -l <"$1")" -eq 1 && "$(<"$1")" == "$ROSA_USERS_EMPTY_LINE" ]]
}

umask 077
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
# 전용 kubeconfig: 기존(Shared OCP 등) context 를 건드리지 않는다.
# cleanup 에서 지우지 않는다 — 회수 전 세션으로 D-11b 를 수동 판정한 뒤 정리한다.
export KUBECONFIG="$WORKDIR/kubeconfig"

grant_attempted=0
watchdog_pid=""

# 화면(stderr)과 별도로 $WORKDIR/session-events.log 에도 남긴다. 화면 쪽 파이프(| tee)가 끊겨도
# 기록이 남고, 쓰기 실패가 래퍼를 멈추지 않는다(#5 2회차 6262238397: tee 종료 뒤 SIGPIPE 로 회수 전에 죽음).
log() {
  local line
  line=$(printf '[%s] %s' "$(date '+%F %T %Z')" "$*")
  printf '%s\n' "$line" >>"$WORKDIR/session-events.log" 2>/dev/null || true
  printf '%s\n' "$line" >&2 2>/dev/null || true
}

# 관리면 grant 확인 → 표준출력: ABSENT | PRESENT | UNKNOWN
#   ABSENT 는 rc0 + (실측 빈 목록 1줄 | 머리글 형식 일치 + 대상 사용자 행에 cluster-admin 없음)일 때만.
check_mgmt_grant() {
  local out="$WORKDIR/verify-users.$1.out" err="$WORKDIR/verify-users.$1.err" rc=0
  rosa list users -c "$CLUSTER_ID" >"$out" 2>"$err" || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "MGMT_QUERY_FAILED rc=$rc"; echo UNKNOWN; return
  fi
  if users_list_empty "$out" "$err"; then
    echo ABSENT; return
  fi
  if ! head -n 1 "$out" | grep -Eq "$ROSA_USERS_HEADER_RE"; then
    log "MGMT_FORMAT_UNKNOWN (머리글 불일치)"; echo UNKNOWN; return
  fi
  # 본문 전 행 형식 검사 — 깨진 본문(예: 오류 HTML)이나 그룹 없는 행은 UNKNOWN
  if ! tail -n +2 "$out" | awk -v re="$ROSA_USERS_ROW_RE" 'NF == 0 { next } $0 !~ re { bad = 1 } END { exit bad }'; then
    log "MGMT_FORMAT_UNKNOWN (본문 행 형식 불일치)"; echo UNKNOWN; return
  fi
  # 대상 사용자 행의 그룹 목록에 cluster-admins 가 정확히 있는지(부분 문자열 아님)
  if tail -n +2 "$out" | awk -v u="$U" '$1 == u { n = split($2, g, ","); for (i = 1; i <= n; i++) if (g[i] == "cluster-admins") f = 1 } END { exit !f }'; then
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

# 기록 파일 open 실패가 revoke 호출을 막지 않게 한다(PR#44 리뷰 5568617943 R1, 이권욱 제시안).
# `cmd >file` 은 셸이 file 을 열지 못하면 cmd 를 실행하지 않는다. open 은 한 번만 하고, 실패하면 출력을 버리고 revoke 는 그대로 호출한다.
revoke_log_failed=0
revoke_safely() {
  local outfd errfd rr=0
  if { exec {outfd}>"$WORKDIR/revoke.out"; } 2>/dev/null &&
     { exec {errfd}>"$WORKDIR/revoke.err"; } 2>/dev/null; then
    rosa revoke user cluster-admin --user "$U" -c "$CLUSTER_ID" -y </dev/null >&"$outfd" 2>&"$errfd" || rr=$?
  else
    revoke_log_failed=1
    log "REVOKE_LOG_FAILED: 기록 파일 open 실패 — revoke 는 계속"
    rosa revoke user cluster-admin --user "$U" -c "$CLUSTER_ID" -y </dev/null >/dev/null 2>&1 || rr=$?
  fi
  [[ -n "${outfd:-}" ]] && exec {outfd}>&-
  [[ -n "${errfd:-}" ]] && exec {errfd}>&-
  return "$rr"
}

cleanup() {
  local rc=$?
  trap - EXIT ERR
  # 회수 경로에서는 errexit 를 끈다 — 로그 쓰기 같은 부수 실패로 revoke 전에 빠져나가지 않게(각 단계는 아래에서 rc 를 직접 검사).
  set +eE
  # 회수 중 Ctrl+C·TERM 은 무시한다(PR#37 이재환 리뷰 #1). 무시 상태는 자식(rosa/oc)에게도 상속되어
  # revoke·회수 확인이 끝까지 간다. 강제 종료(kill -9)·세션 유실은 막을 수 없으므로 두 번째 관리 세션에서 수동 revoke.
  # PIPE: 화면 파이프(tee)가 끊겨도 SIGPIPE 로 죽지 않고 쓰기 실패로만 처리한다(#5 2회차 원인).
  trap '' INT TERM PIPE
  [[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null || true
  log "CLEANUP_START rc=$rc grant_attempted=$grant_attempted (회수 중 Ctrl+C 무시 — 멈춰야 하면 두 번째 관리 세션에서 수동 revoke)"
  local verified=0
  if [[ "$grant_attempted" == 1 ]]; then
    # 출력은 파일로 받는다 — 화면 파이프 상태와 무관하게 revoke 가 끝까지 실행되도록.
    if revoke_safely; then
      log "REVOKE_CMD_OK"
      if verify_revoked; then
        log "REVOKE_VERIFIED"; verified=1
      else
        log "CLEANUP_REQUIRED: 회수 확인 실패/시간 초과"
        rc=1
      fi
    else
      log "CLEANUP_REQUIRED: revoke 명령 실패"
      rc=1
    fi
    # 회수는 했어도 revoke 원문이 없으면 증적이 불완전하다 → 완료로 판정하지 않는다(rc1, receipt 미발행)
    if [[ $revoke_log_failed == 1 ]]; then log "REVOKE_LOG_FAILED — 회수 원문 없음, 완료로 보지 않음"; rc=1; fi
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
  # 회수 판정·대상 결속 원본을 증적 폴더로 복사(PR#43 리뷰 S3). 성공·실패 회차 모두 — 실패 조사에도 필요하다.
  #   verify-users.N.{out,err}  관리면 ABSENT 판정 원문(REVOKE_VERIFIED 의 직접 근거)
  #   verify-cani.N.{out,err}   회수 전 세션 SSAR 원문
  #   preflight-cluster.json    grant 전 Cluster ID↔API 결속·external_id 근거
  # 복사가 실패하면 증적이 불완전하므로 완료로 보고하지 않는다(rc=1, receipt 미발행).
  if [[ -n "${EV:-}" && -d "${EV:-/nonexistent}" ]]; then
    if ! copy_revoke_evidence; then log "EVIDENCE_COPY_FAILED — 회수 판정 원본 복사 실패"; rc=1; fi
  fi
  # 완료 receipt(PR#40 리뷰 R3): 회수 확인 + 단계 정상(rc0) 또는 정책 승인 대기(rc3)일 때만 발행.
  # post-revoke-check.sh 는 이 receipt 가 없거나 값·해시가 다르면 판정 전에 STOP 한다. token 원문은 넣지 않는다.
  if [[ $verified == 1 && ( $rc == 0 || $rc == 3 ) && -n "${EV:-}" && -d "${EV:-/nonexistent}" ]]; then
    if ! issue_receipt "$rc"; then log "RECEIPT_FAILED — post-revoke 판정 불가"; rc=1; fi
  fi
  # 회수 성공이어도 원래 실패/취소 rc 는 보존한다(0 으로 덮지 않음).
  log "CLEANUP_END final_rc=$rc"
  exit "$rc"
}

# 해시는 rc·형식을 검사한 뒤에만 낸다(리뷰 5530751510 R3). 실패를 빈 문자열로 넘기지 않는다.
sha_of() {
  local out
  out=$(sha256sum -- "$1") || return 1
  out=${out%% *}
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}
# 회수 판정·결속 원본을 $EV/11-revoke-verify/ 로 복사하고 SHA256SUMS 를 만든다(PR#43 리뷰 S3).
# preflight-cluster.json 은 grant 전 단계라 항상 있어야 한다. verify-* 는 회수 확인을 한 회차에만 있다.
copy_revoke_evidence() {
  local d="$EV/11-revoke-verify" f n=0
  mkdir -p "$d" || return 1
  [[ -s "$WORKDIR/preflight-cluster.json" ]] || { log "EVIDENCE: preflight-cluster.json 없음"; return 1; }
  cp -p -- "$WORKDIR/preflight-cluster.json" "$d/" || return 1
  for f in "$WORKDIR"/verify-users.*.out "$WORKDIR"/verify-users.*.err "$WORKDIR"/verify-cani.*.out "$WORKDIR"/verify-cani.*.err "$WORKDIR"/revoke.out "$WORKDIR"/revoke.err; do
    [[ -e "$f" ]] || continue
    cp -p -- "$f" "$d/" || return 1
    n=$((n + 1))
  done
  # 회수를 시도했는데 판정 원본이 하나도 없으면 근거가 빠진 것
  if [[ "${grant_attempted:-0}" == 1 && $n -eq 0 ]]; then log "EVIDENCE: 회수 판정 원본(verify-*) 없음"; return 1; fi
  ( cd "$d" && sha256sum -- * >SHA256SUMS ) || return 1
  log "EVIDENCE_COPIED $d (verify 원본 ${n}개 + preflight)"
}

issue_receipt() {
  local status=COMPLETE f now h_old h_tgt h_uid h_inv h_rev tmp="$EV/99-receipt.env.tmp"
  [[ $1 == 3 ]] && status=POLICY_PENDING
  for f in "$KUBECONFIG" "$EV/00-target.env" "$EV/05-ns-uid.txt" "$EV/10b-inventory/SHA256SUMS" "$EV/10b-path-review.tsv"; do
    [[ -s "$f" ]] || { log "RECEIPT: 필요한 파일 없음($f)"; return 1; }
  done
  # 모든 값을 먼저 계산·검증한다. 하나라도 실패하면 receipt 를 만들지 않는다.
  h_old=$(sha_of "$KUBECONFIG")                     || { log "RECEIPT: 회수 전 세션 해시 실패"; return 1; }
  h_tgt=$(sha_of "$EV/00-target.env")              || { log "RECEIPT: target 해시 실패"; return 1; }
  h_uid=$(sha_of "$EV/05-ns-uid.txt")              || { log "RECEIPT: namespace UID 해시 실패"; return 1; }
  h_inv=$(sha_of "$EV/10b-inventory/SHA256SUMS")   || { log "RECEIPT: 인벤토리 SHA256SUMS 해시 실패"; return 1; }
  h_rev=$(sha_of "$EV/10b-path-review.tsv")        || { log "RECEIPT: path-review 해시 실패"; return 1; }
  now=$(date '+%FT%T%z')                            || return 1
  # 임시 파일에 완성본을 쓴 뒤 한 번에 확정(rename). 쓰기·확정 실패 시 불완전 파일을 남기지 않는다.
  # 각 쓰기를 && 로 잇는다 — { a; b; } 는 마지막 명령의 rc 만 돌려주므로 중간 실패가 덮인다(리뷰 5542174606 R3, 이권욱 제시안).
  if ! {
    printf 'RECEIPT_VERSION=1\nSTATUS=%s\nFINAL_RC=%s\n' "$status" "$1" &&
    printf 'CLUSTER_ID=%s\nAPI_URL=%s\nUSER=%s\nREVOKE_VERIFIED_AT=%s\n' "$CLUSTER_ID" "$API_URL" "$U" "$now" &&
    printf 'OLD_KUBECONFIG_SHA256=%s\nTARGET_SHA256=%s\nNS_UID_SHA256=%s\n' "$h_old" "$h_tgt" "$h_uid" &&
    printf 'INVENTORY_SUMS_SHA256=%s\nPATH_REVIEW_SHA256=%s\n' "$h_inv" "$h_rev"
  } >"$tmp"; then
    rm -f -- "$tmp"; log "RECEIPT: 쓰기 실패"; return 1
  fi
  if ! mv -f -- "$tmp" "$EV/99-receipt.env"; then
    rm -f -- "$tmp" "$EV/99-receipt.env"; log "RECEIPT: 확정(rename) 실패"; return 1
  fi
  log "RECEIPT_ISSUED status=$status $EV/99-receipt.env"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 화면 파이프가 끊긴 뒤의 쓰기(SIGPIPE)도 cleanup(회수)으로 보낸다. 기본 동작이면 trap 없이 즉시 죽는다.
trap 'exit 141' PIPE

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
