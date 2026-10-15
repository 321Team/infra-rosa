#!/usr/bin/env bash
# infra-rosa#6 PG-03 — ROSA 실제 배포 Pod 관측기 (6-2 Runtime, 읽기 전용)
#
# 하는 일(조회만, 클러스터 변경 없음):
#   #43/#46이 fds-app에 배포한 transaction-api·fds-engine Deployment와 그 현재 ReplicaSet의 Pod를 get으로 읽어
#   restricted-v2 적용, SCC가 배정한 UID(namespace 범위 안, 10001 아님), portable SecurityContext,
#   승인 이미지 digest, Ready를 구조적으로 판정한다.
#
# 하지 않는 것: apply/create/delete/patch/label/exec/port-forward 등 모든 쓰기·Pod 안 명령.
#   앱을 따로 띄우지 않는다(PR36 리뷰 B1/B2의 소유권·정리 문제를 만들지 않기 위해 #46 배포를 관측만 한다).
#   읽기 전용 루트에서 실제 쓰기가 막히는지(errno 30)는 exec가 필요해 이 도구 범위 밖이다(WRITE_TEST=NOT_RUN).
#
# 입력(모두 필수):
#   CTX, API(https://host[:port]), NS(기본 fds-app 아님 — 명시), PORT_ENV=ROSA|SHARED_OCP_LAB
#   EXPECTED_CLUSTER_ID, EXPECTED_NS_UID   승인된 inventory 값(UUID)
#   TX_IMAGE, ENG_IMAGE  배포 승인 이미지 <registry>/<repo>@sha256:<64hex> (#46 전달 receipt 값)
# 선택: OUT_DIR(없어야 함)
#
# 종료 코드:
#   0  두 앱 모두 restricted-v2·배정 UID·portable SecurityContext·digest 일치·Ready
#   2  입력 오류(oc 호출 전)          10 대상 불일치(서버/Cluster ID/NS UID)
#   11 수집·파싱 오류(조회 rc≠0, 형식 이상, 대상 Deployment·현재 ReplicaSet 누락)
#   31 SCC가 restricted-v2가 아니거나 UID가 고정값·범위 밖·미배정
#   32 SecurityContext가 portable 계약과 다름(UID/GID 고정, 읽기 전용 루트 아님 등)
#   33 이미지 참조 또는 imageID digest가 승인값과 다름(멀티아키텍처 index/child 차이 포함 — 사람 확인)
#   30 rollout 미완료 또는 Ready 아님(transaction-api는 DB 경로가 필요)
#   여러 문제가 겹치면 11 > 31 > 32 > 33 > 30 순서로 하나를 고르고, 행별 결과는 모두 기록한다.
set -euo pipefail
umask 077

die() { local rc="$1"; shift; echo "STOP: $*" >&2; exit "$rc"; }

CTX="${CTX:-}"; API="${API:-}"; NS="${NS:-}"; PORT_ENV="${PORT_ENV:-}"
EXPECTED_CLUSTER_ID="${EXPECTED_CLUSTER_ID:-}"; EXPECTED_NS_UID="${EXPECTED_NS_UID:-}"
TX_IMAGE="${TX_IMAGE:-}"; ENG_IMAGE="${ENG_IMAGE:-}"; OUT_DIR="${OUT_DIR:-}"

# ---- 입력 검사 (oc 호출 전) ----
[[ -n "$CTX" && "$CTX" != *$'\n'* ]] || die 2 "CTX 필요"
[[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die 2 "API는 https://host[:port]"
[[ "$PORT_ENV" == ROSA || "$PORT_ENV" == SHARED_OCP_LAB ]] || die 2 "PORT_ENV=ROSA|SHARED_OCP_LAB"
(( ${#NS} <= 63 )) && [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 2 "NS는 DNS-1123 label"
[[ ! "$NS" =~ ^(openshift|kube)(-|$) && "$NS" != default ]] || die 2 "System namespace는 대상 아님"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "$EXPECTED_CLUSTER_ID" =~ $UUID_RE ]] || die 2 "EXPECTED_CLUSTER_ID는 승인 inventory의 UUID"
[[ "$EXPECTED_NS_UID" =~ $UUID_RE ]] || die 2 "EXPECTED_NS_UID는 승인 inventory의 UUID"
IMG_RE='^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[0-9a-f]{64}$'
[[ "$TX_IMAGE" =~ $IMG_RE && "$ENG_IMAGE" =~ $IMG_RE ]] || die 2 "TX_IMAGE/ENG_IMAGE는 @sha256:<64hex> 고정"
for c in oc python3 sha256sum date mktemp realpath; do command -v "$c" >/dev/null || die 2 "명령 없음: $c"; done

SELF="$(realpath "${BASH_SOURCE[0]}")"
SELF_SHA="$(sha256sum "$SELF" | cut -d' ' -f1)"

if [[ -z "$OUT_DIR" ]]; then
  mkdir -p ./evidence-local/pg03
  OUT_DIR="$(mktemp -d "./evidence-local/pg03/observe.XXXXXX")"
else
  mkdir -m 700 -- "$OUT_DIR" 2>/dev/null || die 2 "OUT_DIR 이미 있음/생성 실패(덮어쓰지 않음)"
fi
OUT_DIR="$(realpath "$OUT_DIR")"
trap 'rc=$?; [[ $rc -ne 0 ]] && echo "RESULT_RC=$rc; 보존: $OUT_DIR" >&2' EXIT

run() {
  local name="$1"; shift
  local start; start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e
  "$@" >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err"
  local rc=$?
  set -e
  echo "$rc" >"$OUT_DIR/$name.rc"
  printf '%s\t%s\t%s\t%s\n' "$start" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$name" >>"$OUT_DIR/commands.tsv"
  return 0
}
rc_of() { cat "$OUT_DIR/$1.rc"; }

# ---- 대상 확인: kubeconfig context의 서버가 API와 같은지 먼저(로컬 조회, API 요청 없음) ----
run ctx-server oc config view --minify --context="$CTX" -o 'jsonpath={.clusters[0].cluster.server}'
[[ "$(rc_of ctx-server)" == 0 && "$(cat "$OUT_DIR/ctx-server.out")" == "$API" ]] \
  || die 10 "CTX의 서버가 API와 다름(첫 API 요청 전 중단)"

OC=(oc --context="$CTX" --server="$API" --insecure-skip-tls-verify=false)

run cluster-id "${OC[@]}" get clusterversion version -o 'jsonpath={.spec.clusterID}'
[[ "$(rc_of cluster-id)" == 0 && "$(cat "$OUT_DIR/cluster-id.out")" == "$EXPECTED_CLUSTER_ID" ]] \
  || die 10 "Cluster ID가 승인 inventory와 다르거나 조회 불가(cluster-id.err 확인)"
run namespace "${OC[@]}" get namespace "$NS" -o json
[[ "$(rc_of namespace)" == 0 ]] || die 10 "Namespace 조회 불가"
NS_UID_NOW="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["uid"])' "$OUT_DIR/namespace.out" 2>/dev/null || true)"
[[ "$NS_UID_NOW" == "$EXPECTED_NS_UID" ]] || die 10 "Namespace UID가 승인 inventory와 다름"

# 보조 증적: 실패해도 진행하고 rc·오류를 남긴다.
run whoami "${OC[@]}" whoami
run oc-version "${OC[@]}" version
{
  echo "ENV=$PORT_ENV"; echo "MODE=observe"
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
  echo "CTX=$CTX"; echo "API=$API"; echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID"
  echo "NS=$NS"; echo "NAMESPACE_UID=$EXPECTED_NS_UID"
  echo "TX_IMAGE=$TX_IMAGE"; echo "ENG_IMAGE=$ENG_IMAGE"
  echo "COLLECTOR_SHA256=$SELF_SHA"
  echo "COLLECTOR_GIT_HEAD=$(git -C "$(dirname "$SELF")" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "WHOAMI_RC=$(rc_of whoami) WHOAMI=$(cat "$OUT_DIR/whoami.out")"
} >"$OUT_DIR/context.txt"

# ---- 관측(get만) ----
SEL='app in (transaction-api,fds-engine)'
run deployments "${OC[@]}" -n "$NS" get deployment transaction-api fds-engine -o json
run replicasets "${OC[@]}" -n "$NS" get replicaset -l "$SEL" -o json
run pods "${OC[@]}" -n "$NS" get pod -l "$SEL" -o json

set +e
python3 - "$OUT_DIR" "$NS" "$TX_IMAGE" "$ENG_IMAGE" <<'PY'
import json, os, sys
out, ns, tx_image, eng_image = sys.argv[1:5]
EXPECT = {'transaction-api': tx_image, 'fds-engine': eng_image}
errors, rows = [], []

def load(name):
    rc = open(os.path.join(out, name + '.rc')).read().strip()
    if rc != '0':
        raise ValueError(f'{name} rc={rc}')
    doc = json.load(open(os.path.join(out, name + '.out')))
    if not isinstance(doc, dict):
        raise ValueError(f'{name} not an object')
    return doc

def items(doc, kind, name):
    if doc.get('kind') == 'List' or doc.get('kind', '').endswith('List'):
        lst = doc.get('items')
    else:
        lst = [doc]
    if not isinstance(lst, list) or not all(isinstance(i, dict) and i.get('kind') == kind for i in lst):
        raise ValueError(f'{name}: unexpected item kind')
    return lst

def uid_range(nsdoc):
    raw = ((nsdoc.get('metadata') or {}).get('annotations') or {}).get('openshift.io/sa.scc.uid-range', '')
    start, _, size = raw.partition('/')
    if not (start.isdigit() and size.isdigit() and int(size) > 0):
        raise ValueError(f'namespace uid-range annotation invalid: {raw!r}')
    return int(start), int(size)

def template_findings(dep):
    f = []
    spec = dep['spec']['template']['spec']
    psc = spec.get('securityContext') or {}
    if 'runAsUser' in psc or 'runAsGroup' in psc:
        f.append('template pod runAsUser/runAsGroup fixed')
    if psc.get('runAsNonRoot') is not True:
        f.append('template runAsNonRoot not true')
    if (psc.get('seccompProfile') or {}).get('type') != 'RuntimeDefault':
        f.append('template seccomp not RuntimeDefault')
    for c in spec.get('containers') or []:
        sc = c.get('securityContext') or {}
        n = c.get('name')
        if 'runAsUser' in sc or 'runAsGroup' in sc:
            f.append(f'template container {n} runAsUser/runAsGroup fixed')
        if sc.get('readOnlyRootFilesystem') is not True:
            f.append(f'template container {n} readOnlyRootFilesystem not true')
        if sc.get('allowPrivilegeEscalation') is not False:
            f.append(f'template container {n} allowPrivilegeEscalation not false')
        if sc.get('privileged') is True:
            f.append(f'template container {n} privileged')
        if 'ALL' not in ((sc.get('capabilities') or {}).get('drop') or []):
            f.append(f'template container {n} capabilities.drop lacks ALL')
    return f

try:
    nsdoc = load('namespace')
    start, size = uid_range(nsdoc)
    deps = {d['metadata']['name']: d for d in items(load('deployments'), 'Deployment', 'deployments')}
    rss = items(load('replicasets'), 'ReplicaSet', 'replicasets')
    pods = items(load('pods'), 'Pod', 'pods')
    if sorted(deps) != sorted(EXPECT):
        raise ValueError(f'deployments={sorted(deps)}')
except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
    errors.append(f'collect: {e}')
    deps, rss, pods, start, size = {}, [], [], 0, 0

for name, image in EXPECT.items():
    dep = deps.get(name)
    if dep is None:
        continue
    try:
        meta, spec, st = dep['metadata'], dep['spec'], dep.get('status') or {}
        if meta.get('namespace') != ns:
            raise ValueError('deployment namespace mismatch')
        rev = (meta.get('annotations') or {}).get('deployment.kubernetes.io/revision')
        cur = [r for r in rss
               if any(o.get('kind') == 'Deployment' and o.get('uid') == meta['uid'] for o in r['metadata'].get('ownerReferences') or [])
               and (r['metadata'].get('annotations') or {}).get('deployment.kubernetes.io/revision') == rev]
        if not rev or len(cur) != 1:
            raise ValueError(f'current replicaset not unique (revision={rev}, found={len(cur)})')
        rs_uid = cur[0]['metadata']['uid']
        mine = [p for p in pods
                if any(o.get('kind') == 'ReplicaSet' and o.get('uid') == rs_uid for o in p['metadata'].get('ownerReferences') or [])]
        replicas = spec.get('replicas')
        if not isinstance(replicas, int) or replicas < 1:
            raise ValueError(f'replicas={replicas!r}')
        rollout_ok = (st.get('observedGeneration', -1) >= meta.get('generation', 0)
                      and st.get('updatedReplicas') == replicas and st.get('readyReplicas') == replicas
                      and st.get('availableReplicas') == replicas and len(mine) == replicas)
        tmpl = template_findings(dep)
        tmpl_images = [c.get('image') for c in spec['template']['spec'].get('containers') or []]
        img_findings = [] if tmpl_images == [image] else [f'template image {tmpl_images}']
        want_digest = image.rsplit('@', 1)[1]
        pod_rows = []
        for p in mine:
            pm, ps, pst = p['metadata'], p['spec'], p.get('status') or {}
            scc = (pm.get('annotations') or {}).get('openshift.io/scc')
            cs = (ps.get('containers') or [{}])[0]
            csc = cs.get('securityContext') or {}
            uid = csc.get('runAsUser', (ps.get('securityContext') or {}).get('runAsUser'))
            statuses = pst.get('containerStatuses') or []
            image_id = statuses[0].get('imageID', '') if statuses else ''
            got_digest = image_id.rsplit('@', 1)[1] if '@sha256:' in image_id else ''
            pod_rows.append({
                'pod': pm.get('name'), 'scc': scc, 'uid': uid, 'phase': pst.get('phase'),
                'ready': bool(statuses) and all(s.get('ready') is True for s in statuses),
                'restarts': sum(int(s.get('restartCount', 0)) for s in statuses),
                'image': cs.get('image'), 'image_id': image_id,
                'live_read_only_root': csc.get('readOnlyRootFilesystem'),
                'scc_ok': scc == 'restricted-v2',
                'uid_ok': isinstance(uid, int) and uid != 10001 and start <= uid < start + size,
                'image_ok': cs.get('image') == image,
                'digest_ok': got_digest == want_digest,
            })
        rows.append({'deployment': name, 'replicas': replicas, 'pods': pod_rows, 'rollout_ok': rollout_ok,
                     'template_findings': tmpl, 'image_findings': img_findings})
    except (ValueError, KeyError, TypeError, AttributeError, IndexError) as e:
        errors.append(f'{name}: {e}')

def any_pod(row, key):
    return any(not p[key] for p in row['pods'])

if errors or len(rows) != 2:
    code, summary = 11, 'COLLECTION_ERROR'
elif any(any_pod(r, 'scc_ok') or any_pod(r, 'uid_ok') for r in rows):
    code, summary = 31, 'SCC_OR_UID_NOT_PORTABLE'
elif any(r['template_findings'] or any(p['live_read_only_root'] is not True for p in r['pods']) for r in rows):
    code, summary = 32, 'SECURITY_CONTEXT_MISMATCH'
elif any(r['image_findings'] or any_pod(r, 'image_ok') or any_pod(r, 'digest_ok') for r in rows):
    code, summary = 33, 'IMAGE_DIGEST_REVIEW_REQUIRED'
elif any(not r['rollout_ok'] or any(not p['ready'] or p['phase'] != 'Running' for p in r['pods']) for r in rows):
    code, summary = 30, 'NOT_READY'
else:
    code, summary = 0, 'OBSERVED_AS_EXPECTED'

result = {'summary': summary, 'rc': code, 'uid_range': [start, size], 'rows': rows, 'errors': errors,
          'cluster_mutation': 'NONE', 'write_test': 'NOT_RUN(exec 범위 밖)', 'pg03': 'NOT_DECIDED_BY_THIS_TOOL'}
json.dump(result, open(os.path.join(out, 'observe-result.json'), 'w'), indent=1, sort_keys=True)
with open(os.path.join(out, 'observe-result.txt'), 'w') as f:
    f.write(f'UID_RANGE={start}/{size}\n')
    for r in rows:
        f.write(f"{r['deployment']}\treplicas={r['replicas']}\trollout_ok={r['rollout_ok']}\n")
        for x in r['template_findings'] + r['image_findings']:
            f.write(f'  FINDING\t{x}\n')
        for p in r['pods']:
            f.write(f"  {p['pod']}\tscc={p['scc']}\tuid={p['uid']}\tphase={p['phase']}\tready={p['ready']}"
                    f"\trestarts={p['restarts']}\tro_root={p['live_read_only_root']}\tdigest_ok={p['digest_ok']}\n")
    for e in errors:
        f.write(f'ERROR\t{e}\n')
    f.write(f'SUMMARY={summary}\nCLUSTER_MUTATION=NONE\nWRITE_TEST=NOT_RUN\n')
    f.write('주의: 관측 결과는 PG03 입력이다. PG03 판정은 Lead가 admission·관측 결과와 함께 내린다.\n')
sys.exit(code)
PY
RESULT=$?
set -e

[[ "$("${OC[@]}" get namespace "$NS" -o 'jsonpath={.metadata.uid}')" == "$EXPECTED_NS_UID" ]] \
  || die 10 "실행 중 namespace UID 변경"
(cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
cat "$OUT_DIR/observe-result.txt"
echo "EVIDENCE_DIR=$OUT_DIR"
exit "$RESULT"
