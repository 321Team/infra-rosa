#!/usr/bin/env bash
# pg03-rosa-check.sh MOCK 시험. 실제 oc/클러스터 없이 가짜 oc로 실패·진입 조건과 무쓰기를 확인한다.
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SOURCE_ROOT/precheck/portability/pg03-rosa-check.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/pg03-mock.XXXXXX")"
[[ "$T" == /*/pg03-mock.* ]] || exit 2
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/msa/deploy/base" "$T/work"

# 가짜 fds-msa checkout(내용은 가짜 oc kustomize가 대신 렌더한다)
printf 'resources: []\n' >"$T/msa/deploy/base/kustomization.yaml"
git -C "$T/msa" init -q
git -C "$T/msa" add .
git -C "$T/msa" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
MSA_SHA="$(git -C "$T/msa" rev-parse HEAD)"

cat >"$T/bin/oc" <<'MOCK'
#!/usr/bin/env bash
# Every call is logged. Scenario comes from $SCENARIO.
printf '%s\n' "$*" >>"$CALLLOG"
if [[ "$1" == config ]]; then
  [[ "$SCENARIO" == server_mismatch ]] && { printf 'https://api.other.invalid:6443'; exit 0; }
  printf 'https://api.mock.invalid:6443'; exit 0
fi
if [[ "$1" == kustomize ]]; then
  if [[ "$2" == */fixed ]]; then printf 'kind: Deployment\n  runAsUser: 10001\n'; else printf 'kind: Deployment\n'; fi
  exit 0
fi
[[ "$1" == --context=mock && "$2" == --server=https://api.mock.invalid:6443 && "$3" == --insecure-skip-tls-verify=false ]] || exit 97
shift 3
args="$*"
case "$args" in
  "get clusterversion version"*)
    [[ "$SCENARIO" == cluster_mismatch ]] && { printf '99999999-0000-0000-0000-000000000000'; exit 0; }
    [[ "$SCENARIO" == cluster_403 ]] && { echo 'Error from server (Forbidden)' >&2; exit 1; }
    printf '11111111-2222-3333-4444-555555555555'; exit 0;;
  "get namespace fds-app -o jsonpath={.metadata.uid}")
    [[ "$SCENARIO" == ns_mismatch ]] && { printf '00000000-0000-0000-0000-000000000000'; exit 0; }
    # 같은 조회가 처음(대상 확인)과 마지막(종료 확인)에 두 번 온다. 두 번째 호출에서만 실패를 만든다.
    if [[ "$(grep -c 'get namespace fds-app -o jsonpath={.metadata.uid}$' "$CALLLOG")" -ge 2 ]]; then
      [[ "$SCENARIO" == final_ns_diff ]] && { printf '99999999-0000-0000-0000-000000000000'; exit 0; }
      [[ "$SCENARIO" == final_ns_fail_empty ]] && { echo 'Error from server (Forbidden)' >&2; exit 1; }
      [[ "$SCENARIO" == final_ns_fail_with_uid ]] && { printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; echo 'error: unexpected EOF' >&2; exit 1; }
    fi
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; exit 0;;
  "get namespace fds-app -o jsonpath="*) printf '1000740000/10000\n1000740000/10000\n'; exit 0;;
  whoami) echo mock-user; exit 0;;
  version) echo 'MOCK oc'; exit 0;;
  "create --dry-run=client -o json -f "*)
    python3 - "$args" "$SCENARIO" <<'PY'
import json, sys
fixed = '/render-fixed.out' in sys.argv[1]
scenario = sys.argv[2]
def dep(name, sa):
    sc = {'runAsNonRoot': True, 'seccompProfile': {'type': 'RuntimeDefault'}}
    if fixed:
        sc.update(runAsUser=10001, runAsGroup=999)
    return {'apiVersion': 'apps/v1', 'kind': 'Deployment',
            'metadata': {'name': name, 'namespace': 'fds-app'},
            'spec': {'template': {'spec': {'serviceAccountName': sa, 'securityContext': sc,
                                           'containers': [{'name': name, 'image': 'x'}]}}}}
items = [{'kind': 'ServiceAccount', 'metadata': {'name': 'fds-engine-sa'}},
         {'kind': 'ServiceAccount', 'metadata': {'name': 'transaction-api-sa'}},
         dep('fds-engine', 'fds-engine-sa')]
if scenario != 'one_deployment':
    items.append(dep('transaction-api', 'transaction-api-sa'))
items += [{'kind': 'Service', 'metadata': {'name': n}} for n in ('fds-engine', 'transaction-api')]
items += [{'kind': 'NetworkPolicy', 'metadata': {'name': n}}
          for n in ('default-deny-all', 'transaction-api-allow', 'fds-engine-allow')]
print(json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': items}))
PY
    exit 0;;
  "-n fds-app get serviceaccount "*)
    [[ "$SCENARIO" == sa_403 ]] && { echo 'Error from server (Forbidden): serviceaccounts is forbidden' >&2; exit 1; }
    [[ "$SCENARIO" == sa_absent ]] && { echo 'Error from server (NotFound): serviceaccounts "x" not found' >&2; exit 1; }
    printf 'sa-uid'; exit 0;;
  "-n fds-app adm policy scc-subject-review -z "*)
    [[ "$args" == *" -o json" ]] || exit 96
    variant=portable; [[ "$args" == *deploy-fixed-* ]] && variant=fixed
    [[ "$SCENARIO" == review_rc7 ]] && { echo 'error: unsupported object' >&2; exit 7; }
    [[ "$SCENARIO" == partial && "$args" == *transaction-api* ]] && { echo '{"kind":"List","items":[]}'; exit 0; }
    scc=''
    case "$SCENARIO:$variant" in
      *:portable) scc=restricted-v2;;
      fixed_restricted:fixed) scc=restricted-v2;;
      fixed_broad:fixed) scc=anyuid;;
    esac
    [[ "$SCENARIO" == portable_none && $variant == portable ]] && scc=''
    [[ "$SCENARIO" == portable_broad && $variant == portable ]] && scc=anyuid
    # 깨진 응답(리뷰 B4): bad_fixed_* 는 fixed 거부 응답을, bad_allow_* 는 portable 허용 응답을 바꾼다.
    K='"apiVersion":"security.openshift.io/v1","kind":"PodSecurityPolicySubjectReview"'
    case "$SCENARIO:$variant" in
      bad_fixed_empty_doc:fixed)     echo '{}'; exit 0;;
      bad_fixed_wrong_kind:fixed)    echo '{"apiVersion":"apps/v1","kind":"Deployment","status":{}}'; exit 0;;
      bad_fixed_status_null:fixed)   echo "{$K,\"status\":null}"; exit 0;;
      bad_fixed_status_empty:fixed)  echo "{$K,\"status\":{}}"; exit 0;;
      bad_fixed_no_api:fixed)        echo '{"kind":"PodSecurityPolicySubjectReview","status":{"reason":"denied","template":{}}}'; exit 0;;
      bad_fixed_reason_type:fixed)   echo "{$K,\"status\":{\"reason\":5,\"template\":{}}}"; exit 0;;
      bad_fixed_template_null:fixed) echo "{$K,\"status\":{\"template\":null}}"; exit 0;;
      bad_fixed_template_list:fixed) echo "{$K,\"status\":{\"template\":[]}}"; exit 0;;
      bad_fixed_template_str:fixed)  echo "{$K,\"status\":{\"template\":\"not-a-pod-template\"}}"; exit 0;;
      bad_fixed_reason_empty:fixed)  echo "{$K,\"status\":{\"reason\":\"\"}}"; exit 0;;
      bad_allow_wrong_api:portable)  echo '{"apiVersion":"v1","kind":"PodSecurityPolicySubjectReview","status":{"allowedBy":{"name":"restricted-v2"}}}'; exit 0;;
      bad_allow_status_str:portable) echo "{$K,\"status\":\"restricted-v2\"}"; exit 0;;
      bad_allow_ref_str:portable)    echo "{$K,\"status\":{\"allowedBy\":\"restricted-v2\"}}"; exit 0;;
      bad_allow_empty_name:portable) echo "{$K,\"status\":{\"allowedBy\":{\"name\":\"\"}}}"; exit 0;;
    esac
    if [[ -n "$scc" ]]; then
      printf '{%s,"status":{"allowedBy":{"kind":"SecurityContextConstraints","name":"%s"},"template":{}}}\n' "$K" "$scc"
    elif [[ "$SCENARIO" == fixed_template_only ]]; then
      printf '{%s,"status":{"template":{}}}\n' "$K"
    else
      printf '{%s,"status":{"reason":"denied","template":{}}}\n' "$K"
    fi
    exit 0;;
esac
echo "unexpected: $args" >&2
exit 98
MOCK
chmod +x "$T/bin/oc"

export PATH="$T/bin:$PATH" CALLLOG="$T/calls.log"
DIGEST="$(printf 'a%.0s' {1..64})"
BASE_ENV=(CTX=mock API=https://api.mock.invalid:6443 NS=fds-app PORT_ENV=ROSA
  EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555
  EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  MSA_DIR="$T/msa" MSA_SHA="$MSA_SHA"
  TX_IMAGE="registry.invalid/fds/transaction-api@sha256:$DIGEST"
  ENG_IMAGE="registry.invalid/fds/fds-engine@sha256:$DIGEST")
WRITE_RE='(^|[[:space:]])(apply|delete|patch|label|annotate|exec|replace|edit|scale|rollout|set|expose)([[:space:]]|$)'
n=0

check() {  # check <name> <want_rc> <api_calls_allowed:yes|no> [extra env...]
  local name="$1" want="$2" api="$3"; shift 3
  : >"$CALLLOG"
  set +e
  (cd "$T/work" && env "${BASE_ENV[@]}" OUT_DIR="$T/out-$name" "$@" bash "$SCRIPT") >"$T/$name.stdout" 2>"$T/$name.stderr"
  local rc=$?
  set -e
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: rc=$rc want=$want"; cat "$T/$name.stderr"; exit 1; }
  if grep -Eq "$WRITE_RE" "$CALLLOG"; then echo "FAIL $name: write verb called"; cat "$CALLLOG"; exit 1; fi
  if grep '^--context' "$CALLLOG" | grep ' create ' | grep -qv -- '--dry-run=client'; then
    echo "FAIL $name: create without client dry-run"; exit 1
  fi
  if [[ "$api" == no ]] && grep -q -- '^--context' "$CALLLOG"; then
    echo "FAIL $name: API called"; cat "$CALLLOG"; exit 1
  fi
  n=$((n + 1))
}

# 입력 단계 거부: oc 호출 0건
for bad in "MODE=runtime" "NS=openshift-monitoring" "NS=kube-system" "NS=default" \
           "EXPECTED_CLUSTER_ID=" "EXPECTED_NS_UID=not-a-uuid" "TX_IMAGE=repo:latest"; do
  check "input-${bad%%=*}-$n" 2 no "$bad"
  [[ ! -s "$CALLLOG" ]] || { echo "FAIL input $bad: oc called"; exit 1; }
done

# 대상 불일치: 첫 API 요청 전(서버) 또는 쓰기 없이 중단
check server_mismatch 10 no SCENARIO=server_mismatch
check cluster_mismatch 10 yes SCENARIO=cluster_mismatch
check cluster_403 10 yes SCENARIO=cluster_403
check ns_mismatch 10 yes SCENARIO=ns_mismatch
# 판정이 정상이어도 마지막 namespace 확인이 실패하면 10(SHA256SUMS로 마감하지 않음)
for s in final_ns_diff final_ns_fail_empty final_ns_fail_with_uid; do
  check "$s" 10 yes SCENARIO="$s"
  [[ -f "$T/out-$s/namespace-final.rc" && ! -f "$T/out-$s/SHA256SUMS" ]] || { echo "FAIL $s: final check not recorded or evidence sealed"; exit 1; }
done

# 수집 오류: 지원 안 되는 객체 rc7, 부분 출력, Deployment 누락, SA 조회 403
check review_rc7 11 yes SCENARIO=review_rc7
grep -q '^SUMMARY=COLLECTION_ERROR$' "$T/out-review_rc7/admission-result.txt"
check partial 11 yes SCENARIO=partial
check one_deployment 11 yes SCENARIO=one_deployment
check sa_403 11 yes SCENARIO=sa_403

# 깨진 응답은 거부·허용으로 읽지 않고 수집 오류(리뷰 B4)
for s in bad_fixed_empty_doc bad_fixed_wrong_kind bad_fixed_status_null bad_fixed_status_empty \
         bad_fixed_no_api bad_fixed_reason_type \
         bad_fixed_template_null bad_fixed_template_list bad_fixed_template_str bad_fixed_reason_empty \
         bad_allow_wrong_api bad_allow_status_str bad_allow_ref_str bad_allow_empty_name; do
  check "$s" 11 yes SCENARIO="$s"
  grep -q '^SUMMARY=COLLECTION_ERROR$' "$T/out-$s/admission-result.txt"
done
# reason 없이 template만 있는 거부 응답은 정상 거부로 인정
check fixed_template_only 0 yes SCENARIO=fixed_template_only

# 판정 분기
check portable_none 20 yes SCENARIO=portable_none
check portable_broad 20 yes SCENARIO=portable_broad
grep -q 'BROADER_SCC:anyuid' "$T/out-portable_broad/admission-result.txt"
check fixed_restricted 21 yes SCENARIO=fixed_restricted
check fixed_broad 21 yes SCENARIO=fixed_broad
grep -q 'ALLOWED_BY_OTHER_SCC:anyuid' "$T/out-fixed_broad/admission-result.txt"

# 정상: 리뷰 4건(-z 앱 SA), SA/Service/NetworkPolicy는 리뷰하지 않음
check ok 0 yes SCENARIO=ok
[[ "$(grep -c 'scc-subject-review -z' "$CALLLOG")" == 4 ]]
grep -q 'scc-subject-review -z fds-engine-sa' "$CALLLOG"
grep -q 'scc-subject-review -z transaction-api-sa' "$CALLLOG"
! grep -q 'scc-subject-review -f' "$CALLLOG"
grep -q '^SUMMARY=ADMISSION_AS_EXPECTED$' "$T/out-ok/admission-result.txt"
grep -q '^CLUSTER_MUTATION=NONE$' "$T/out-ok/admission-result.txt"
grep -q "^COLLECTOR_SHA256=$(sha256sum "$SCRIPT" | cut -d' ' -f1)$" "$T/out-ok/context.txt"
(cd "$T/out-ok" && sha256sum -c --quiet SHA256SUMS)

# SA 부재는 NotFound일 때만 기록하고 진행
check sa_absent 0 yes SCENARIO=sa_absent
grep -q 'sa_present=False' "$T/out-sa_absent/admission-result.txt"

# 기존 OUT_DIR는 덮어쓰지 않음
check reuse 2 no SCENARIO=ok OUT_DIR="$T/out-ok"
(cd "$T/out-ok" && sha256sum -c --quiet SHA256SUMS)

echo "PASS: $n cases; no write verbs; target check before API; structured admission verdicts"
