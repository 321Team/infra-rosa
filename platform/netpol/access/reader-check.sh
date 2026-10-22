#!/usr/bin/env bash
# infra-rosa#7 — 래퍼 회수(REVOKE_VERIFIED) 뒤 하영 일반 세션으로 읽기 권한 상태를 확인하고 반출 묶음을 만든다.
# 사용: bash reader-check.sh <on|off>
#   on : 읽기 4종 yes + 그 밖(Secret·쓰기·전체 권한) no, 실제 읽기(nodes·network.config) 성공
#   off: 읽기 4종이 모두 no(기존 #5 회수 뒤 상태로 복귀)
# 입력(env): WORKDIR(기본 ~/rosa-netpol-reader, #5 ~/rosa-idp와 분리), API_URL. 세션은 래퍼가 쓴 $WORKDIR/kubeconfig(회수 뒤 일반 권한).
# 쓰기 없음. token 원문 미기록.
set -euo pipefail
umask 077
MODE="${1:-}"; [[ "$MODE" == on || "$MODE" == off ]] || { echo "사용: bash reader-check.sh <on|off>" >&2; exit 2; }
WORKDIR="${WORKDIR:-$HOME/rosa-netpol-reader}"
: "${API_URL:?API_URL 필요}"
export KUBECONFIG="$WORKDIR/kubeconfig"
EXPECT_USER="${EXPECT_USER:-hayeoung}"
# 모든 oc 호출에 요청·프로세스 상한(PR53 R2와 같은 기준). 초과는 FAIL/STOP(판정 불가)
_oc() { timeout -k 10 "${READER_CALL_S:-60}" oc --request-timeout="${READER_REQ_S:-30}s" "$@"; }
RD=$(ls -dt "$WORKDIR"/netpol-reader-"$MODE"-* 2>/dev/null | head -1) || true
[[ -n "$RD" && -d "$RD" ]] || { echo "STOP: $MODE 단계 기록 폴더 없음(래퍼 단계가 먼저)" >&2; exit 2; }
CK="$RD/check"; mkdir -p "$CK"
FAIL=0
log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*" | tee -a "$CK/check.log"; }

# 래퍼 결과: 회수 확인이 없으면 판정하지 않음
# 마지막 래퍼 회차(마지막 GRANT_START 이후)가 이 단계 기록·회수 확인·rc0으로 끝났는지 본다(이전 회차 기록과 섞지 않음)
gs=$(grep -n 'GRANT_START' "$WORKDIR/session-events.log" | tail -1 | cut -d: -f1) || true
[[ -n "$gs" ]] || { log "STOP: 래퍼 기록(GRANT_START) 없음"; exit 1; }
sed -n "${gs},\$p" "$WORKDIR/session-events.log" >"$CK/last-session.log"
grep -qF "STEPS_RD $RD" "$CK/last-session.log" && grep -q 'REVOKE_VERIFIED' "$CK/last-session.log" && grep -q 'CLEANUP_END final_rc=0$' "$CK/last-session.log" \
  || { log "STOP: 마지막 래퍼 회차가 이 단계·REVOKE_VERIFIED·rc0으로 끝나지 않음 — 회수 먼저 확인"; exit 1; }
[[ "$(_oc whoami --show-server)" == "$API_URL" ]] || { log "STOP: server 불일치 또는 조회 실패"; exit 1; }
_oc whoami >"$CK/whoami.out" 2>"$CK/whoami.err" || { log "STOP: whoami 실패(세션 만료면 oc login 후 다시)"; exit 1; }
[[ "$(<"$CK/whoami.out")" == "$EXPECT_USER" ]] || { log "STOP: 확인 주체가 $EXPECT_USER 아님($(<"$CK/whoami.out"))"; exit 1; }
log "계정: $(<"$CK/whoami.out")"

# 클러스터 범위 질의에 붙는 scope 경고만 있는 stderr 허용(#5 steps.sh _scope_warning_only와 같은 기준)
scope_only() { local rc=0; grep -vE "^(Warning: resource '[a-z0-9.-]+' is not namespace scoped( in group '[a-z0-9.-]+')?)?$" "$1" >/dev/null || rc=$?; [[ $rc -eq 1 ]]; }
cani() { # id want args...
  local id=$1 want=$2 rc=0 got=OTHER; shift 2
  _oc auth can-i "$@" >"$CK/$id.out" 2>"$CK/$id.err" || rc=$?
  [[ $rc -eq 0 && "$(<"$CK/$id.out")" == yes ]] && scope_only "$CK/$id.err" && got=yes
  [[ $rc -eq 1 && "$(<"$CK/$id.out")" == no ]] && scope_only "$CK/$id.err" && got=no
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$*" "$want" "$got" "$rc" >>"$CK/results.tsv"
  [[ "$got" == "$want" ]] || { FAIL=1; log "FAIL $id want=$want got=$got rc=$rc"; }
}
printf 'id\trequest\texpect\tobserved\trc\n' >"$CK/results.tsv"
r=yes; [[ $MODE == off ]] && r=no
cani R-1 "$r" list nodes
cani R-2 "$r" get networks.config.openshift.io/cluster
cani R-3 "$r" list namespaces
cani R-4 "$r" list pods --all-namespaces
cani R-5 "$r" list pods -n openshift-dns
cani N-1 no get secrets --all-namespaces
cani N-2 no create pods -n openshift-dns
cani N-3 no delete nodes
cani N-4 no update networks.config.openshift.io/cluster
cani N-5 no create clusterrolebindings
cani N-6 no '*' '*' --all-namespaces
cani K-1 yes create networkpolicies -n fds-app
if [[ $MODE == on ]]; then
  _oc get nodes -o name >"$CK/nodes.out" 2>"$CK/nodes.err" && [[ $(grep -c '^node/' "$CK/nodes.out") -ge 1 ]] || { FAIL=1; log "FAIL 실제 nodes 읽기"; }
  _oc get network.config cluster -o 'jsonpath={.status.networkType}' >"$CK/network.out" 2>"$CK/network.err" && [[ "$(<"$CK/network.out")" == OVNKubernetes ]] || { FAIL=1; log "FAIL 실제 network.config 읽기"; }
fi
# 반출: 이 단계 기록 + 래퍼 회수 원본(token·kubeconfig 제외)
mkdir -p "$RD/wrapper"
for f in "$WORKDIR"/session-events.log "$WORKDIR"/preflight-cluster.json "$WORKDIR"/verify-users.*.out "$WORKDIR"/verify-users.*.err "$WORKDIR"/verify-cani.*.out "$WORKDIR"/verify-cani.*.err "$WORKDIR"/revoke.out "$WORKDIR"/revoke.err; do
  [[ -e "$f" ]] && cp -p -- "$f" "$RD/wrapper/"
done
RESULT=PASS; [[ $FAIL == 0 ]] || RESULT=FAIL
log "READER_CHECK_$MODE=$RESULT"
echo "READER_CHECK_$MODE=$RESULT" >"$CK/RESULT.txt"
( cd "$RD" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS )
tar -czf "$RD.tgz" -C "$(dirname "$RD")" "$(basename "$RD")"
log "묶음: $RD.tgz sha256=$(sha256sum "$RD.tgz" | cut -d' ' -f1)"
[[ $FAIL == 0 ]]
