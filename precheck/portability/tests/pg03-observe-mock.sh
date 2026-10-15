#!/usr/bin/env bash
# pg03-rosa-observe.sh MOCK 시험. 실제 oc/클러스터 없이 가짜 oc로 판정 분기·중단·무쓰기를 확인한다.
# Linux(bash·python3·GNU coreutils)에서 실행한다.
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SOURCE_ROOT/precheck/portability/pg03-rosa-observe.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/pg03-observe-mock.XXXXXX")"
[[ "$T" == /*/pg03-observe-mock.* ]] || exit 2
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/work"

cat >"$T/bin/oc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLLOG"
if [[ "$1" == config ]]; then
  [[ "$SCENARIO" == server_mismatch ]] && { printf 'https://api.other.invalid:6443'; exit 0; }
  printf 'https://api.mock.invalid:6443'; exit 0
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
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; exit 0;;
  whoami) echo mock-user; exit 0;;
  version) echo 'MOCK oc'; exit 0;;
  "get namespace fds-app -o json"|"-n fds-app get "*)
    [[ "$SCENARIO" == deploy_missing && "$args" == *"get deployment"* ]] && {
      echo 'Error from server (NotFound): deployments.apps "fds-engine" not found' >&2; exit 1; }
    [[ "$SCENARIO" == pods_403 && "$args" == *"get pod"* ]] && { echo 'Error from server (Forbidden)' >&2; exit 1; }
    exec python3 "$FIXTURE" "$SCENARIO" "$args";;
esac
echo "unexpected: $args" >&2
exit 98
MOCK
chmod +x "$T/bin/oc"

# 가짜 클러스터 상태. 시나리오마다 정상 상태에서 한 군데만 바꾼다.
cat >"$T/fixture.py" <<'PY'
import json, sys
scenario, args = sys.argv[1], sys.argv[2]
D = 'a' * 64
IMG = {'transaction-api': 'registry.invalid/fds/transaction-api@sha256:' + D,
       'fds-engine': 'registry.invalid/fds/fds-engine@sha256:' + D}
NS_UID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

def ns():
    rng = 'not-a-range' if scenario == 'bad_range' else '1000680000/10000'
    return {'apiVersion': 'v1', 'kind': 'Namespace',
            'metadata': {'name': 'fds-app', 'uid': NS_UID,
                         'annotations': {'openshift.io/sa.scc.uid-range': rng,
                                         'openshift.io/sa.scc.supplemental-groups': '1000680000/10000'}}}

SIDE = 'registry.invalid/fds/sidecar@sha256:' + 'e' * 64

def csc(live, uid=None):
    sc = {'allowPrivilegeEscalation': False, 'privileged': False, 'readOnlyRootFilesystem': True,
          'capabilities': {'drop': ['ALL']}}
    if scenario == 'ro_false':
        sc['readOnlyRootFilesystem'] = False
    if scenario == 'drop_missing':
        sc['capabilities'] = {'drop': []}
    if scenario == 'ctr_runasnonroot_false' and not live:
        sc['runAsNonRoot'] = False          # 보완 4: Pod 값은 true지만 컨테이너가 덮어씀
    if scenario == 'live_seccomp_unconfined' and live:
        sc['seccompProfile'] = {'type': 'Unconfined'}   # 보완 4: template은 정상, live만 다름
    if scenario == 'live_privesc' and live:
        sc['allowPrivilegeEscalation'] = True
    if live and uid is not None:
        sc['runAsUser'] = uid
    return sc

def containers(name, image, live, uid=None):
    app = {'name': name, 'image': image, 'securityContext': csc(live, uid)}
    if scenario == 'app_container_missing' and live:
        app['name'] = name + '-renamed'
    if scenario == 'sidecar_first':        # 보완 3: 앱이 첫 번째가 아니어도 이름으로 찾아야 한다
        side = {'name': 'sidecar', 'image': SIDE,
                'securityContext': {'allowPrivilegeEscalation': False, 'privileged': False,
                                    'readOnlyRootFilesystem': True, 'capabilities': {'drop': ['ALL']},
                                    **({'runAsUser': uid} if live and uid is not None else {})}}
        return [side, app]
    return [app]

def dep(name):
    psc = {'runAsNonRoot': True, 'seccompProfile': {'type': 'RuntimeDefault'}}
    if scenario == 'tmpl_fixed_uid':
        psc.update(runAsUser=10001, runAsGroup=999)
    image = IMG[name]
    if scenario == 'image_mismatch' and name == 'fds-engine':
        image = 'registry.invalid/fds/fds-engine@sha256:' + 'b' * 64
    ready = 2 if scenario == 'not_ready' and name == 'transaction-api' else 3
    observed = 3 if scenario == 'not_observed' and name == 'fds-engine' else 4
    spec = {'replicas': 3, 'template': {'spec': {'securityContext': psc, 'containers': containers(name, image, False)}}}
    if scenario == 'paused' and name == 'transaction-api':
        spec['paused'] = True
    return {'apiVersion': 'apps/v1', 'kind': 'Deployment',
            'metadata': {'name': name, 'namespace': 'fds-app', 'uid': 'dep-' + name, 'generation': 4,
                         'annotations': {'deployment.kubernetes.io/revision': '2'}},
            'spec': spec,
            'status': {'observedGeneration': observed, 'replicas': 3, 'updatedReplicas': 3,
                       'readyReplicas': ready, 'availableReplicas': ready}}

def rs(name, rev, suffix):
    return {'apiVersion': 'apps/v1', 'kind': 'ReplicaSet',
            'metadata': {'name': f'{name}-{suffix}', 'uid': f'rs-{name}-{suffix}',
                         'labels': {'app': name, 'pod-template-hash': 'h' + suffix},
                         'annotations': {'deployment.kubernetes.io/revision': rev},
                         'ownerReferences': [{'kind': 'Deployment', 'uid': 'dep-' + name}]}}

def pod(name, suffix, i, rs_suffix):
    uid = 1000680000 + i
    if scenario == 'uid_fixed' and name == 'transaction-api':
        uid = 10001
    if scenario == 'uid_out_of_range' and name == 'fds-engine':
        uid = 1000690000
    if scenario == 'uid_missing' and name == 'fds-engine':
        uid = None
    scc = 'anyuid' if scenario == 'scc_anyuid' and name == 'fds-engine' else 'restricted-v2'
    digest = 'c' * 64 if scenario == 'digest_child' and name == 'transaction-api' else D
    ready = not (scenario == 'not_ready' and name == 'transaction-api' and i == 0)
    # 보완 1: 컨테이너는 ready지만 Pod Ready 조건(readiness gate)이 False
    pod_ready = not (scenario == 'pod_condition_not_ready' and name == 'fds-engine' and i == 1) and ready
    phash = 'h' + rs_suffix
    if scenario == 'hash_mismatch' and name == 'fds-engine' and i == 0 and rs_suffix == 'new':
        phash = 'hother'
    meta = {'name': f'{name}-{rs_suffix}-{i}', 'labels': {'app': name, 'pod-template-hash': phash},
            'annotations': {'openshift.io/scc': scc},
            'ownerReferences': [{'kind': 'ReplicaSet', 'uid': f'rs-{name}-{rs_suffix}'}]}
    if suffix == 'terminating':
        meta['deletionTimestamp'] = '2026-10-15T00:00:00Z'
    statuses = [{'name': name, 'ready': ready, 'restartCount': 0,
                 'imageID': IMG[name].split('@')[0] + '@sha256:' + digest}]
    if scenario == 'sidecar_first':        # status 순서도 앱이 뒤
        statuses.insert(0, {'name': 'sidecar', 'ready': True, 'restartCount': 0,
                            'imageID': SIDE.split('@')[0] + '@sha256:' + 'f' * 64})
    return {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': meta,
            'spec': {'securityContext': {'runAsNonRoot': True, 'fsGroup': 1000680000,
                                         'seccompProfile': {'type': 'RuntimeDefault'}},
                     'containers': containers(name, IMG[name], True, uid)},
            'status': {'phase': 'Running',
                       'conditions': [{'type': 'Ready', 'status': 'True' if pod_ready else 'False'}],
                       'containerStatuses': statuses}}

def lst(items):
    return {'apiVersion': 'v1', 'kind': 'List', 'items': items}

names = ['transaction-api', 'fds-engine']
if args == 'get namespace fds-app -o json':
    doc = ns()
elif 'get deployment' in args:
    doc = lst([dep(n) for n in names])
elif 'get replicaset' in args:
    items = []
    for n in names:
        items += [rs(n, '2', 'new'), rs(n, '1', 'old')]
        if scenario == 'rs_ambiguous' and n == 'fds-engine':
            items.append(rs(n, '2', 'dup'))
    doc = lst(items)
elif 'get pod' in args:
    items = []
    for n in names:
        count = 2 if scenario == 'pod_count_less' and n == 'fds-engine' else 3
        items += [pod(n, 'new', i, 'new') for i in range(count)]
        items.append(pod(n, 'old', 9, 'old'))  # 이전 ReplicaSet Pod는 판정에서 빠져야 한다
        if scenario == 'terminating_pod' and n == 'transaction-api':
            items.append(pod(n, 'terminating', 7, 'new'))  # 보완 1: 현재 RS의 종료 중 Pod
    if scenario == 'pods_wrong_kind':
        items[0]['kind'] = 'Deployment'
    doc = lst(items)
else:
    sys.stderr.write('fixture: unexpected ' + args + '\n'); sys.exit(98)
if scenario == 'partial_json' and 'get pod' in args:
    sys.stdout.write(json.dumps(doc)[:200]); sys.exit(0)
print(json.dumps(doc))
PY

export PATH="$T/bin:$PATH" CALLLOG="$T/calls.log" FIXTURE="$T/fixture.py"
DIGEST="$(printf 'a%.0s' {1..64})"
BASE_ENV=(CTX=mock API=https://api.mock.invalid:6443 NS=fds-app PORT_ENV=ROSA
  EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555
  EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  TX_IMAGE="registry.invalid/fds/transaction-api@sha256:$DIGEST"
  ENG_IMAGE="registry.invalid/fds/fds-engine@sha256:$DIGEST")
WRITE_RE='(^|[[:space:]])(apply|create|delete|patch|label|annotate|exec|replace|edit|scale|rollout|set|expose|port-forward|debug|cp|attach)([[:space:]]|$)'
n=0

check() {  # check <name> <want_rc> <api_calls_allowed:yes|no> [extra env...]
  local name="$1" want="$2" api="$3"; shift 3
  : >"$CALLLOG"
  set +e
  (cd "$T/work" && env "${BASE_ENV[@]}" OUT_DIR="$T/out-$name" "$@" bash "$SCRIPT") >"$T/$name.stdout" 2>"$T/$name.stderr"
  local rc=$?
  set -e
  [[ "$rc" == "$want" ]] || { echo "FAIL $name: rc=$rc want=$want"; cat "$T/$name.stderr"; tail -20 "$T/$name.stdout"; exit 1; }
  if grep -Eq "$WRITE_RE" "$CALLLOG"; then echo "FAIL $name: write verb called"; cat "$CALLLOG"; exit 1; fi
  if grep -v '^config ' "$CALLLOG" | grep -qv -- '^--context=mock --server=https://api.mock.invalid:6443 --insecure-skip-tls-verify=false '; then
    echo "FAIL $name: unpinned oc call"; cat "$CALLLOG"; exit 1
  fi
  if [[ "$api" == no ]] && grep -q -- '^--context' "$CALLLOG"; then
    echo "FAIL $name: API called"; cat "$CALLLOG"; exit 1
  fi
  n=$((n + 1))
}
summary_is() { grep -q "^SUMMARY=$2\$" "$T/out-$1/observe-result.txt" || { echo "FAIL $1: summary"; cat "$T/out-$1/observe-result.txt"; exit 1; }; }

# 입력 단계 거부: oc 호출 0건
for bad in "CTX=" "NS=openshift-monitoring" "NS=kube-system" "NS=default" "PORT_ENV=prod" \
           "EXPECTED_CLUSTER_ID=" "EXPECTED_NS_UID=not-a-uuid" "TX_IMAGE=repo:latest" "API=http://api.mock.invalid:6443"; do
  check "input-$n" 2 no "$bad"
  [[ ! -s "$CALLLOG" ]] || { echo "FAIL input $bad: oc called"; exit 1; }
done

# 대상 불일치
check server_mismatch 10 no SCENARIO=server_mismatch
check cluster_mismatch 10 yes SCENARIO=cluster_mismatch
check cluster_403 10 yes SCENARIO=cluster_403
check ns_mismatch 10 yes SCENARIO=ok EXPECTED_NS_UID=00000000-0000-0000-0000-000000000000

# 수집 오류
for s in deploy_missing pods_403 rs_ambiguous bad_range pods_wrong_kind partial_json not_observed paused hash_mismatch app_container_missing; do
  check "$s" 11 yes SCENARIO="$s"; summary_is "$s" COLLECTION_ERROR
done

# 판정 분기
for s in scc_anyuid uid_fixed uid_out_of_range uid_missing; do
  check "$s" 31 yes SCENARIO="$s"; summary_is "$s" SCC_OR_UID_NOT_PORTABLE
done
for s in tmpl_fixed_uid ro_false drop_missing ctr_runasnonroot_false live_seccomp_unconfined live_privesc; do
  check "$s" 32 yes SCENARIO="$s"; summary_is "$s" SECURITY_CONTEXT_MISMATCH
done
for s in image_mismatch digest_child; do
  check "$s" 33 yes SCENARIO="$s"; summary_is "$s" IMAGE_DIGEST_REVIEW_REQUIRED
done
for s in not_ready pod_count_less pod_condition_not_ready terminating_pod; do
  check "$s" 30 yes SCENARIO="$s"; summary_is "$s" NOT_READY
done

# 정상: 이전 ReplicaSet Pod는 빼고 현재 Pod 3개씩만 판정
check ok 0 yes SCENARIO=ok
summary_is ok OBSERVED_AS_EXPECTED
[[ "$(grep -c 'scc=restricted-v2' "$T/out-ok/observe-result.txt")" == 6 ]] || { echo "FAIL ok: pod count"; exit 1; }
! grep -q -- '-old-' "$T/out-ok/observe-result.txt" || { echo "FAIL ok: old pod counted"; exit 1; }
grep -q '^CLUSTER_MUTATION=NONE$' "$T/out-ok/observe-result.txt"
grep -q '^WRITE_TEST=NOT_RUN$' "$T/out-ok/observe-result.txt"
grep -q "^COLLECTOR_SHA256=$(sha256sum "$SCRIPT" | cut -d' ' -f1)$" "$T/out-ok/context.txt"
(cd "$T/out-ok" && sha256sum -c --quiet SHA256SUMS)

# 보완 3: 사이드카가 앞에 있어도 앱 컨테이너·status를 이름으로 찾아 정상 판정
check sidecar_first 0 yes SCENARIO=sidecar_first
summary_is sidecar_first OBSERVED_AS_EXPECTED

# 기존 OUT_DIR는 덮어쓰지 않음
check reuse 2 no SCENARIO=ok OUT_DIR="$T/out-ok"
(cd "$T/out-ok" && sha256sum -c --quiet SHA256SUMS)

echo "PASS: $n cases; get-only pinned calls; no write verbs; structured observe verdicts"
