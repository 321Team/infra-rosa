#!/usr/bin/env bash
# post-revoke-check.sh MOCK 시험 — 가짜 rosa/oc(클라우드 호출 없음, jq 필요). 하나라도 FAIL 이면 rc1.
# fixture 는 bootstrap 회차 증적과 같은 형식(00-target.env, 05-ns-uid.txt, 10b-inventory/*, 10b-path-review.tsv,
# 99-receipt.env)을 만들고, 리뷰 5530426592 R3 의 변조·다른 회차·다른 세션 경우를 하나씩 주입한다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
# KUBECONFIG 로 세션 구분: .../kubeconfig = 회수 전(OLD), .../kubeconfig-d11 = 새 로그인(NEW)
mode=OLD; [[ "${KUBECONFIG:-}" == *kubeconfig-d11 ]] && mode=NEW
echo "oc[$mode] $*" >>"$MOCK_LOG"
deny()   { echo 'Error from server (Forbidden): nodes is forbidden: User "hayeoung" cannot list resource "nodes" in API group "" at the cluster scope' >&2; exit 1; }
hook()   { echo 'Error from server (Forbidden): admission webhook "mock.example" denied the request' >&2; exit 1; }
unauth() { echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; }
a="$*"
if [[ $mode == OLD ]]; then
  case "$a" in
    "config view --minify -o jsonpath={.clusters[0].cluster.server}") echo "${MOCK_OLD_SERVER:-https://api.mock:443}" ;;
    "get nodes") case "${MOCK_OLD:-deny}" in allow) exit 0 ;; unauth) unauth ;; hook) hook ;; *) deny ;; esac ;;
    "logout") exit 0 ;;
  esac
  exit 0
fi
case "$a" in
  "login "*) : >"$KUBECONFIG"; exit 0 ;;
  "logout") exit 0 ;;
  "whoami") echo hayeoung ;;
  "whoami --show-server") echo https://api.mock:443 ;;
  "get nodes") case "${MOCK_NEW_NODES:-deny}" in unauth) unauth ;; hook) hook ;; *) deny ;; esac ;;
  "get pods -n fds-app") exit 0 ;;
  "get project "*) [[ "${MOCK_UID_MISMATCH:-0}" == 1 && "$3" == fds-app ]] && { echo "uid-other"; exit 0; }; echo "uid-$3" ;;
  "auth can-i * * --all-namespaces")
    [[ "${MOCK_NEW_STAR:-no}" == yes ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  "auth can-i create servicemonitors"*"-n fds-app") echo yes; exit 0 ;;
  # 하영 clusterversion/version get 최소 권한(#5 6258874244). MOCK_CV_NOBIND = 회수 뒤 세션에서 바인딩이 없음
  "auth can-i get clusterversions.config.openshift.io/version") [[ "${MOCK_CV_NOBIND:-0}" == 1 ]] && { echo no; exit 1; }; echo yes; exit 0 ;;
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
  header)       echo "ID        GROUPS" ;;
  admin)        echo "ID        GROUPS"; echo "hayeoung  cluster-admins" ;;
  broken)       echo "<html>bad</html>" ;;
  headerbroken) echo "ID        GROUPS"; echo "<html>gateway timeout</html>" ;;
  noneinfo)     echo "INFO: There are no users configured for cluster '${MOCK_EMPTY_ID:-mock-id}'" ;;   # #5 A단계 실측 빈 목록
esac
[[ -n "${MOCK_USERS_ERR:-}" ]] && echo "$MOCK_USERS_ERR" >&2
exit 0
EOF
chmod +x "$T/bin/oc" "$T/bin/rosa"
# 실패 주입용 sha256sum(post 실행에만 쓰임). 지정 경로에서만 실패하고 그 밖에는 진짜 명령으로 넘긴다(리뷰 5530751510 R3)
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ -n "${MOCK_SHA_FAIL:-}" && "$a" == *"$MOCK_SHA_FAIL" ]] && { echo "mock sha256sum failure" >&2; exit 42; }; done\nexec %q "$@"\n' \
  "$(command -v sha256sum)" >"$T/bin/sha256sum"
chmod +x "$T/bin/sha256sum"

# 승인 policy(시험 전용): self-provisioners 1행, 규칙 해시는 분류기와 같은 정규화
norm() { jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' | sha256sum | cut -d' ' -f1; }
printf '# test policy\ncluster\tself-provisioners\tClusterRole\tself-provisioner\tGroup:system:authenticated:oauth\t%s\n' \
  "$(printf '{"kind":"ClusterRole"}' | norm)" >"$T/policy.tsv"

sha() { sha256sum -- "$1" | cut -d' ' -f1; }
# bootstrap 회차 증적 fixture + receipt
mk_fixture() { # home
  local home=$1 ev="$1/rosa-idp/ev" inv="$1/rosa-idp/ev/10b-inventory"
  mkdir -p "$inv"
  echo "mock-kubeconfig server=https://api.mock:443" >"$home/rosa-idp/kubeconfig"   # 회수 전 세션
  printf 'CLUSTER_ID=%s\nAPI_URL=https://api.mock:443\nUSER=hayeoung\nSTARTED_AT=x\n' "${BOOT_CLUSTER:-mock-id}" >"$ev/00-target.env"
  printf 'fds-app uid-fds-app\nmonitoring-api uid-monitoring-api\nci-cd uid-ci-cd\n' >"$ev/05-ns-uid.txt"
  echo "${BOOT_SERVER:-https://api.mock:443}" >"$inv/server.txt"
  {
    printf '# access paths for hayeoung\n# scope\tbinding\troleRef.kind\troleRef.name\tsubjects\n'
    if [[ "${FIX_EMPTY_PATHS:-0}" != 1 ]]; then
      printf 'cluster\tcluster-admins\tClusterRole\tcluster-admin\tGroup:cluster-admins\n'
      printf 'cluster\tself-provisioners\tClusterRole\tself-provisioner\tGroup:system:authenticated:oauth\n'
      for ns in fds-app monitoring-api ci-cd; do printf '%s\thayeoung-admin\tClusterRole\tadmin\tUser:hayeoung\n' "$ns"; done
      printf 'cluster\thayeoung-clusterversion-reader\tClusterRole\tfds-clusterversion-reader\tUser:hayeoung\n'   # #5 6258874244
      [[ "${FIX_HIDDEN:-0}" == 1 ]] && printf 'cluster\thidden-direct\tClusterRole\tsudoer\tUser:hayeoung\n'
    fi
  } >"$inv/access-paths-hayeoung.tsv"
  for r in cluster-admin self-provisioner admin sudoer; do echo '{"kind":"ClusterRole"}' >"$inv/clusterrole-$r.json"; done
  echo '{"kind":"ClusterRole","rules":[{"apiGroups":["config.openshift.io"],"resources":["clusterversions"],"resourceNames":["version"],"verbs":["get"]}]}' >"$inv/clusterrole-fds-clusterversion-reader.json"
  ( cd "$inv" && sha256sum -- *.json *.txt *.tsv >SHA256SUMS )
  printf 'APPROVED\tfds-app\thayeoung-admin\n' >"$ev/10b-path-review.tsv"
  {
    printf 'RECEIPT_VERSION=1\nSTATUS=%s\nFINAL_RC=%s\n' "${RC_STATUS:-COMPLETE}" "${RC_FINAL:-0}"
    printf 'CLUSTER_ID=mock-id\nAPI_URL=https://api.mock:443\nUSER=hayeoung\nREVOKE_VERIFIED_AT=x\n'
    printf 'OLD_KUBECONFIG_SHA256=%s\n' "$(sha "$home/rosa-idp/kubeconfig")"
    printf 'TARGET_SHA256=%s\n' "$(sha "$ev/00-target.env")"
    [[ "${RC_NO_UID:-0}" == 1 ]] || printf 'NS_UID_SHA256=%s\n' "$(sha "$ev/05-ns-uid.txt")"
    printf 'INVENTORY_SUMS_SHA256=%s\n' "$(sha "$inv/SHA256SUMS")"
    printf 'PATH_REVIEW_SHA256=%s\n' "$(sha "$ev/10b-path-review.tsv")"
  } >"$ev/99-receipt.env"
  # receipt 발행 뒤 변조·누락 주입
  [[ "${NO_RECEIPT:-0}" == 1 ]] && rm -f "$ev/99-receipt.env"
  # receipt 값 자체의 결함(생산자 버그 가정): 빈 해시 / 형식 오류 해시
  [[ "${RC_EMPTY_OLD:-0}" == 1 ]] && sed -i 's/^OLD_KUBECONFIG_SHA256=.*/OLD_KUBECONFIG_SHA256=/' "$ev/99-receipt.env"
  [[ "${RC_BAD_HASH:-0}" == 1 ]] && sed -i 's/^TARGET_SHA256=.*/TARGET_SHA256=zzzz/' "$ev/99-receipt.env"
  # receipt 발행 뒤 namespace UID 원본을 다른 값으로 교체(현재 UID 도 같은 값으로 맞춰 UID 비교만으로는 못 잡게 함)
  [[ "${TAMPER_UID:-0}" == 1 ]] && sed -i 's/^fds-app .*/fds-app uid-other/' "$ev/05-ns-uid.txt"
  [[ "${TAMPER_REVIEW:-0}" == 1 ]] && printf 'APPROVED\tci-cd\thayeoung-admin\n' >>"$ev/10b-path-review.tsv"
  [[ "${TAMPER_INV:-0}" == 1 ]] && echo '{"kind":"ClusterRole","rules":[{"verbs":["*"]}]}' >"$inv/clusterrole-self-provisioner.json"
  [[ "${SWAP_OLD:-0}" == 1 ]] && echo "other-session" >"$home/rosa-idp/kubeconfig"
  [[ "${NO_OLD:-0}" == 1 ]] && rm -f "$home/rosa-idp/kubeconfig"
  return 0
}

fail=0
case_() { # name expect_rc [env...]   — 환경변수 주입은 fixture 와 실행 양쪽에 같이 적용
  local name=$1 expect=$2; shift 2
  local home="$T/h-$name" log="$T/$name.log"; : >"$log"
  # 인자 없는 `export` 는 환경변수 전체를 출력한다(인증 토큰 포함) → 인자가 있을 때만 export
  ( if [[ $# -gt 0 ]]; then export "$@"; fi; mk_fixture "$home" ) >/dev/null
  env PATH="$T/bin:$PATH" HOME="$home" MOCK_LOG="$log" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
      POLICY_FILE="$T/policy.tsv" KIT_DIR="$HERE" "$@" \
    bash "$HERE/post-revoke-check.sh" "$home/rosa-idp/ev" >/dev/null 2>"$T/$name.err"
  local rc=$? old_left=no new_left=no
  [[ -f "$home/rosa-idp/kubeconfig" ]] && old_left=yes
  [[ -e "$home/rosa-idp/kubeconfig-d11" ]] && new_left=yes
  # 새 세션 kubeconfig 는 어떤 결과든 남으면 안 됨. 회수 전 세션은 PASS(rc0)면 지워지고, FAIL 이면 조사용으로 남는다.
  local ok=PASS
  [[ $rc == "$expect" && $new_left == no ]] || ok=FAIL
  if [[ $rc == 0 ]]; then
    [[ $old_left == no ]] || ok=FAIL
    # PASS 회차엔 판정 입력 기록(policy·분류기 해시)이 있어야 함(비차단 보완)
    grep -qE '^CLASSIFIER_SHA256=[0-9a-f]{64}$' "$home"/rosa-idp/d11-*/00-judgement-inputs.env 2>/dev/null || ok=FAIL
    grep -qE '^POLICY_SHA256=[0-9a-f]{64}$' "$home"/rosa-idp/d11-*/00-judgement-inputs.env 2>/dev/null || ok=FAIL
  fi
  [[ "$ok" == PASS ]] || fail=1
  printf '%-30s rc=%-2s expect=%-2s old_kubeconfig_left=%-3s new_kubeconfig_left=%-3s => %s\n' \
    "$name" "$rc" "$expect" "$old_left" "$new_left" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s) / jq $(jq --version 2>/dev/null || echo MISSING)"
case_ P1_normal                     0
case_ P2_old_session_admin          1 MOCK_OLD=allow           # 회수 전 세션이 여전히 관리자 → CLEANUP_REQUIRED
case_ P3_old_session_401            0 MOCK_OLD=unauth          # 회수 전 세션 401 은 허용(D-11a·c 와 결합)
case_ P4_new_nodes_401              1 MOCK_NEW_NODES=unauth    # 새 세션 401 은 D-11a PASS 아님
case_ P5_new_star_yes               1 MOCK_NEW_STAR=yes        # SSAR '*' '*' yes
case_ P6_mgmt_still_admin           1 MOCK_USERS_MODE=admin
case_ P7_mgmt_format_unknown        1 MOCK_USERS_MODE=broken
case_ P8_hidden_path_recheck        1 FIX_HIDDEN=1             # 저장 인벤토리에 숨은 직접 binding → 오프라인 재판정 STOP
case_ P9_no_old_kubeconfig          1 NO_OLD=1
# 대상 불일치(보완 3)
case_ P10_boot_cluster_mismatch     1 BOOT_CLUSTER=other-id
case_ P11_inventory_server_mismatch 1 BOOT_SERVER=https://api.other:443
case_ P12_describe_api_mismatch     1 MOCK_DESCRIBE_API=https://api.other:443
case_ P13_ns_uid_mismatch           1 MOCK_UID_MISMATCH=1
# RBAC 이 아닌 403(보완 5)
case_ P14_old_session_webhook_403   1 MOCK_OLD=hook
case_ P15_new_nodes_webhook_403     1 MOCK_NEW_NODES=hook
# 리뷰 5530426592 R5: 머리글 정상 + 깨진 본문
case_ P16_mgmt_header_broken_body   1 MOCK_USERS_MODE=headerbroken
# 리뷰 5530426592 R3: 완료 receipt·해시·회수 전 세션 결속
case_ P17_no_receipt                1 NO_RECEIPT=1
case_ P18_path_review_tampered      1 TAMPER_REVIEW=1
case_ P19_inventory_tampered        1 TAMPER_INV=1
case_ P20_old_session_swapped       1 SWAP_OLD=1
case_ P21_old_session_other_server  1 MOCK_OLD_SERVER=https://api.other:443
case_ P22_failed_bootstrap_receipt  1 RC_STATUS=FAILED RC_FINAL=1
case_ P23_empty_paths               1 FIX_EMPTY_PATHS=1
# 정책 승인 대기 회차(rc3): policy 가 없으면 STOP, 승인된 policy 가 있으면 오프라인 재판정으로 PASS
case_ P24_pending_without_policy    1 RC_STATUS=POLICY_PENDING RC_FINAL=3 POLICY_FILE="$T/no-such-policy.tsv"
case_ P25_pending_with_policy       0 RC_STATUS=POLICY_PENDING RC_FINAL=3
# 리뷰 5530751510 R3: 해시 실패·빈 값·형식 오류·UID 원본 미결속
case_ P26_consumer_hash_fail        1 MOCK_SHA_FAIL=rosa-idp/kubeconfig   # 회수 전 세션 해시 계산 실패 → 빈 값끼리 같다고 보지 않음
case_ P27_receipt_empty_hash        1 RC_EMPTY_OLD=1
case_ P28_receipt_malformed_hash    1 RC_BAD_HASH=1
case_ P29_ns_uid_file_swapped       1 TAMPER_UID=1 MOCK_UID_MISMATCH=1    # 수정 전: 원본·현재 UID 를 같이 바꾸면 PASS 했음
case_ P30_receipt_without_uid_hash  1 RC_NO_UID=1
# #5 6258874244: 회수 뒤 하영 세션에서 clusterversion/version get 이 안 되면 FAIL(바인딩 누락)
case_ P34_cv_reader_missing_after_revoke 1 MOCK_CV_NOBIND=1
# #5 A단계 실측 빈 목록(INFO 1줄): 이 클러스터 ID·stderr 없음일 때만 부재
case_ P31_mgmt_empty_info_line      0 MOCK_USERS_MODE=noneinfo
case_ P32_mgmt_empty_info_other_id  1 MOCK_USERS_MODE=noneinfo MOCK_EMPTY_ID=other-id
case_ P33_mgmt_empty_info_stderr    1 MOCK_USERS_MODE=noneinfo MOCK_USERS_ERR='WARN: token expiring'
exit "$fail"
