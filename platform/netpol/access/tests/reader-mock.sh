#!/usr/bin/env bash
# steps-reader.sh·reader-check.sh MOCK: 가짜 oc(+래퍼 시험용 가짜 rosa·jq). 실제 클러스터 호출 없음.
# 실행: bash platform/netpol/access/tests/reader-mock.sh
#   W 시험은 실제 platform/rbac/bootstrap/bootstrap-session.sh를 돌려 grant → 단계 → revoke → 회수 확인 경로를 본다.
#   나머지는 래퍼를 log 줄로 흉내 낸다(단계 파일 판정만 빠르게).
set -euo pipefail
A="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$(cd "$A/../../rbac/bootstrap" && pwd)/bootstrap-session.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/reader-mock.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
API=https://api.mock:443
export READER_CALL_S=3 READER_REQ_S=2 GRANT_WAIT_INTERVAL=0

cat >"$T/bin/oc" <<'M'
#!/usr/bin/env bash
args=(); for x in "$@"; do [[ $x == --request-timeout=* ]] || args+=("$x"); done
a="${args[*]}"; printf '%s\n' "oc $a" >>"$CALLLOG"
U1=aaaaaaaa-0000-0000-0000-000000000001; U2=bbbbbbbb-0000-0000-0000-000000000002
nf() { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
f() { case "$1" in clusterrole/*|*/clusterroles/*) echo "$ST/cr";; clusterrolebinding/*|*/clusterrolebindings/*) echo "$ST/crb";; esac; }
sw() { echo "Warning: resource '$1' is not namespace scoped" >&2; }
hang() { [ "$SCENARIO" = "hang_$1" ] && sleep 30; true; }
case "$a" in
  login*) echo "Login successful.";;
  "whoami --show-server") echo https://api.mock:443;;
  whoami) [ "$SCENARIO" = other_user ] && [ ! -f "$ST/granted" ] && { echo someone; exit 0; }; echo hayeoung;;
  "auth can-i * * --all-namespaces") [ -f "$ST/granted" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i list nodes"|"auth can-i list namespaces") sw "${a##* }"; [ -f "$ST/crb" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i get networks.config.openshift.io/cluster"|"auth can-i list pods --all-namespaces"|"auth can-i list pods -n openshift-dns")
    [ -f "$ST/crb" ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i get secrets --all-namespaces") [ "$SCENARIO" = leak ] && { echo yes; exit 0; }; echo no; exit 1;;
  "auth can-i create networkpolicies -n fds-app") echo yes;;
  "auth can-i "*) echo no; exit 1;;
  "get clusterrole"*" -o jsonpath={.metadata.uid}")
    k="${a#get }"; k="${k%% *}"; [[ $k == clusterrole/* ]] && hang get
    p=$(f "$k"); [ -f "$p" ] || nf "$k"; cat "$p";;
  "create -f "*)
    hang create
    echo -n "$U1" >"$ST/cr"; printf 'ClusterRole\tfds-netpol-window-reader\t%s\n' "$U1"
    [ "$SCENARIO" = partial ] && { echo 'error: timeout' >&2; exit 1; }
    # swap_after_create: 응답은 U2인데 그 직후 누가 같은 이름으로 교체
    if [ "$SCENARIO" = swap_after_create ]; then echo -n "dddddddd-0000-0000-0000-000000000004" >"$ST/crb"; else echo -n "$U2" >"$ST/crb"; fi
    printf 'ClusterRoleBinding\tfds-netpol-window-reader-hayeoung\t%s\n' "$U2";;
  "get clusterrolebinding/"*"roleRef"*) printf 'fds-netpol-window-reader|User:hayeoung,';;
  "delete --raw "*)
    path="${a#delete --raw }"; path="${path%% *}"; body="${a##*-f }"; p=$(f "$path")
    want=$(sed -n 's/.*"uid":"\([^"]*\)".*/\1/p' "$body")
    # swap_before_delete: GET 뒤·DELETE 전에 Binding이 교체됨
    [ "$SCENARIO" = swap_before_delete ] && [[ $path == */clusterrolebindings/* ]] && echo -n "eeeeeeee-0000-0000-0000-000000000005" >"$p"
    [ -f "$p" ] || nf "$path"
    [ "$(cat "$p")" = "$want" ] || { echo "Error from server (Conflict): Operation cannot be fulfilled: Precondition failed: UID in precondition: $want, UID in object meta: $(cat "$p")" >&2; exit 1; }
    rm -f "$p"; echo '{"kind":"Status","status":"Success"}';;
  "get nodes -o name") [ -f "$ST/crb" ] || { echo forbidden >&2; exit 1; }; printf 'node/a\nnode/b\nnode/c\n';;
  "get network.config cluster"*) [ -f "$ST/crb" ] || { echo forbidden >&2; exit 1; }; echo -n OVNKubernetes;;
  *) echo "unexpected oc $a" >&2; exit 98;;
esac
M
cat >"$T/bin/rosa" <<'M'
#!/usr/bin/env bash
printf '%s\n' "rosa $*" >>"$CALLLOG"
case "$*" in
  "describe cluster"*) echo '{"api":{"url":"https://api.mock:443"}}';;
  "grant user cluster-admin"*) touch "$ST/granted"; echo granted;;
  "revoke user cluster-admin"*) rm -f "$ST/granted"; echo revoked;;
  "list users"*) if [ -f "$ST/granted" ]; then printf 'ID        GROUPS\nhayeoung  cluster-admins\n'; else echo "INFO: There are no users configured for cluster 'mock'"; fi;;
  *) echo "unexpected rosa $*" >&2; exit 98;;
esac
M
# 래퍼가 쓰는 jq 필터는 `.api.url`(문자열) 하나 — 작성 PC에 jq가 없을 때만 대신한다
if ! command -v jq >/dev/null; then
  printf '#!/usr/bin/env bash\nexec py -3 -c "import json,sys; print(json.load(open(sys.argv[-1]))[\\"api\\"][\\"url\\"])" "$@"\n' >"$T/bin/jq"
fi
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; tail -n 6 "$T/last.log" | sed 's/^/     /'; }
newenv() { export SCENARIO="$2" ST="$T/st.$1" WORKDIR="$T/w.$1" CALLLOG="$T/calls.$1"; mkdir -p "$ST" "$WORKDIR"; : >"$CALLLOG"; : >"$WORKDIR/session-events.log"; }
# 래퍼 흉내(빠른 단계 판정용)
wrap() { # mode [no_revoke]
  local rc=0
  echo "[x] GRANT_START user=hayeoung" >>"$WORKDIR/session-events.log"; touch "$ST/granted"
  ( set -Eeuo pipefail
    log() { echo "[x] $*" >>"$WORKDIR/session-events.log"; echo "$*"; }
    export KUBECONFIG="$WORKDIR/kubeconfig" U=hayeoung API_URL="$API" CLUSTER_ID=mock READER_MODE="$1"
    source "$A/steps-reader.sh"; run_steps ) >"$T/last.log" 2>&1 || rc=$?
  rm -f "$ST/granted"
  [ "${2:-}" = no_revoke ] || echo "[x] REVOKE_VERIFIED" >>"$WORKDIR/session-events.log"
  echo "[x] CLEANUP_END final_rc=$rc" >>"$WORKDIR/session-events.log"
  RC=$rc
}
# 실제 래퍼
realwrap() { # mode
  set +e
  ( cd "$A" && READER_MODE="$1" CLUSTER_ID=mock API_URL="$API" DEADLINE_EPOCH=$(( $(date +%s) + 120 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 \
      bash "$WRAP" steps-reader.sh ) >"$T/last.log" 2>&1
  RC=$?; set -e
}
check() { set +e; ( API_URL="$API" bash "$A/reader-check.sh" "$1" ) >"$T/last.log" 2>&1; RC=$?; set -e; }
odel() { grep -q '^oc delete ' "$CALLLOG"; }

# ---- 실제 래퍼 경로 ----
newenv w ok
realwrap on
[[ $RC == 0 ]] && grep -q 'REVOKE_VERIFIED' "$WORKDIR/session-events.log" && grep -q '^CRB_UID=bbbbbbbb' "$WORKDIR/netpol-reader-current.env" && [ ! -f "$ST/granted" ] && ok "W1 실제 래퍼 on: grant→생성(ACK UID)→revoke·REVOKE_VERIFIED" || bad "W1 wrap on"
check on
[[ $RC == 0 ]] && grep -q 'READER_CHECK_on=PASS' "$T/last.log" && ok "W2 check on PASS(실제 래퍼 회차 결속)" || bad "W2 check on"
realwrap off
[[ $RC == 0 && ! -e "$ST/cr" && ! -e "$ST/crb" ]] && grep -q 'delete --raw /apis/rbac.authorization.k8s.io/v1/clusterrolebindings/' "$CALLLOG" && ok "W3 실제 래퍼 off: UID 조건 raw DELETE·revoke" || bad "W3 wrap off"
check off
[[ $RC == 0 ]] && grep -q 'READER_CHECK_off=PASS' "$T/last.log" && ok "W3b check off PASS(읽기 4종 no)" || bad "W3b check off"
newenv h hang_get
s=$(date +%s); realwrap on; e=$(( $(date +%s) - s ))
[[ $RC != 0 ]] && grep -q 'REVOKE_VERIFIED' "$WORKDIR/session-events.log" && grep -q 'rosa revoke user cluster-admin' "$CALLLOG" && [ ! -f "$ST/granted" ] && (( e < 25 )) \
  && ok "W4 멈춘 API → 상한(${e}s)으로 STOP·실제 래퍼 revoke·회수 확인(R2)" || bad "W4 hang (${e}s)"

# ---- 단계 파일 판정 ----
newenv a ok
wrap on; check on
grep -q $'^R-1\tlist nodes\tyes\tyes' "$WORKDIR"/netpol-reader-on-*/check/results.tsv && ok "scope 경고만 있는 yes 인정" || bad "scope warn"
wrap off
grep -n '^oc delete ' "$CALLLOG" | head -1 | grep -q 'clusterrolebindings' && ok "off: Binding 먼저 삭제" || bad "order"
grep -q '"preconditions":{"uid":"bbbbbbbb' "$WORKDIR"/netpol-reader-off-*/delete-clusterrolebinding.body.json && ok "off: 삭제 요청에 UID 조건 포함" || bad "precondition body"
newenv b ok; echo -n "cccccccc-0000-0000-0000-000000000003" >"$ST/cr"
wrap on
[[ $RC != 0 ]] && ! grep -q 'create -f' "$CALLLOG" && ok "on: 같은 이름 Role 이미 있음 → 만들지 않고 STOP" || bad "exists"
newenv c swap_after_create
wrap on
[[ $RC != 0 && ! -e "$WORKDIR/netpol-reader-current.env" ]] && grep -q '생성 직후 UID가 응답과 다름' "$T/last.log" && ok "on: 생성 ACK 뒤 교체 → 소유로 채택하지 않음(R1)" || bad "swap after create"
newenv d swap_before_delete
wrap on; wrap off
[[ $RC != 0 && -e "$ST/crb" ]] && grep -q '409' "$T/last.log" && [ "$(cat "$ST/crb")" = eeeeeeee-0000-0000-0000-000000000005 ] && ok "off: GET→DELETE 사이 교체 → 서버 409, 교체 Binding 보존(R1)" || bad "swap before delete"
newenv e ok
wrap off
[[ $RC != 0 ]] && ! odel && ok "off: 붙이기 기록 없음 → STOP" || bad "no record"
newenv f partial
wrap on
[[ $RC != 0 ]] && grep -q 'UNKNOWN' "$T/last.log" && [ ! -e "$WORKDIR/netpol-reader-current.env" ] && ok "on: 일부만 생성 → STOP·UNKNOWN·채택 없음" || bad "partial"
newenv g hang_create
s=$(date +%s); wrap on; e=$(( $(date +%s) - s ))
[[ $RC != 0 ]] && (( e < 25 )) && grep -q 'UNKNOWN' "$T/last.log" && ok "on: create 응답 멈춤 → 상한(${e}s)·UNKNOWN(R2)" || bad "hang create (${e}s)"
newenv i ok
wrap on no_revoke; check on
[[ $RC != 0 ]] && grep -q 'REVOKE_VERIFIED' "$T/last.log" && ok "check: 마지막 회차 회수 확인 없으면 판정 안 함" || bad "no revoke"
newenv j leak
wrap on; check on
[[ $RC != 0 ]] && grep -q 'FAIL N-1' "$T/last.log" && ok "check on: Secret 읽기 yes면 FAIL" || bad "leak"
newenv k other_user
wrap on; check on
[[ $RC != 0 ]] && grep -q '확인 주체가 hayeoung 아님' "$T/last.log" && ok "check: whoami가 기대 사용자 아니면 STOP(권고)" || bad "other user"
! grep -rqiE 'token|password' "$T"/w.*/netpol-reader-*/*.out 2>/dev/null && ok "token·비밀번호 미기록" || bad "secret"
echo "----"; echo "PASS=$pass FAIL=$fail"; (( fail == 0 ))
