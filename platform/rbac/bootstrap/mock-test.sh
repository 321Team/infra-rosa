#!/usr/bin/env bash
# bootstrap-session.sh MOCK 시험 — 가짜 rosa/oc 로 클라우드·비밀 파일 조작 없이 제어 흐름만 확인.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/rosa" <<'EOF'
#!/usr/bin/env bash
echo "rosa $*" >>"$MOCK_LOG"
case "$1 $2" in
  "describe cluster")
    case "${MOCK_DESCRIBE_MODE:-ok}" in
      ok)     echo "{\"api\":{\"url\":\"${MOCK_DESCRIBE_API:-https://api.mock:443}\"}}" ;;
      noapi)  echo '{"id":"mock-id"}' ;;                       # 형식 불명(api.url 없음)
      broken) echo '<html>bad gateway</html>' ;;
    esac
    exit "${MOCK_DESCRIBE_RC:-0}" ;;
  "grant user")  exit 0 ;;
  "revoke user") exit "${MOCK_REVOKE_RC:-0}" ;;
  "list users")
    case "${MOCK_USERS_MODE:-std}" in
      std)    echo "ID        GROUPS"; echo "gwonuk    dedicated-admins"
              [[ "${MOCK_STILL_ADMIN:-0}" == 1 ]] && echo "hayeoung  cluster-admins" ;;
      header) echo "ID        GROUPS" ;;                       # 정상 빈 목록
      empty)  : ;;                                             # 출력 없음(형식 불명)
      broken) echo "<html>gateway timeout</html>" ;;           # 깨진 출력
    esac
    exit "${MOCK_LIST_RC:-0}" ;;
esac
exit 0
EOF
cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
echo "oc $*" >>"$MOCK_LOG"
deny() { echo "Error from server (Forbidden): mock deny: $*" >&2; exit 1; }

# ── 배포 SA 세션(steps.sh 의 _sa = --kubeconfig=.../sa.kubeconfig): Role 대로 허용, 나머지 403
if [[ "${1:-}" == --kubeconfig=*sa.kubeconfig ]]; then
  shift; a="$*"
  case "$a" in
    "whoami") echo "system:serviceaccount:ci-cd:fds-deployer"; exit 0 ;;
    "auth can-i "*) echo no; exit 1 ;;
    "get pods -n fds-app") exit 0 ;;
    "get secrets -n fds-app") [[ "${MOCK_SA_LEAK:-0}" == 1 ]] && exit 0; deny "$a" ;;   # 26: 권한 누수 주입
    "create deployment "*"-n fds-app --dry-run=server") exit 0 ;;
    "create route edge a04-probe "*) exit 0 ;;
    *) deny "$a" ;;
  esac
fi

# ── 관리자(하영 bootstrap) 세션
# ⑨ `oc auth can-i --list` 는 실제로 권한 표를 출력하고 rc0 (SSAR yes/no 질의와 다름)
if [[ "$1 $2 $3" == "auth can-i --list" ]]; then
  echo "Resources   Non-Resource URLs   Resource Names   Verbs"
  exit 0
fi
# ⑨ J-1~J-8: 이재환 --as 판정(view 3개 ns + fds-app monitoring-edit 가정)
if [[ "$1 $2" == "auth can-i" && "$*" == *"--as=jaehwan"* ]]; then
  case "$*" in
    "auth can-i create servicemonitors.monitoring.coreos.com -n fds-app "*|\
    "auth can-i create prometheusrules.monitoring.coreos.com -n fds-app "*|\
    "auth can-i get pods -n "*) echo yes; exit 0 ;;
    *) echo no; exit 1 ;;
  esac
fi
if [[ "$1 $2" == "auth can-i" ]]; then
  rc="${MOCK_CANI_RC:-1}"
  case "$rc" in 0) echo yes ;; 1) echo no ;; esac
  [[ -n "${MOCK_CANI_ERR:-}" ]] && echo "$MOCK_CANI_ERR" >&2
  exit "$rc"
fi
case "$*" in
  "whoami") echo "${U:-hayeoung}" ;;
  "whoami --show-server") echo "https://api.mock:443" ;;
  "get ns "*"jsonpath="*) [[ "${MOCK_NSUID_RC:-0}" != 0 ]] && exit "$MOCK_NSUID_RC"; echo "uid-$3" ;;
  "get sa -n "*"jsonpath="*) [[ "${MOCK_SA_RC:-0}" != 0 ]] && exit "$MOCK_SA_RC"; echo "default builder deployer" ;;
  "config view "*) : ;;                                     # CA data 없음 → 시스템 신뢰 저장소 경로
  "create token fds-deployer -n ci-cd --duration=900s")
    [[ "${MOCK_TOKEN:-0}" == 1 ]] || exit 93                 # 기본: ⑩ 도달 표시 후 중단(24)
    b64u() { base64 | tr -d '\n=' | tr '+/' '-_'; }
    now=$(date +%s); life="${MOCK_TOKEN_LIFE:-900}"
    printf '%s.%s.sig\n' "$(printf '{"alg":"none"}' | b64u)" \
      "$(printf '{"sub":"system:serviceaccount:ci-cd:fds-deployer","aud":["https://kubernetes.default.svc"],"iat":%s,"exp":%s}' "$now" $((now + life)) | b64u)" ;;
  # ⑩-b 권한 목록 수집용 합성 RBAC
  "get groups -o json") echo '{"items":[{"metadata":{"name":"cluster-admins"},"users":["hayeoung"]}]}' ;;
  "get clusterrolebindings -o json")
    extra=""
    [[ "${MOCK_INV_UNEXPECTED:-0}" == 1 ]] && extra=',{"metadata":{"name":"hidden-direct"},"roleRef":{"kind":"ClusterRole","name":"sudoer"},"subjects":[{"kind":"User","name":"hayeoung"}]}'
    echo '{"items":[{"metadata":{"name":"cluster-admins"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"Group","name":"cluster-admins"}]},
      {"metadata":{"name":"self-provisioners"},"roleRef":{"kind":"ClusterRole","name":"self-provisioner"},"subjects":[{"kind":"Group","name":"system:authenticated:oauth"}]}'"$extra"']}' ;;
  "get rolebindings -n "*" -o json")
    echo '{"items":[{"metadata":{"name":"hayeoung-admin"},"roleRef":{"kind":"ClusterRole","name":"admin"},"subjects":[{"kind":"User","name":"hayeoung"}]}]}' ;;
  "get clusterrole "*" -o json") echo '{"kind":"ClusterRole"}' ;;
esac
exit 0
EOF
chmod +x "$T/bin/rosa" "$T/bin/oc"

mk_steps() { # $1 name, $2 body
  printf 'run_steps() {\n%s\n}\n' "$2" >"$T/$1.sh"
}
mk_steps normal   'echo STEP1 >>"$MOCK_LOG"; echo STEP2 >>"$MOCK_LOG"'
mk_steps fail     'echo STEP1 >>"$MOCK_LOG"; false; echo STEP2_AFTER_FAIL >>"$MOCK_LOG"'
mk_steps int      'echo STEP1 >>"$MOCK_LOG"; kill -INT $$; sleep 1; echo STEP2_AFTER_INT >>"$MOCK_LOG"'
mk_steps term     'echo STEP1 >>"$MOCK_LOG"; kill -TERM $$; sleep 1; echo STEP2_AFTER_TERM >>"$MOCK_LOG"'
mk_steps deadline 'echo STEP1 >>"$MOCK_LOG"; for i in 1 2 3 4 5 6; do sleep 1; done; echo STEP2_AFTER_DEADLINE >>"$MOCK_LOG"'

failures=0

cp "$HERE/steps.sh" "$T/template.sh"   # 실제 단계 파일(가짜 oc 는 manifest 내용을 읽지 않음)

# 기대값(호출 전 변수로 지정): EXP_GRANT/EXP_REVOKE(기본 1), FORBID(로그에 나오면 안 되는 정규식)
run_case() { # name steps expect_rc [env...]
  local name=$1 steps=$2 expect=$3; shift 3
  local log="$T/$name.log"; : >"$log"
  local dl=$(( $(date +%s) + 600 ))
  [[ "$steps" == deadline ]] && dl=$(( $(date +%s) + 2 ))
  env PATH="$T/bin:$PATH" MOCK_LOG="$log" HOME="$T/home-$name" \
      CLUSTER_ID=mock-id API_URL=https://api.mock:443 DEADLINE_EPOCH="$dl" \
      VERIFY_TRIES=2 VERIFY_INTERVAL=0 MANIFEST_DIR="$HERE/../manifests" KIT_DIR="$HERE" "$@" \
      bash "$HERE/bootstrap-session.sh" "$T/$steps.sh" 2>"$T/$name.err"
  local rc=$?
  local after; after=$(grep -c '_AFTER_' "$log" || true)
  local granted; granted=$(grep -c '^rosa grant' "$log" || true)
  local revoked; revoked=$(grep -c '^rosa revoke' "$log" || true)
  local forbid=0; [[ -n "${FORBID:-}" ]] && forbid=$(grep -Ec "$FORBID" "$log" || true)
  local cr; cr=$(grep -c 'CLEANUP_REQUIRED' "$T/$name.err" || true)
  local perm; perm=$(stat -c '%a' "$T/home-$name/rosa-idp" 2>/dev/null || echo NA)
  local ok=PASS
  [[ $rc == "$expect" && $after == 0 && $granted == "${EXP_GRANT:-1}" && $revoked == "${EXP_REVOKE:-1}" && $forbid == 0 ]] || ok=FAIL
  [[ "$ok" == PASS ]] || failures=1
  printf '%-26s rc=%-3s expect=%-3s after=%s grant=%s revoke=%s forbidden=%s CLEANUP_REQUIRED=%s dir_perm=%s => %s\n' \
    "$name" "$rc" "$expect" "$after" "$granted" "$revoked" "$forbid" "$cr" "$perm" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s) / jq $(jq --version 2>/dev/null || echo MISSING)"
# SELFTEST_EXPECT: 하네스 자체 시험용(일부러 틀린 기대값 → 전체 rc1 이어야 함, F3)
run_case 1_normal          normal   "${SELFTEST_EXPECT:-0}"
run_case 2_step_fail       fail     1
run_case 3_int             int      130
run_case 4_term            term     143
run_case 5_deadline        deadline 143
run_case 6_revoke_fail     normal   1 MOCK_REVOKE_RC=42
run_case 7_verify_timeout  normal   1 MOCK_STILL_ADMIN=1
run_case 8_verify_cani_yes normal   1 MOCK_CANI_RC=0
run_case 9_int_and_revoke_fail int  1 MOCK_REVOKE_RC=42
# 리뷰 6164637613 R1: 조회 실패·형식 불명을 회수 성공으로 보면 안 됨
run_case 11_mgmt_query_rc42    normal 1 MOCK_LIST_RC=42
run_case 12_session_timeout42  normal 1 MOCK_CANI_RC=42 MOCK_CANI_ERR="Unable to connect: i/o timeout"
run_case 13_both_rc42          normal 1 MOCK_LIST_RC=42 MOCK_CANI_RC=42
run_case 14_mgmt_empty_output  normal 1 MOCK_USERS_MODE=empty
run_case 15_mgmt_broken_output normal 1 MOCK_USERS_MODE=broken
run_case 16_mgmt_header_only   normal 0 MOCK_USERS_MODE=header
run_case 17_session_401        normal 1 MOCK_CANI_RC=1 MOCK_CANI_ERR="error: You must be logged in to the server (Unauthorized)"
# 리뷰 6168044536 F1: 대상 결속 실패면 grant·revoke·apply 0회
EXP_GRANT=0 EXP_REVOKE=0 FORBID='^oc apply' run_case 18_api_mismatch     normal 1 MOCK_DESCRIBE_API=https://api.other:443
EXP_GRANT=0 EXP_REVOKE=0 FORBID='^oc apply' run_case 19_describe_rc42     normal 1 MOCK_DESCRIBE_RC=42
EXP_GRANT=0 EXP_REVOKE=0 FORBID='^oc apply' run_case 20_describe_no_api   normal 1 MOCK_DESCRIBE_MODE=noapi
EXP_GRANT=0 EXP_REVOKE=0 FORBID='^oc apply' run_case 21_describe_broken   normal 1 MOCK_DESCRIBE_MODE=broken
# 리뷰 6168044536 F2: steps.sh 실제 단계로, 조회 실패 뒤 후속 쓰기·token 0회 + revoke 1회
FORBID='rbac\.yaml|human-bindings|create token' run_case 22_tmpl_nsuid_rc42 template 1 MOCK_NSUID_RC=42
FORBID='create token'                           run_case 23_tmpl_sa_rc42    template 1 MOCK_SA_RC=42
# 대조: 정상 template 은 ⑩(create token, 가짜 rc93)까지 도달한 뒤 회수 — 단계 연결 확인용
run_case 24_tmpl_reaches_token template 93
# steps.sh 완성본: ⑩ 실제 SA 시험·⑩-b 경로 검토까지 끝까지
run_case 25_steps_full_success   template 0 MOCK_TOKEN=1
FORBID='^oc get groups -o json' run_case 26_sa_secret_leak_stops template 1 MOCK_TOKEN=1 MOCK_SA_LEAK=1   # D-03a 기대 위반 → ⑩-b 전에 STOP
FORBID='^oc --kubeconfig=' run_case 27_token_life_3600_stops template 1 MOCK_TOKEN=1 MOCK_TOKEN_LIFE=3600 # claim 900초 초과 → SA 요청 0회
run_case 28_inventory_unexpected template 1 MOCK_TOKEN=1 MOCK_INV_UNEXPECTED=1                          # 숨은 직접 binding → 회수 전 STOP
unset FORBID

# 10: 로그를 파이프(tee)로 받을 때 watchdog 가 파이프를 붙잡지 않는지(마감 600초인데 즉시 끝나야 함)
: >"$T/10.log"; start=$(date +%s)
env PATH="$T/bin:$PATH" MOCK_LOG="$T/10.log" HOME="$T/home-10" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
    DEADLINE_EPOCH=$(( $(date +%s) + 600 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 \
    bash "$HERE/bootstrap-session.sh" "$T/normal.sh" 2>&1 | tee "$T/10.out" >/dev/null
rc=${PIPESTATUS[0]}; el=$(( $(date +%s) - start ))
ok=PASS
[[ $rc == 0 && $el -lt 20 ]] || { ok=FAIL; failures=1; }
printf '%-22s rc=%-3s elapsed=%ss (deadline 600s) => %s\n' 10_pipe_no_hang "$rc" "$el" "$ok"
exit "$failures"
