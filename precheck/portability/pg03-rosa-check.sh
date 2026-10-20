#!/usr/bin/env bash
# infra-rosa#6 PG-03 — ROSA restricted-v2 SCC admission 수집기 (v2, admission 전용)
#
# 하는 일(영구 자원 변경 없음. 단 scc-subject-review는 review API에 대한 Create(POST)라
#   get 권한만으로는 안 될 수 있다 — #5의 승인된 조회·리뷰 주체로 실행):
#   fds-msa deploy/base 실제 manifest를 portable(T2, UID 고정 없음)과 fixed(T1, Phase 1 UID/GID)로 렌더한다.
#   렌더 결과에서 Deployment 2개만 골라, 각 Deployment의 앱 ServiceAccount 단독 주체(-z)로
#   `oc adm policy scc-subject-review`를 돌리고 allowedBy SCC를 구조적으로 판정한다.
#
# 하지 않는 것: apply/create/delete/label/patch/exec 등 모든 쓰기. Runtime(실제 Pod 기동) 시험은
#   소유권 장부·정리 설계 후 별도 PR에서 다룬다(PR36 리뷰 B1/B2). MODE=runtime은 입력 단계에서 거부한다.
#
# 결과는 admission 참고 근거다. 실제 SCC annotation/UID/기동 확인을 대체하지 않으며 PG03 PASS가 아니다.
#
# 입력(모두 필수):
#   CTX, API(https://host[:port]), NS, PORT_ENV=ROSA|SHARED_OCP_LAB
#   EXPECTED_CLUSTER_ID, EXPECTED_NS_UID   승인된 inventory 값(UUID)
#   MSA_DIR  fds-msa clean checkout,  MSA_SHA  기대 40-hex HEAD
#   TX_IMAGE, ENG_IMAGE  <registry>/<repo>@sha256:<64hex>
# 선택: OUT_DIR(없어야 함)
#
# 종료 코드:
#   0  portable 2건 모두 restricted-v2, fixed 2건 모두 거부(allowedBy 없음)
#   2  입력 오류(oc 호출 전)          10 대상 불일치(서버/Cluster ID/NS UID)
#   11 수집·파싱 오류(렌더, 변환, 리뷰 rc≠0, 대상 누락, SA 조회 오류)
#   20 portable이 restricted-v2가 아님(거부 또는 더 넓은 SCC)
#   21 fixed가 예상과 달리 허용됨(restricted-v2 또는 더 넓은 SCC)
set -euo pipefail
umask 077

die() { local rc="$1"; shift; echo "STOP: $*" >&2; exit "$rc"; }

MODE="${MODE:-admission}"; CTX="${CTX:-}"; API="${API:-}"; NS="${NS:-}"; PORT_ENV="${PORT_ENV:-}"
EXPECTED_CLUSTER_ID="${EXPECTED_CLUSTER_ID:-}"; EXPECTED_NS_UID="${EXPECTED_NS_UID:-}"
MSA_DIR="${MSA_DIR:-}"; MSA_SHA="${MSA_SHA:-}"; TX_IMAGE="${TX_IMAGE:-}"; ENG_IMAGE="${ENG_IMAGE:-}"
OUT_DIR="${OUT_DIR:-}"

# ---- 입력 검사 (oc 호출 전) ----
[[ "$MODE" == admission ]] || die 2 "MODE=admission만 지원(runtime은 HOLD: 소유권·정리 재설계 후 별도 PR)"
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
[[ "$MSA_SHA" =~ ^[0-9a-f]{40}$ ]] || die 2 "MSA_SHA는 40-hex"
for c in oc git python3 sha256sum date mktemp realpath; do command -v "$c" >/dev/null || die 2 "명령 없음: $c"; done

# fds-msa source 고정: 지정 SHA + clean worktree
[[ -d "$MSA_DIR/deploy/base" ]] || die 2 "MSA_DIR/deploy/base 없음"
[[ "$(git -C "$MSA_DIR" rev-parse --verify HEAD)" == "$MSA_SHA" ]] || die 2 "fds-msa HEAD != MSA_SHA"
[[ -z "$(git -C "$MSA_DIR" status --porcelain --untracked-files=normal)" ]] || die 2 "fds-msa worktree dirty"
MSA_DIR="$(realpath "$MSA_DIR")"

SELF="$(realpath "${BASH_SOURCE[0]}")"
SELF_SHA="$(sha256sum "$SELF" | cut -d' ' -f1)"

if [[ -z "$OUT_DIR" ]]; then
  mkdir -p ./evidence-local/pg03
  OUT_DIR="$(mktemp -d "./evidence-local/pg03/admission.XXXXXX")"
else
  mkdir -m 700 -- "$OUT_DIR" 2>/dev/null || die 2 "OUT_DIR 이미 있음/생성 실패(덮어쓰지 않음)"
fi
OUT_DIR="$(realpath "$OUT_DIR")"
trap 'rc=$?; [[ $rc -ne 0 ]] && echo "RESULT_RC=$rc; 보존: $OUT_DIR" >&2' EXIT

# 명령 하나를 시각·rc·stdout·stderr로 남긴다. 판정은 rc와 내용으로 한다.
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
run ns-uid "${OC[@]}" get namespace "$NS" -o 'jsonpath={.metadata.uid}'
[[ "$(rc_of ns-uid)" == 0 && "$(cat "$OUT_DIR/ns-uid.out")" == "$EXPECTED_NS_UID" ]] \
  || die 10 "Namespace UID가 승인 inventory와 다르거나 조회 불가"

run whoami "${OC[@]}" whoami
run oc-version "${OC[@]}" version
run ns-scc-annotations "${OC[@]}" get namespace "$NS" -o \
  'jsonpath={.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{"\n"}'
{
  echo "ENV=$PORT_ENV"; echo "MODE=admission"
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
  echo "CTX=$CTX"; echo "API=$API"; echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID"
  echo "NS=$NS"; echo "NAMESPACE_UID=$EXPECTED_NS_UID"
  echo "MSA_SHA=$MSA_SHA"; echo "TX_IMAGE=$TX_IMAGE"; echo "ENG_IMAGE=$ENG_IMAGE"
  echo "COLLECTOR_SHA256=$SELF_SHA"
  echo "COLLECTOR_GIT_HEAD=$(git -C "$(dirname "$SELF")" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "WHOAMI_RC=$(rc_of whoami) WHOAMI=$(cat "$OUT_DIR/whoami.out")"
} >"$OUT_DIR/context.txt"

# ---- 렌더: fds-msa base를 가리키는 임시 overlay 2벌(라벨 추가 없음) ----
mkdir -p "$OUT_DIR/portable" "$OUT_DIR/fixed"
REL_BASE="$(realpath -m --relative-to="$OUT_DIR/portable" "$MSA_DIR/deploy/base")"
cat >"$OUT_DIR/portable/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NS}
resources:
  - ${REL_BASE}
images:
  - name: transaction-api
    newName: ${TX_IMAGE%@*}
    digest: ${TX_IMAGE##*@}
  - name: fds-engine
    newName: ${ENG_IMAGE%@*}
    digest: ${ENG_IMAGE##*@}
EOF
# fixed = portable + Phase 1 고정값(fds-msa deploy/overlays/p1-onprem/deployment-p1.yaml 의 UID/GID만)
cat >"$OUT_DIR/fixed/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../portable
patches:
  - target:
      kind: Deployment
    patch: |-
      - op: add
        path: /spec/template/spec/securityContext/runAsUser
        value: 10001
      - op: add
        path: /spec/template/spec/securityContext/runAsGroup
        value: 999
EOF

for v in portable fixed; do
  run "render-$v" oc kustomize "$OUT_DIR/$v"
  [[ "$(rc_of "render-$v")" == 0 ]] || die 11 "kustomize 렌더 실패($v)"
  # 렌더 YAML → JSON. client dry-run이라 서버에 쓰지 않는다(리소스 매핑 조회만).
  run "json-$v" "${OC[@]}" create --dry-run=client -o json -f "$OUT_DIR/render-$v.out"
  [[ "$(rc_of "json-$v")" == 0 ]] || die 11 "렌더 JSON 변환 실패($v)"
done

# Deployment만 추출(SA/Service/NetworkPolicy는 Pod template이 없어 리뷰 대상이 아님).
python3 - "$OUT_DIR" "$NS" <<'PY' || die 11 "Deployment 추출 실패(대상 2건 아님 또는 형식 오류)"
import json, sys, os
out, ns = sys.argv[1], sys.argv[2]
EXPECT = {'fds-engine': 'fds-engine-sa', 'transaction-api': 'transaction-api-sa'}
targets = []

def read_objects(path):
    """oc create --dry-run=client -o json 출력을 읽는다.
    oc 4.22.17은 여러 객체를 List 하나가 아니라 JSON 객체를 이어 붙여 출력한다(2026-10-20 ROSA 실측).
    List 하나든 이어 붙인 객체든 받고, 객체가 없거나 중간에 깨졌으면 실패한다."""
    text = open(path).read()
    dec, pos, objs = json.JSONDecoder(), 0, []
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos == len(text):
            break
        obj, pos = dec.raw_decode(text, pos)
        if not isinstance(obj, dict):
            raise ValueError('top-level JSON value is not an object')
        if obj.get('kind') == 'List':
            if not isinstance(obj.get('items'), list):
                raise ValueError('List without items')
            objs.extend(obj['items'])
        else:
            objs.append(obj)
    if not objs or not all(isinstance(o, dict) for o in objs):
        raise ValueError('no objects')
    return objs

for v in ('portable', 'fixed'):
    items = read_objects(os.path.join(out, f'json-{v}.out'))
    deps = [i for i in items if i.get('kind') == 'Deployment']
    names = sorted(d['metadata']['name'] for d in deps)
    assert names == sorted(EXPECT), names
    for d in deps:
        name = d['metadata']['name']
        spec = d['spec']['template']['spec']
        sc = spec.get('securityContext') or {}
        assert d['metadata'].get('namespace') == ns
        assert spec.get('serviceAccountName') == EXPECT[name]
        if v == 'portable':
            assert 'runAsUser' not in sc and 'runAsGroup' not in sc
        else:
            assert sc.get('runAsUser') == 10001 and sc.get('runAsGroup') == 999
        path = os.path.join(out, f'deploy-{v}-{name}.json')
        json.dump(d, open(path, 'w'), sort_keys=True)
        targets.append(f'{v}\t{name}\t{EXPECT[name]}')
open(os.path.join(out, 'targets.tsv'), 'w').write('\n'.join(targets) + '\n')
PY

# ---- 앱 SA 상태 기록: NotFound만 부재로 인정, 그 밖의 오류는 중단 ----
for sa in fds-engine-sa transaction-api-sa; do
  run "sa-$sa" "${OC[@]}" -n "$NS" get serviceaccount "$sa" -o 'jsonpath={.metadata.uid}'
  if [[ "$(rc_of "sa-$sa")" != 0 ]] && ! grep -q 'NotFound' "$OUT_DIR/sa-$sa.err"; then
    die 11 "SA 조회 오류($sa): NotFound가 아님(sa-$sa.err 확인)"
  fi
done

# ---- admission: 앱 SA 단독 주체(-z)로 Deployment별 평가 ----
# -z 없이 실행하면 self-subject review가 되어 실행자 권한이 섞인다.
while IFS=$'\t' read -r v name sa; do
  run "review-$v-$name" "${OC[@]}" -n "$NS" adm policy scc-subject-review -z "$sa" \
    -f "$OUT_DIR/deploy-$v-$name.json" -o json
done <"$OUT_DIR/targets.tsv"

set +e
python3 - "$OUT_DIR" <<'PY'
import json, os, sys
out = sys.argv[1]
rows, errors = [], []
for line in open(os.path.join(out, 'targets.tsv')).read().split('\n'):
    if not line:
        continue
    v, name, sa = line.split('\t')
    base = os.path.join(out, f'review-{v}-{name}')
    rc = open(base + '.rc').read().strip()
    allowed, reason = None, ''
    try:
        if rc != '0':
            raise ValueError(f'rc={rc}')
        doc = json.load(open(base + '.out'))
        items = doc['items'] if 'items' in doc else [doc]
        if len(items) != 1:
            raise ValueError(f'items={len(items)}')
        # 응답 형식을 확인한다. 비었거나 깨진 응답을 "거부"로 읽지 않는다(리뷰 B4).
        item = items[0]
        if not isinstance(item, dict):
            raise ValueError('review item is not an object')
        if item.get('apiVersion') != 'security.openshift.io/v1' or item.get('kind') != 'PodSecurityPolicySubjectReview':
            raise ValueError('unexpected review type')
        status = item.get('status')
        if not isinstance(status, dict):
            raise ValueError('missing/invalid review status')
        allowed_ref = status.get('allowedBy')
        if allowed_ref is not None:
            if not isinstance(allowed_ref, dict) or not isinstance(allowed_ref.get('name'), str) or not allowed_ref['name']:
                raise ValueError('invalid allowedBy')
        allowed = None if allowed_ref is None else allowed_ref['name']
        reason = status.get('reason', '')
        if not isinstance(reason, str):
            raise ValueError('invalid reason')
        # status.template은 API상 optional(omitempty)이다. 있으면 객체여야 한다.
        if 'template' in status and not isinstance(status['template'], dict):
            raise ValueError('invalid template')
        # 거부로 읽으려면 근거(비어 있지 않은 reason 또는 template 객체)가 있어야 한다(리뷰 B4 잔여).
        # 실제 oc 응답 형식은 첫 승인 회차 원문으로 확인한다. 현장에서 이 기준을 느슨하게 바꾸지 않는다.
        if allowed_ref is None and not reason.strip() and not isinstance(status.get('template'), dict):
            raise ValueError('missing denial evidence')
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        errors.append(f'{v}/{name}: {e}')
        continue
    sa_rc = open(os.path.join(out, f'sa-{sa}.rc')).read().strip()
    rows.append({'variant': v, 'deployment': name, 'service_account': sa,
                 'sa_present': sa_rc == '0', 'allowed_by': allowed, 'reason': reason})

def verdict(row):
    a = row['allowed_by']
    if row['variant'] == 'portable':
        return 'RESTRICTED_V2' if a == 'restricted-v2' else ('REJECTED' if a is None else 'BROADER_SCC:' + a)
    return 'REJECTED' if a is None else ('ALLOWED_RESTRICTED_V2' if a == 'restricted-v2' else 'ALLOWED_BY_OTHER_SCC:' + a)

for r in rows:
    r['verdict'] = verdict(r)
if errors or len(rows) != 4:
    code, summary = 11, 'COLLECTION_ERROR'
elif any(r['variant'] == 'portable' and r['verdict'] != 'RESTRICTED_V2' for r in rows):
    code, summary = 20, 'PORTABLE_NOT_RESTRICTED_V2'
elif any(r['variant'] == 'fixed' and r['verdict'] != 'REJECTED' for r in rows):
    code, summary = 21, 'FIXED_UNEXPECTEDLY_ALLOWED'
else:
    code, summary = 0, 'ADMISSION_AS_EXPECTED'
result = {'summary': summary, 'rc': code, 'rows': rows, 'errors': errors,
          'cluster_mutation': 'NONE', 'runtime': 'NOT_RUN', 'pg03': 'NOT_DECIDED_BY_THIS_TOOL'}
json.dump(result, open(os.path.join(out, 'admission-result.json'), 'w'), indent=1, sort_keys=True)
with open(os.path.join(out, 'admission-result.txt'), 'w') as f:
    for r in rows:
        f.write(f"{r['variant']}\t{r['deployment']}\t{r['service_account']}\tsa_present={r['sa_present']}"
                f"\tallowedBy={r['allowed_by'] or '<none>'}\t{r['verdict']}\n")
    for e in errors:
        f.write(f'ERROR\t{e}\n')
    f.write(f'SUMMARY={summary}\nCLUSTER_MUTATION=NONE\nRUNTIME=NOT_RUN\n')
    f.write('주의: admission 참고 근거. 실제 SCC annotation/UID/기동 확인과 PG03 판정은 별도.\n')
    if any(not r['sa_present'] for r in rows):
        f.write('주의: 앱 SA가 없는 상태의 평가(이름 기준). SA 생성 후 재확인 필요.\n')
sys.exit(code)
PY
RESULT=$?
set -e

# 마지막 대상 확인도 시각·출력·RC를 남기고, rc=0과 UID 일치를 함께 본다(PR39 R3와 같은 보완).
run namespace-final "${OC[@]}" get namespace "$NS" -o 'jsonpath={.metadata.uid}'
[[ "$(rc_of namespace-final)" == 0 && "$(cat "$OUT_DIR/namespace-final.out")" == "$EXPECTED_NS_UID" ]] \
  || die 10 "실행 중 namespace UID 변경 또는 최종 조회 실패(namespace-final.err 확인)"
(cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
cat "$OUT_DIR/admission-result.txt"
echo "EVIDENCE_DIR=$OUT_DIR"
exit "$RESULT"
