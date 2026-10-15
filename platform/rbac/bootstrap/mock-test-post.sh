#!/usr/bin/env bash
# post-revoke-check.sh MOCK 시험 — 가짜 rosa/oc(클라우드 호출 없음). 하나라도 FAIL 이면 rc1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
# KUBECONFIG 로 세션 구분: .../kubeconfig = 회수 전(OLD), .../kubeconfig-d11 = 새 로그인(NEW)
mode=OLD; [[ "${KUBECONFIG:-}" == *kubeconfig-d11 ]] && mode=NEW
echo "oc[$mode] $*" >>"$MOCK_LOG"
deny()  { echo "Error from server (Forbidden): mock" >&2; exit 1; }
unauth(){ echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; }
a="$*"
if [[ $mode == OLD ]]; then
  case "$a" in
    "get nodes") case "${MOCK_OLD:-deny}" in allow) exit 0 ;; unauth) unauth ;; *) deny ;; esac ;;
    "logout") exit 0 ;;
  esac
  exit 0
fi
case "$a" in
  "login "*) exit 0 ;;
  "whoami") echo hayeoung ;;
  "whoami --show-server") echo https://api.mock:443 ;;
  "get nodes") [[ "${MOCK_NEW_NODES:-deny}" == unauth ]] && unauth; deny ;;
  "get pods -n fds-app") exit 0 ;;
  "auth can-i '*' '*' --all-namespaces"|"auth can-i * * --all-namespaces")
    [[ "${MOCK_NEW_STAR:-no}" == yes ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  "auth can-i create servicemonitors"*"-n fds-app") echo yes; exit 0 ;;
  "auth can-i "*) echo no; exit 1 ;;
esac
exit 0
EOF
cat >"$T/bin/rosa" <<'EOF'
#!/usr/bin/env bash
echo "rosa $*" >>"$MOCK_LOG"
[[ "$1 $2" == "list users" ]] || exit 0
case "${MOCK_USERS_MODE:-header}" in
  header) echo "ID        GROUPS" ;;
  admin)  echo "ID        GROUPS"; echo "hayeoung  cluster-admins" ;;
  broken) echo "<html>bad</html>" ;;
esac
EOF
chmod +x "$T/bin/oc" "$T/bin/rosa"

fail=0
case_() { # name expect_rc [env...]
  local name=$1 expect=$2; shift 2
  local home="$T/h-$name" log="$T/$name.log"; : >"$log"
  mkdir -p "$home/rosa-idp/ev"
  : >"$home/rosa-idp/kubeconfig"                               # 래퍼가 남겨 둔 회수 전 세션
  [[ "${NO_OLD:-0}" == 1 ]] && rm -f "$home/rosa-idp/kubeconfig"
  printf 'APPROVED\tfds-app\thayeoung-admin\n' >"$home/rosa-idp/ev/10b-path-review.tsv"
  [[ "${UNEXPECTED_PATH:-0}" == 1 ]] && printf 'UNEXPECTED\tcluster\thidden\n' >>"$home/rosa-idp/ev/10b-path-review.tsv"
  env PATH="$T/bin:$PATH" HOME="$home" MOCK_LOG="$log" CLUSTER_ID=mock-id API_URL=https://api.mock:443 "$@" \
    bash "$HERE/post-revoke-check.sh" "$home/rosa-idp/ev" >/dev/null 2>"$T/$name.err"
  local rc=$? old_left=no
  [[ -f "$home/rosa-idp/kubeconfig" ]] && old_left=yes
  local ok=PASS; [[ $rc == "$expect" ]] || { ok=FAIL; fail=1; }
  printf '%-24s rc=%-2s expect=%-2s old_kubeconfig_left=%-3s => %s\n' "$name" "$rc" "$expect" "$old_left" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s)"
case_ P1_normal              0
case_ P2_old_session_admin   1 MOCK_OLD=allow          # 회수 전 세션이 여전히 관리자 → CLEANUP_REQUIRED
case_ P3_old_session_401     0 MOCK_OLD=unauth         # 회수 전 세션 401 은 허용(D-11a·c 와 결합)
case_ P4_new_nodes_401       1 MOCK_NEW_NODES=unauth   # 새 세션 401 은 D-11a PASS 아님
case_ P5_new_star_yes        1 MOCK_NEW_STAR=yes       # SSAR '*' '*' yes
case_ P6_mgmt_still_admin    1 MOCK_USERS_MODE=admin
case_ P7_mgmt_format_unknown 1 MOCK_USERS_MODE=broken
UNEXPECTED_PATH=1 case_ P8_unexpected_path 1
NO_OLD=1 case_ P9_no_old_kubeconfig 1
exit "$fail"
