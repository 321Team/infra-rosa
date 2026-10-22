#!/usr/bin/env bash
# steps-reader.sh·reader-check.sh MOCK: 가짜 oc. 래퍼(grant/revoke)는 log 줄로만 흉내 낸다. 실제 클러스터 호출 없음.
# 실행: bash platform/netpol/access/tests/reader-mock.sh
set -euo pipefail
A="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/reader-mock.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
API=https://api.mock:443

cat >"$T/bin/oc" <<'M'
#!/usr/bin/env bash
printf '%s\n' "oc $*" >>"$CALLLOG"; a="$*"
nf() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
f() { case "$1" in clusterrole/*) echo "$ST/cr";; clusterrolebinding/*) echo "$ST/crb";; esac; }
sw() { echo "Warning: resource '$1' is not namespace scoped" >&2; }
case "$a" in
  login*) echo "Login successful.";;
  "whoami --show-server") echo https://api.mock:443;;
  whoami) echo hayeoung;;
  "auth can-i * * --all-namespaces") [ -f "$ST/granted" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i list nodes"|"auth can-i list namespaces") sw "${a##* }"; [ -f "$ST/crb" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i get networks.config.openshift.io/cluster") [ -f "$ST/crb" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i list pods --all-namespaces"|"auth can-i list pods -n openshift-dns") [ -f "$ST/crb" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i get secrets --all-namespaces") [ "$SCENARIO" = leak ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i create networkpolicies -n fds-app") echo yes;;
  "auth can-i "*) echo no; exit 1;;
  "get clusterrole/"*" -o jsonpath={.metadata.uid}"|"get clusterrolebinding/"*" -o jsonpath={.metadata.uid}")
    k="${a#get }"; k="${k%% *}"; p=$(f "$k"); [ -f "$p" ] || nf "$k"
    if [ "$SCENARIO" = uid_changed ] && [[ $k == clusterrolebinding/* ]] && [ -f "$ST/swap" ]; then echo -n "99999999-9999-9999-9999-999999999999"; else cat "$p"; fi;;
  "create -f "*)
    echo -n "aaaaaaaa-0000-0000-0000-000000000001" >"$ST/cr"; echo clusterrole.rbac.authorization.k8s.io/fds-netpol-window-reader
    [ "$SCENARIO" = partial ] && { echo 'error: timeout' >&2; exit 1; }
    echo -n "bbbbbbbb-0000-0000-0000-000000000002" >"$ST/crb"; echo clusterrolebinding.rbac.authorization.k8s.io/fds-netpol-window-reader-hayeoung
    touch "$ST/created_once";;
  "get clusterrolebinding/"*"roleRef"*) printf 'fds-netpol-window-reader|User:hayeoung,';;
  "delete "*) k="${a#delete }"; k="${k%% *}"; rm -f "$(f "$k")"; echo deleted;;
  "get clusterrole"*" -o name") k="${a#get }"; k="${k%% *}"; [ -f "$(f "$k")" ] && echo "$k" || nf "$k";;
  "get nodes -o name") [ -f "$ST/crb" ] || { echo forbidden >&2; exit 1; }; printf 'node/a\nnode/b\nnode/c\n';;
  "get network.config cluster"*) [ -f "$ST/crb" ] || { echo forbidden >&2; exit 1; }; echo -n OVNKubernetes;;
  *) echo "unexpected oc $a" >&2; exit 98;;
esac
M
chmod +x "$T/bin/oc"
export PATH="$T/bin:$PATH"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; tail -n 5 "$T/last.log" | sed 's/^/     /'; }
newenv() { # id scenario
  export SCENARIO="$2" ST="$T/st.$1" WORKDIR="$T/w.$1" CALLLOG="$T/calls.$1"
  mkdir -p "$ST" "$WORKDIR"; : >"$CALLLOG"; : >"$WORKDIR/session-events.log"
}
# 래퍼 흉내: GRANT_START → (grant) → run_steps → revoke → REVOKE_VERIFIED → CLEANUP_END
wrap() { # mode [no_revoke]
  local rc=0
  echo "[x] GRANT_START user=hayeoung" >>"$WORKDIR/session-events.log"; touch "$ST/granted"
  ( set -Eeuo pipefail
    log() { echo "[x] $*" >>"$WORKDIR/session-events.log"; echo "$*"; }
    export KUBECONFIG="$WORKDIR/kubeconfig" U=hayeoung API_URL="$API" CLUSTER_ID=mock READER_MODE="$1" GRANT_WAIT_INTERVAL=0
    source "$A/steps-reader.sh"; run_steps ) >"$T/last.log" 2>&1 || rc=$?
  rm -f "$ST/granted"
  [ "${2:-}" = no_revoke ] || echo "[x] REVOKE_VERIFIED" >>"$WORKDIR/session-events.log"
  echo "[x] CLEANUP_END final_rc=$rc" >>"$WORKDIR/session-events.log"
  RC=$rc
}
check() { set +e; ( API_URL="$API" bash "$A/reader-check.sh" "$1" ) >"$T/last.log" 2>&1; RC=$?; set -e; }

newenv a ok
wrap on
[[ $RC == 0 && -s "$WORKDIR/netpol-reader-current.env" ]] && grep -q '^CRB_UID=bbbbbbbb' "$WORKDIR/netpol-reader-current.env" && ok "on: 2개 생성·UID 기록" || bad "on"
check on
[[ $RC == 0 ]] && grep -q 'READER_CHECK_on=PASS' "$T/last.log" && ls "$WORKDIR"/netpol-reader-on-*.tgz >/dev/null && ok "check on: 읽기 4종 yes·나머지 no·실제 읽기·묶음" || bad "check on"
grep -q $'^R-1\tlist nodes\tyes\tyes' "$WORKDIR"/netpol-reader-on-*/check/results.tsv && ok "scope 경고만 있는 yes 인정" || bad "scope warn"
wrap off
[[ $RC == 0 && ! -e "$ST/cr" && ! -e "$ST/crb" && ! -e "$WORKDIR/netpol-reader-current.env" ]] && ok "off: UID 대조 후 Binding→Role 삭제·NotFound" || bad "off"
grep -n '^oc delete ' "$CALLLOG" | head -1 | grep -q 'clusterrolebinding' && ok "off: Binding 먼저 삭제" || bad "order"
check off
[[ $RC == 0 ]] && grep -q 'READER_CHECK_off=PASS' "$T/last.log" && ok "check off: 읽기 4종 no로 복귀" || bad "check off"

newenv b ok; echo -n "cccccccc-0000-0000-0000-000000000003" >"$ST/cr"
wrap on
[[ $RC != 0 ]] && ! grep -q 'create -f' "$CALLLOG" && ok "on: 같은 이름 Role 이미 있음 → 만들지 않고 STOP" || bad "exists"
newenv c uid_changed
wrap on; touch "$ST/swap"; wrap off
[[ $RC != 0 && -e "$ST/crb" ]] && ! grep -q '^oc delete ' "$CALLLOG" && ok "off: UID 불일치 → 지우지 않고 STOP" || bad "uid mismatch"
newenv d ok
wrap off
[[ $RC != 0 ]] && ! grep -q '^oc delete ' "$CALLLOG" && ok "off: 붙이기 기록 없음 → STOP" || bad "no record"
newenv e partial
wrap on
[[ $RC != 0 ]] && grep -q 'UNKNOWN' "$T/last.log" && ok "on: 일부만 생성 → STOP·UNKNOWN(사람 확인)" || bad "partial"
newenv f ok
wrap on no_revoke
check on
[[ $RC != 0 ]] && grep -q 'REVOKE_VERIFIED' "$T/last.log" && ok "check: 마지막 회차 회수 확인 없으면 판정 안 함" || bad "no revoke"
newenv g leak
wrap on; check on
[[ $RC != 0 ]] && grep -q 'FAIL N-1' "$T/last.log" && ok "check on: Secret 읽기 yes면 FAIL" || bad "leak"
! grep -rqiE 'token|password' "$T"/w.*/netpol-reader-*/*.out 2>/dev/null && ok "token·비밀번호 미기록" || bad "secret"
echo "----"; echo "PASS=$pass FAIL=$fail"; (( fail == 0 ))
