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
  "grant user")  [[ "${MOCK_GRANT_NOPROP:-0}" == 1 ]] || : >"$MOCK_LOG.granted"; exit 0 ;;   # 55: 반영 안 됨 주입
  "revoke user")
    # 29: 실제 Ctrl+C 처럼 자기 프로세스 그룹 전체(래퍼+rosa)에 INT. 회수 중 무시가 상속되면 rosa 도 끝까지 간다.
    if [[ "${MOCK_INT_DURING_REVOKE:-0}" == 1 ]]; then kill -INT 0; sleep 0.3; echo "MOCK: revoke survived INT" >>"$MOCK_LOG"; fi
    [[ "${MOCK_REVOKE_RC:-0}" == 0 ]] && rm -f "$MOCK_LOG.granted"
    exit "${MOCK_REVOKE_RC:-0}" ;;
  "list users")
    case "${MOCK_USERS_MODE:-std}" in
      std)    echo "ID        GROUPS"; echo "gwonuk    dedicated-admins"
              [[ "${MOCK_STILL_ADMIN:-0}" == 1 ]] && echo "hayeoung  cluster-admins" ;;
      header) echo "ID        GROUPS" ;;                       # 정상 빈 목록
      headerbroken) echo "ID        GROUPS"; echo "<html>gateway timeout</html>" ;;   # 32: 머리글 정상 + 깨진 본문(R5)
      nogroup) echo "ID        GROUPS"; echo "hayeoung" ;;                            # 33: 그룹 열 없는 행(R5)
      empty)  : ;;                                             # 출력 없음(형식 불명)
      broken) echo "<html>gateway timeout</html>" ;;           # 깨진 출력
      # 44~48: 실측 빈 목록(#5 A단계 2026-10-18) — 머리글 없이 INFO 1줄(stdout)
      noneinfo)  echo "INFO: There are no users configured for cluster '${MOCK_EMPTY_ID:-mock-id}'" ;;
      noneinfo2) echo "INFO: There are no users configured for cluster '${MOCK_EMPTY_ID:-mock-id}'"; echo "hayeoung  cluster-admins" ;;
    esac
    [[ -n "${MOCK_USERS_ERR:-}" ]] && echo "$MOCK_USERS_ERR" >&2
    exit "${MOCK_LIST_RC:-0}" ;;
esac
exit 0
EOF
cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
echo "oc $*" >>"$MOCK_LOG"
# 실제 RBAC 거부 형식: ... is forbidden: User "<주체>" cannot <verb> resource "<res>" ...
deny() { echo "Error from server (Forbidden): mock is forbidden: User \"system:serviceaccount:ci-cd:fds-deployer\" cannot get resource \"mock\" in API group \"\"" >&2; exit 1; }

# ── 배포 SA 세션(steps.sh 의 _sa = --kubeconfig=.../sa.kubeconfig): Role 대로 허용, 나머지 403
if [[ "${1:-}" == --kubeconfig=*sa.kubeconfig ]]; then
  shift; a="$*"
  case "$a" in
    "whoami") echo "system:serviceaccount:ci-cd:fds-deployer"; exit 0 ;;
    "auth can-i "*) echo no; exit 1 ;;
    "get pods -n fds-app") exit 0 ;;
    "get secrets -n fds-app") [[ "${MOCK_SA_LEAK:-0}" == 1 ]] && exit 0; deny "$a" ;;   # 26: 권한 누수 주입
    # 30: RBAC 이 아닌 이유(quota)의 403 — 권한이 있는데 다른 이유로 막힌 것을 '정상 거부'로 보면 안 됨(보완 5)
    "create deployment d01-probe "*)
      if [[ "${MOCK_SA_QUOTA:-0}" == 1 ]]; then
        echo 'Error from server (Forbidden): deployments.apps "d01-probe" is forbidden: exceeded quota: compute-resources' >&2; exit 1
      fi
      deny "$a" ;;
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
# H-1~H-3: 하영 clusterversion/version get 최소 권한(--as=hayeoung, cluster-admins 그룹 없이). MOCK_CV_NOBIND = 바인딩 누락
if [[ "$1 $2" == "auth can-i" && "$*" == *"--as=hayeoung"* ]]; then
  case "$*" in
    "auth can-i get clusterversions.config.openshift.io/version "*) [[ "${MOCK_CV_NOBIND:-0}" == 1 ]] && { echo no; exit 1; }; echo yes; exit 0 ;;
    *) echo no; exit 1 ;;
  esac
fi
if [[ "$1 $2" == "auth can-i" ]]; then
  # 기본: grant 상태 파일이 있으면 yes(반영됨), 없으면 no. MOCK_CANI_RC 를 주면 그 값으로 고정(회수 확인 실패 주입용)
  if [[ -n "${MOCK_CANI_RC:-}" ]]; then rc=$MOCK_CANI_RC; elif [[ -e "$MOCK_LOG.granted" ]]; then rc=0; else rc=1; fi
  case "$rc" in 0) echo yes ;; 1) echo no ;; esac
  [[ -n "${MOCK_CANI_ERR:-}" ]] && echo "$MOCK_CANI_ERR" >&2
  exit "$rc"
fi
case "$*" in
  "whoami") echo "${U:-hayeoung}" ;;
  "login "*) echo "mock-kubeconfig server=https://api.mock:443" >"$KUBECONFIG" ;;   # 실제 oc login 처럼 kubeconfig 생성(receipt 지문용)
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
  # ④ 인계표 1·3번(clusterversion·nodes) — 49~51 실패 주입
  "get clusterversion version -o json")
    [[ "${MOCK_CV_RC:-0}" != 0 ]] && exit "$MOCK_CV_RC"
    [[ "${MOCK_CV_EMPTY:-0}" == 1 ]] && { echo '{"spec":{},"status":{}}'; exit 0; }
    echo '{"spec":{"clusterID":"00000000-0000-4000-8000-00000000mock"},"status":{"desired":{"version":"4.22.17"}}}' ;;
  "get nodes -o json")
    [[ "${MOCK_NODES_EMPTY:-0}" == 1 ]] && { echo '{"items":[]}'; exit 0; }
    echo '{"items":['
    echo '{"metadata":{"name":"ip-10-0-1-1.mock"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},'
    echo '{"metadata":{"name":"ip-10-0-1-2.mock"},"status":{"conditions":[{"type":"Ready","status":"True"}]}},'
    echo '{"metadata":{"name":"ip-10-0-1-3.mock"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  "get nodes -o wide") echo "NAME STATUS ROLES" ;;
  # ⑩-b 권한 목록 수집용 합성 RBAC
  "get groups -o json") echo '{"items":[{"metadata":{"name":"cluster-admins"},"users":["hayeoung"]}]}' ;;
  "get clusterrolebindings -o json")
    extra=""
    [[ "${MOCK_INV_UNEXPECTED:-0}" == 1 ]] && extra=',{"metadata":{"name":"hidden-direct"},"roleRef":{"kind":"ClusterRole","name":"sudoer"},"subjects":[{"kind":"User","name":"hayeoung"}]}'
    # 31: 로그인한 모든 사람에게 cluster-admin — 주체만 보면 '플랫폼 기본'처럼 보이는 위험 경로(보완 2)
    [[ "${MOCK_INV_AUTH_ADMIN:-0}" == 1 ]] && extra=',{"metadata":{"name":"authenticated-admin"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"Group","name":"system:authenticated"}]}'
    echo '{"items":[{"metadata":{"name":"cluster-admins"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"Group","name":"cluster-admins"}]},
      {"metadata":{"name":"self-provisioners"},"roleRef":{"kind":"ClusterRole","name":"self-provisioner"},"subjects":[{"kind":"Group","name":"system:authenticated:oauth"}]},
      {"metadata":{"name":"hayeoung-clusterversion-reader"},"roleRef":{"kind":"ClusterRole","name":"fds-clusterversion-reader"},"subjects":[{"kind":"User","name":"hayeoung"}]}'"$extra"']}' ;;
  "get rolebindings -n "*" -o json")
    echo '{"items":[{"metadata":{"name":"hayeoung-admin"},"roleRef":{"kind":"ClusterRole","name":"admin"},"subjects":[{"kind":"User","name":"hayeoung"}]}]}' ;;
  "get clusterrole self-provisioner -o json")   # 32x: 승인 목록 이름이지만 규칙이 바뀐 경우(R1)
    if [[ "${MOCK_SP_RULES:-0}" == 1 ]]; then echo '{"kind":"ClusterRole","rules":[{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]}]}'; else echo '{"kind":"ClusterRole"}'; fi ;;
  "get clusterrole fds-clusterversion-reader -o json")   # 53: 키트 ClusterRole 규칙이 넓어진 경우(list 추가)
    v='"get"'; [[ "${MOCK_CV_RULES_WIDE:-0}" == 1 ]] && v='"get","list"'
    echo '{"kind":"ClusterRole","rules":[{"apiGroups":["config.openshift.io"],"resources":["clusterversions"],"resourceNames":["version"],"verbs":['"$v"']}]}' ;;
  "get clusterrole "*" -o json") echo '{"kind":"ClusterRole"}' ;;
esac
exit 0
EOF
chmod +x "$T/bin/rosa" "$T/bin/oc"
# 실패 주입용 sha256sum / mv: 지정한 경우에만 실패하고, 그 밖에는 진짜 명령으로 넘긴다(리뷰 5530751510 R3)
real_sha=$(command -v sha256sum); real_mv=$(command -v mv)
printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ -n "${MOCK_SHA_FAIL:-}" && "$a" == *"$MOCK_SHA_FAIL" ]] && { echo "mock sha256sum failure" >&2; exit 42; }; done\nexec %q "$@"\n' "$real_sha" >"$T/bin/sha256sum"
printf '#!/usr/bin/env bash\n[[ "${MOCK_MV_FAIL:-0}" == 1 && "$*" == *99-receipt.env* ]] && { echo "mock mv failure" >&2; exit 1; }\nexec %q "$@"\n' "$real_mv" >"$T/bin/mv"
real_cp=$(command -v cp)
printf '#!/usr/bin/env bash
[[ "${MOCK_CP_FAIL:-0}" == 1 && "$*" == *verify-users.* ]] && { echo "mock cp failure" >&2; exit 1; }
exec %q "$@"
' "$real_cp" >"$T/bin/cp"   # PR#43 S3: 원본 복사 실패 주입
chmod +x "$T/bin/sha256sum" "$T/bin/mv" "$T/bin/cp"

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

# 시험용 승인 policy: 가짜 인벤토리의 기본 binding(self-provisioners) 1행. 규칙 해시는 분류기와 같은 정규화로 계산.
# (실제 policy 는 AFTER-CREATE 증적을 보고 PR 리뷰로 만든다 — 이 파일은 시험 전용)
sp_sha=$(printf '{"kind":"ClusterRole"}' | jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' | sha256sum | cut -d' ' -f1)
printf '# test policy\ncluster\tself-provisioners\tClusterRole\tself-provisioner\tGroup:system:authenticated:oauth\t%s\n' "$sp_sha" >"$T/policy.tsv"

# 대조용 '수정 전 분류기' 키트: 3a3958e 의 규칙(이름·주체만 보고 namespace 는 cluster 가 아니면 승인)을 재현한 사본
mkdir -p "$T/kit-nofix"; cp "$HERE"/*.sh "$T/kit-nofix/"
perl -pi -e 's/^  elif \[\[ " \$APPROVED_NAMESPACES " == \*" \$scope "\* && /  elif [[ "\$scope" != cluster && /; s/^(  elif \[\[ "\$kind" == ClusterRole && "\$subjects" =~ \$auth_re \]\]; then)$/$1 c=PLATFORM_DEFAULT; elif false; then/' "$T/kit-nofix/classify-access-paths.sh"
cmp -s "$HERE/classify-access-paths.sh" "$T/kit-nofix/classify-access-paths.sh" && { echo "FAIL: 대조 분류기 사본이 원본과 같음(치환 실패)"; failures=1; }

# 기대값(호출 전 변수로 지정): EXP_GRANT/EXP_REVOKE(기본 1), FORBID(로그에 나오면 안 되는 정규식),
#   REQUIRE_ERR(래퍼 stderr 에 반드시 있어야 하는 정규식), USE_SETSID=1(별도 프로세스 그룹에서 실행 — 그룹 신호 시험용)
skipped=0
run_case() { # name steps expect_rc [env...]
  local name=$1 steps=$2 expect=$3; shift 3
  local log="$T/$name.log"; : >"$log"
  local dl=$(( $(date +%s) + 600 ))
  [[ "$steps" == deadline ]] && dl=$(( $(date +%s) + 2 ))
  local pre=()
  if [[ "${USE_SETSID:-0}" == 1 ]]; then
    if [[ "${FORCE_SKIP_SETSID:-0}" != 1 ]] && setsid --help 2>&1 | grep -q -- '--wait'; then pre=(setsid --wait)
    else printf '%-26s => SKIP (setsid --wait 없음 — Linux 에서 실행 필요)\n' "$name"; skipped=1; return; fi
  fi
  "${pre[@]}" env PATH="$T/bin:$PATH" MOCK_LOG="$log" HOME="$T/home-$name" \
      CLUSTER_ID=mock-id API_URL=https://api.mock:443 DEADLINE_EPOCH="$dl" \
      VERIFY_TRIES=2 VERIFY_INTERVAL=0 GRANT_WAIT_INTERVAL=0 MANIFEST_DIR="$HERE/../manifests" KIT_DIR="$HERE" POLICY_FILE="$T/policy.tsv" "$@" \
      bash "${WRAPPER:-$HERE/bootstrap-session.sh}" "$T/$steps.sh" 2>"$T/$name.err"
  local rc=$?
  local after; after=$(grep -c '_AFTER_' "$log" || true)
  local granted; granted=$(grep -c '^rosa grant' "$log" || true)
  local revoked; revoked=$(grep -c '^rosa revoke' "$log" || true)
  local forbid=0; [[ -n "${FORBID:-}" ]] && forbid=$(grep -Ec "$FORBID" "$log" || true)
  local cr; cr=$(grep -c 'CLEANUP_REQUIRED' "$T/$name.err" || true)
  local perm; perm=$(stat -c '%a' "$T/home-$name/rosa-idp" 2>/dev/null || echo NA)
  local req=1; [[ -n "${REQUIRE_ERR:-}" ]] && req=$(grep -Ec "$REQUIRE_ERR" "$T/$name.err" || true)
  local fe=0; [[ -n "${FORBID_ERR:-}" ]] && fe=$(grep -Ec "$FORBID_ERR" "$T/$name.err" || true)
  local rcok=0   # expect 가 nonzero 면 0 이 아닌 모든 rc 를 인정(신호 종료 rc 는 환경마다 다를 수 있음)
  if [[ "$expect" == nonzero ]]; then [[ $rc != 0 ]] && rcok=1; else [[ $rc == "$expect" ]] && rcok=1; fi
  # 보완 1: 어떤 경우든 끝난 뒤 SA token 원문·SA kubeconfig 가 남으면 FAIL
  local left=0 f
  for f in t sa.kubeconfig; do [[ -e "$T/home-$name/rosa-idp/$f" ]] && left=$((left + 1)); done
  local ok=PASS
  [[ $rcok == 1 && $after == 0 && $granted == "${EXP_GRANT:-1}" && $revoked == "${EXP_REVOKE:-1}" && $forbid == 0 && $req -ge 1 && $fe == 0 && $left == 0 ]] || ok=FAIL
  [[ "$ok" == PASS ]] || failures=1
  printf '%-26s rc=%-3s expect=%-3s after=%s grant=%s revoke=%s forbidden=%s token_files_left=%s CLEANUP_REQUIRED=%s dir_perm=%s => %s\n' \
    "$name" "$rc" "$expect" "$after" "$granted" "$revoked" "$forbid" "$left" "$cr" "$perm" "$ok"
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
# PR#37 리뷰(이재환 #1): 회수(revoke) 도중 Ctrl+C(프로세스 그룹 INT)가 와도 회수·확인을 끝까지 하고 기록을 남긴다
USE_SETSID=1 REQUIRE_ERR='REVOKE_VERIFIED' run_case 29_ctrl_c_during_revoke normal 0 MOCK_INT_DURING_REVOKE=1
# 대조(29b): 회수 중 무시(trap '' INT TERM)를 뺀 사본은 같은 상황에서 INT 로 죽어야 한다 — 29 가 의미 있는 시험인지 확인
grep -v "^  trap '' INT TERM$" "$HERE/bootstrap-session.sh" >"$T/wrapper-nofix.sh"
WRAPPER="$T/wrapper-nofix.sh" USE_SETSID=1 FORBID_ERR='REVOKE_VERIFIED' run_case 29b_without_fix_dies normal nonzero MOCK_INT_DURING_REVOKE=1

# PR#40 보완 5: RBAC 이 아닌 403(quota)을 '정상 거부'로 보지 않음 → D-01 에서 STOP
run_case 30_quota_403_not_rbac_deny template 1 MOCK_TOKEN=1 MOCK_SA_QUOTA=1
# 대조(30b): 'Forbidden' 만 보던 수정 전 분류는 같은 주입을 정상 거부로 보고 끝까지 통과해 버린다
perl -0pe 's/elif grep -q \x27\(Forbidden\)\x27 "\$errf" && grep -qF [^\n]*\n[^\n]*then echo DENY/elif grep -q \x27(Forbidden)\x27 "\$errf"; then echo DENY/' "$HERE/steps.sh" >"$T/nofix5.sh"
cmp -s "$HERE/steps.sh" "$T/nofix5.sh" && { echo "FAIL: 30b 대조 사본이 원본과 같음(치환 실패)"; failures=1; }
run_case 30b_without_fix_passes nofix5 0 MOCK_TOKEN=1 MOCK_SA_QUOTA=1
# 리뷰 5530426592 R1: 분류는 범위·binding·roleRef·주체·실제 규칙까지 대조. 각 반례 → 회수 전 STOP, 대조(b)는 수정 전 분류로 통과
run_case 31_auth_group_admin_stops      template 1 MOCK_TOKEN=1 MOCK_INV_AUTH_ADMIN=1              # authenticated 에 cluster-admin
run_case 31b_without_fix_passes         template 0 MOCK_TOKEN=1 MOCK_INV_AUTH_ADMIN=1 KIT_DIR="$T/kit-nofix"
run_case 32_sp_rules_changed_stops      template 1 MOCK_TOKEN=1 MOCK_SP_RULES=1                    # 같은 이름, 규칙에 secrets get 추가
run_case 32b_without_fix_passes         template 0 MOCK_TOKEN=1 MOCK_SP_RULES=1 KIT_DIR="$T/kit-nofix"
run_case 33_fourth_namespace_stops      template 1 MOCK_TOKEN=1 NAMESPACES="fds-app monitoring-api ci-cd extra-scope"
run_case 33b_without_fix_passes         template 0 MOCK_TOKEN=1 NAMESPACES="fds-app monitoring-api ci-cd extra-scope" KIT_DIR="$T/kit-nofix"
run_case 34_policy_pending_rc3          template 3 MOCK_TOKEN=1 POLICY_FILE="$T/no-such-policy.tsv"   # policy 미승인 → 회수 후 rc3
run_case 35_policy_malformed_stops      template 1 MOCK_TOKEN=1 POLICY_FILE="$HERE/README.md"          # 형식 오류 policy → STOP
# 리뷰 5530426592 R5: 머리글 정상 + 깨진/불완전 본문은 '부재'가 아님 → 회수 확인 UNKNOWN → CLEANUP_REQUIRED
run_case 36_mgmt_header_broken_body     normal   1 MOCK_USERS_MODE=headerbroken
run_case 37_mgmt_row_without_groups     normal   1 MOCK_USERS_MODE=nogroup
# 리뷰 5530751510 R3: receipt 해시 계산 실패·확정(rename) 실패 → 완료 receipt 없음, rc1 (회수는 정상)
REQUIRE_ERR='RECEIPT: 회수 전 세션 해시 실패' run_case 42_receipt_hash_fail template 1 MOCK_TOKEN=1 MOCK_SHA_FAIL=rosa-idp/kubeconfig
REQUIRE_ERR='RECEIPT: 확정\(rename\) 실패'      run_case 43_receipt_rename_fail template 1 MOCK_TOKEN=1 MOCK_MV_FAIL=1
# #5 A단계 실측(2026-10-18): 빈 목록은 머리글 없이 INFO 1줄. 정확히 이 클러스터 ID·1줄·stderr 없음·rc0 일 때만 부재
REQUIRE_ERR='REVOKE_VERIFIED' run_case 44_mgmt_empty_info_line normal 0 MOCK_USERS_MODE=noneinfo
run_case 45_mgmt_empty_info_other_id    normal 1 MOCK_USERS_MODE=noneinfo MOCK_EMPTY_ID=other-id
run_case 46_mgmt_empty_info_stderr      normal 1 MOCK_USERS_MODE=noneinfo MOCK_USERS_ERR='WARN: token expiring'
run_case 47_mgmt_empty_info_extra_line  normal 1 MOCK_USERS_MODE=noneinfo2
run_case 48_mgmt_empty_info_rc42        normal 1 MOCK_USERS_MODE=noneinfo MOCK_LIST_RC=42
# 인계표 1·3번 읽기 실패·값 없음 → ⑤ 적용·token 전에 STOP, 회수 1회
FORBID='^oc apply|create token' run_case 49_tmpl_clusterversion_rc42 template 1 MOCK_CV_RC=42
FORBID='^oc apply|create token' run_case 50_tmpl_clusterversion_no_uuid template 1 MOCK_CV_EMPTY=1
FORBID='^oc apply|create token' run_case 51_tmpl_no_nodes template 1 MOCK_NODES_EMPTY=1
# PR#43 리뷰 S3: 회수 판정 원본 복사 실패 → 완료로 보고하지 않음(rc1, receipt 없음). 회수 자체는 정상(revoke 1)
REQUIRE_ERR='EVIDENCE_COPY_FAILED' run_case 52_revoke_evidence_copy_fail template 1 MOCK_TOKEN=1 MOCK_CP_FAIL=1
# #5 6258874244: 하영 clusterversion/version get 최소 권한. 키트 ClusterRole 규칙이 넓어지면 회수 전 STOP, 바인딩이 빠지면 H-1 에서 STOP
run_case 53_cv_reader_rules_widened_stops template 1 MOCK_TOKEN=1 MOCK_CV_RULES_WIDE=1
FORBID='create token' run_case 54_cv_reader_binding_missing_stops template 1 MOCK_TOKEN=1 MOCK_CV_NOBIND=1
# #5 2회차 6262238397: grant 가 세션에 반영되지 않으면 래퍼 안 대기 후 첫 단계 전에 STOP(→ 회수 1회)
FORBID='^oc apply|create token' REQUIRE_ERR='grant 반영 대기 시간 초과' run_case 55_grant_not_effective_stops template 1 MOCK_GRANT_NOPROP=1 GRANT_WAIT_TRIES=2
unset FORBID REQUIRE_ERR

# 56: #5 2회차 재현 — 화면 파이프(tee)가 먼저 끊긴 뒤에도 회수(revoke)·회수 확인을 끝까지 한다.
#     읽는 쪽이 첫 바이트만 읽고 끝나면(head -c1) 이후 래퍼의 화면 쓰기는 SIGPIPE 를 받는다.
#     대조(56b): PIPE 처리를 뺀 사본은 같은 상황에서 revoke 없이 죽어야 한다 — 56 이 의미 있는 시험인지 확인.
mk_steps slow 'echo STEP1 >>"$MOCK_LOG"; sleep 1; echo STEP2 >&2; sleep 1; echo STEP3 >>"$MOCK_LOG"'
sed -e "/^trap 'exit 141' PIPE\$/d" -e "s/^  trap '' INT TERM PIPE\$/  trap '' INT TERM/" "$HERE/bootstrap-session.sh" >"$T/wrapper-nopipe.sh"
cmp -s "$HERE/bootstrap-session.sh" "$T/wrapper-nopipe.sh" && { echo "FAIL: 56b 대조 사본이 원본과 같음(치환 실패)"; failures=1; }
pipe_case() { # name wrapper expect(revoked|died)
  local name=$1 w=$2 want=$3 log="$T/$1.log"; : >"$log"
  env PATH="$T/bin:$PATH" MOCK_LOG="$log" HOME="$T/home-$name" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
      DEADLINE_EPOCH=$(( $(date +%s) + 600 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 \
      bash "$w" "$T/slow.sh" 2>&1 | head -c 1 >/dev/null
  local rc=${PIPESTATUS[0]}
  local rv; rv=$(grep -c '^rosa revoke' "$log" || true)
  local vf; vf=$(grep -c 'REVOKE_VERIFIED' "$T/home-$name/rosa-idp/session-events.log" 2>/dev/null || true)
  local ok=FAIL
  if [[ $want == revoked ]]; then [[ $rv == 1 && $vf -ge 1 ]] && ok=PASS
  else [[ $rv == 0 && $rc == 141 ]] && ok=PASS; fi
  [[ "$ok" == PASS ]] || failures=1
  printf '%-26s rc=%-3s revoke=%s events_REVOKE_VERIFIED=%s expect=%s => %s\n' "$name" "$rc" "$rv" "$vf" "$want" "$ok"
}
pipe_case 56_pipe_closed_still_revokes "$HERE/bootstrap-session.sh" revoked
pipe_case 56b_without_fix_dies        "$T/wrapper-nopipe.sh"        died

# 증적 확인(보완 3·4, 리뷰 R3): 25 정상 회차 / 34 정책 대기 회차의 target·read-rc·분류·receipt
ev_of() { ls -d "$T"/home-"$1"/rosa-idp/evidence-* 2>/dev/null | head -1; }
ev25=$(ev_of 25_steps_full_success); ev34=$(ev_of 34_policy_pending_rc3)
ok=PASS
# PR#43 리뷰 S3: 회수 판정·결속 원본이 증적 폴더(11-revoke-verify)에 복사되고 SHA256SUMS 로 검산된다(정상·정책대기·실패 회차)
for e in "$ev25" "$ev34" "$(ev_of 28_inventory_unexpected)"; do
  d="$e/11-revoke-verify"
  [[ -s "$d/preflight-cluster.json" && -s "$d/verify-users.1.out" && -e "$d/verify-cani.1.out" && -s "$d/SHA256SUMS" ]] || { ok=FAIL; echo "  S3: 원본 누락 $d"; continue; }
  ( cd "$d" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 || { ok=FAIL; echo "  S3: SHA256SUMS 불일치 $d"; }
done
grep -qx 'CLUSTER_ID=mock-id' "$ev25/00-target.env" 2>/dev/null && grep -qx 'USER=hayeoung' "$ev25/00-target.env" || ok=FAIL
[[ $(grep -c ' rc=' "$ev25/04-read-rc.txt" 2>/dev/null) == 2 ]] || ok=FAIL
grep -q $'^REVOKE_TARGET\tcluster\tcluster-admins' "$ev25/10b-path-review.tsv" 2>/dev/null || ok=FAIL
grep -q $'^PLATFORM_DEFAULT\tcluster\tself-provisioners' "$ev25/10b-path-review.tsv" 2>/dev/null || ok=FAIL
grep -q $'^APPROVED\tcluster\thayeoung-clusterversion-reader\tClusterRole\tfds-clusterversion-reader' "$ev25/10b-path-review.tsv" 2>/dev/null || ok=FAIL   # #5 6258874244
grep -qx 'STATUS=COMPLETE' "$ev25/99-receipt.env" 2>/dev/null && grep -qx 'FINAL_RC=0' "$ev25/99-receipt.env" || ok=FAIL
# 인계표 1·3번 기록, grant 상태 rosa list users 원문 기록
grep -qx 'OPENSHIFT_CLUSTER_UUID=00000000-0000-4000-8000-00000000mock' "$ev25/04-handoff-1-3.txt" 2>/dev/null || ok=FAIL
grep -qx 'NODE_COUNT=3' "$ev25/04-handoff-1-3.txt" 2>/dev/null || ok=FAIL
[[ $(grep -c $'\tReady=True$' "$ev25/04-handoff-1-3.txt" 2>/dev/null) == 3 ]] || ok=FAIL
grep -qx 'granted-users rc=0' "$ev25/03-granted-users.rc" 2>/dev/null && [[ -s "$ev25/03-granted-users.out" ]] || ok=FAIL
# R3: receipt 의 해시 5개가 모두 64자리 hex(빈 값 없음), namespace UID 파일 포함
[[ $(grep -cE '^(OLD_KUBECONFIG|TARGET|NS_UID|INVENTORY_SUMS|PATH_REVIEW)_SHA256=[0-9a-f]{64}$' "$ev25/99-receipt.env" 2>/dev/null) == 5 ]] || ok=FAIL
for n in 42_receipt_hash_fail 43_receipt_rename_fail 52_revoke_evidence_copy_fail; do   # 실패 회차엔 receipt 도 임시 파일도 없음
  e=$(ev_of "$n"); [[ -n "$e" ]] || { ok=FAIL; continue; }
  [[ -e "$e/99-receipt.env" || -e "$e/99-receipt.env.tmp" ]] && ok=FAIL
done
grep -qx 'STATUS=POLICY_PENDING' "$ev34/99-receipt.env" 2>/dev/null && grep -qx 'FINAL_RC=3' "$ev34/99-receipt.env" || ok=FAIL
grep -q $'^PENDING_POLICY\tcluster\tself-provisioners' "$ev34/10b-path-review.tsv" 2>/dev/null || ok=FAIL
for n in 28_inventory_unexpected 31_auth_group_admin_stops 36_mgmt_header_broken_body; do    # 실패 회차엔 receipt 없음
  e=$(ev_of "$n"); [[ -n "$e" && -e "$e/99-receipt.env" ]] && ok=FAIL
done
[[ "$ok" == PASS ]] || failures=1
printf '%-26s target·read-rc·분류·receipt(정상/정책대기/실패 회차) => %s\n' 3x_evidence_checks "$ok"

# 리뷰 5530426592 R4: README 의 `| tee` 실행에서 PIPESTATUS 로 래퍼 rc·로그 rc 를 따로 받는지(README 명령 그대로)
readme_pipe() { # name steps expect_wrapper_rc expect_log_rc logpath [env...]
  local name=$1 steps=$2 ew=$3 el=$4 lp=$5; shift 5
  local out
  out=$( env PATH="$T/bin:$PATH" MOCK_LOG="$T/$name.log" HOME="$T/home-$name" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
           DEADLINE_EPOCH=$(( $(date +%s) + 600 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 "$@" \
           bash "$HERE/bootstrap-session.sh" "$T/$steps.sh" 2>&1 | tee "$lp" >/dev/null 2>&1
         pipeline_status=("${PIPESTATUS[@]}"); echo "${pipeline_status[0]} ${pipeline_status[1]}" )
  local w=${out%% *} l=${out##* } ok=PASS
  [[ $w == "$ew" && $l == "$el" ]] || ok=FAIL
  local go=STOP; [[ $w == 0 && $l == 0 ]] && go=NEXT
  [[ "$ok" == PASS ]] || failures=1
  printf '%-26s wrapper_rc=%s log_rc=%s → %s => %s\n' "$name" "$w" "$l" "$go" "$ok"
}
readme_pipe 38_readme_pipe_normal      normal 0 0 "$T/38.log"
readme_pipe 39_readme_pipe_step_fail   fail   1 0 "$T/39.log"
readme_pipe 40_readme_pipe_revoke_fail normal 1 0 "$T/40.log" MOCK_REVOKE_RC=42
readme_pipe 41_readme_pipe_log_fail    normal 0 1 "$T/no-such-dir/41.log"

# 10: 로그를 파이프(tee)로 받을 때 watchdog 가 파이프를 붙잡지 않는지(마감 600초인데 즉시 끝나야 함)
: >"$T/10.log"; start=$(date +%s)
env PATH="$T/bin:$PATH" MOCK_LOG="$T/10.log" HOME="$T/home-10" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
    DEADLINE_EPOCH=$(( $(date +%s) + 600 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 \
    bash "$HERE/bootstrap-session.sh" "$T/normal.sh" 2>&1 | tee "$T/10.out" >/dev/null
rc=${PIPESTATUS[0]}; el=$(( $(date +%s) - start ))
ok=PASS
[[ $rc == 0 && $el -lt 20 ]] || { ok=FAIL; failures=1; }
printf '%-22s rc=%-3s elapsed=%ss (deadline 600s) => %s\n' 10_pipe_no_hang "$rc" "$el" "$ok"
# 보완 4: SKIP(미실행)을 성공(rc0)으로 보이게 하지 않는다. FAIL → rc1, FAIL 없이 SKIP 만 → rc2, 전부 PASS → rc0
if [[ $failures != 0 ]]; then exit 1; fi
if [[ $skipped == 1 ]]; then echo "RESULT: SKIP 있음(rc2) — Linux(setsid --wait)에서 다시 실행해야 전체 판정 가능"; exit 2; fi
exit 0
