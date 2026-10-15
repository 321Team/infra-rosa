#!/usr/bin/env bash
# post-revoke-check.sh MOCK 시험 — 가짜 rosa/oc(클라우드 호출 없음, jq 필요). 하나라도 FAIL 이면 rc1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
# KUBECONFIG 로 세션 구분: .../kubeconfig = 회수 전(OLD), .../kubeconfig-d11 = 새 로그인(NEW)
mode=OLD; [[ "${KUBECONFIG:-}" == *kubeconfig-d11 ]] && mode=NEW
echo "oc[$mode] $*" >>"$MOCK_LOG"
# 실제 RBAC 거부 형식
deny()   { echo 'Error from server (Forbidden): nodes is forbidden: User "hayeoung" cannot list resource "nodes" in API group "" at the cluster scope' >&2; exit 1; }
# RBAC 이 아닌 403(admission webhook) — 정상 거부로 보면 안 됨(보완 5)
hook()   { echo 'Error from server (Forbidden): admission webhook "mock.example" denied the request' >&2; exit 1; }
unauth() { echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; }
a="$*"
if [[ $mode == OLD ]]; then
  case "$a" in
    "get nodes") case "${MOCK_OLD:-deny}" in allow) exit 0 ;; unauth) unauth ;; hook) hook ;; *) deny ;; esac ;;
    "logout") exit 0 ;;
  esac
  exit 0
fi
case "$a" in
  "login "*) : >"$KUBECONFIG"; exit 0 ;;                         # 실제 oc login 처럼 새 kubeconfig 파일 생성
  "logout") exit 0 ;;
  "whoami") echo hayeoung ;;
  "whoami --show-server") echo https://api.mock:443 ;;
  "get nodes") case "${MOCK_NEW_NODES:-deny}" in unauth) unauth ;; hook) hook ;; *) deny ;; esac ;;
  "get pods -n fds-app") exit 0 ;;
  "get project "*) [[ "${MOCK_UID_MISMATCH:-0}" == 1 && "$3" == fds-app ]] && { echo "uid-other"; exit 0; }; echo "uid-$3" ;;
  "auth can-i * * --all-namespaces")
    [[ "${MOCK_NEW_STAR:-no}" == yes ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  "auth can-i create servicemonitors"*"-n fds-app") echo yes; exit 0 ;;
  "auth can-i "*) echo no; exit 1 ;;
esac
exit 0
EOF
cat >"$T/bin/rosa" <<'EOF'
#!/usr/bin/env bash
echo "rosa $*" >>"$MOCK_LOG"
if [[ "$1 $2" == "describe cluster" ]]; then echo "{\"api\":{\"url\":\"${MOCK_DESCRIBE_API:-https://api.mock:443}\"}}"; exit 0; fi
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
  local ev="$home/rosa-idp/ev"
  mkdir -p "$ev/10b-inventory"
  : >"$home/rosa-idp/kubeconfig"                               # 래퍼가 남겨 둔 회수 전 세션
  [[ "${NO_OLD:-0}" == 1 ]] && rm -f "$home/rosa-idp/kubeconfig"
  # bootstrap 회차 증적(steps.sh 가 남기는 것과 같은 형식)
  printf 'CLUSTER_ID=%s\nAPI_URL=https://api.mock:443\nUSER=hayeoung\nSTARTED_AT=x\n' "${BOOT_CLUSTER:-mock-id}" >"$ev/00-target.env"
  echo "${BOOT_SERVER:-https://api.mock:443}" >"$ev/10b-inventory/server.txt"
  printf 'fds-app uid-fds-app\nmonitoring-api uid-monitoring-api\nci-cd uid-ci-cd\n' >"$ev/05-ns-uid.txt"
  printf 'APPROVED\tfds-app\thayeoung-admin\n' >"$ev/10b-path-review.tsv"
  [[ "${UNEXPECTED_PATH:-0}" == 1 ]] && printf 'UNEXPECTED\tcluster\thidden\n' >>"$ev/10b-path-review.tsv"
  env PATH="$T/bin:$PATH" HOME="$home" MOCK_LOG="$log" CLUSTER_ID=mock-id API_URL=https://api.mock:443 "$@" \
    bash "$HERE/post-revoke-check.sh" "$ev" >/dev/null 2>"$T/$name.err"
  local rc=$? old_left=no new_left=no
  [[ -f "$home/rosa-idp/kubeconfig" ]] && old_left=yes
  [[ -e "$home/rosa-idp/kubeconfig-d11" ]] && new_left=yes
  # 보완 1: 새 세션 kubeconfig 는 어떤 결과든 남으면 안 됨. 회수 전 세션은 정상(rc0)이면 지워져야 함
  local ok=PASS
  [[ $rc == "$expect" && $new_left == no ]] || ok=FAIL
  [[ $rc != 0 || $old_left == no ]] || ok=FAIL
  [[ "$ok" == PASS ]] || fail=1
  printf '%-26s rc=%-2s expect=%-2s old_kubeconfig_left=%-3s new_kubeconfig_left=%-3s => %s\n' \
    "$name" "$rc" "$expect" "$old_left" "$new_left" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s) / jq $(jq --version 2>/dev/null || echo MISSING)"
case_ P1_normal              0
case_ P2_old_session_admin   1 MOCK_OLD=allow          # 회수 전 세션이 여전히 관리자 → CLEANUP_REQUIRED
case_ P3_old_session_401     0 MOCK_OLD=unauth         # 회수 전 세션 401 은 허용(D-11a·c 와 결합)
case_ P4_new_nodes_401       1 MOCK_NEW_NODES=unauth   # 새 세션 401 은 D-11a PASS 아님
case_ P5_new_star_yes        1 MOCK_NEW_STAR=yes       # SSAR '*' '*' yes
case_ P6_mgmt_still_admin    1 MOCK_USERS_MODE=admin
case_ P7_mgmt_format_unknown 1 MOCK_USERS_MODE=broken
UNEXPECTED_PATH=1 case_ P8_unexpected_path 1
NO_OLD=1 case_ P9_no_old_kubeconfig 1
# PR#40 보완 3: 대상 불일치
BOOT_CLUSTER=other-id case_ P10_boot_cluster_mismatch 1                   # 다른 회차(클러스터)의 증적 폴더
BOOT_SERVER=https://api.other:443 case_ P11_inventory_server_mismatch 1  # ⑩-b 수집 server 가 다름
case_ P12_describe_api_mismatch 1 MOCK_DESCRIBE_API=https://api.other:443 # CLUSTER_ID 의 실제 API 가 다름
case_ P13_ns_uid_mismatch 1 MOCK_UID_MISMATCH=1                           # 같은 이름의 다른 namespace
# PR#40 보완 5: RBAC 이 아닌 403 을 정상 거부로 보지 않음
case_ P14_old_session_webhook_403 1 MOCK_OLD=hook
case_ P15_new_nodes_webhook_403   1 MOCK_NEW_NODES=hook
exit "$fail"
