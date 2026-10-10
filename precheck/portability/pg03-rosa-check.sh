#!/usr/bin/env bash
# infra-rosa#6 PG-03 — ROSA restricted-v2 portable SecurityContext 재검증 수집기 (초안 v1)
#
# MODE=admission  읽기 전용. fds-msa 실제 manifest를 고정 UID(T1) / portable(T2) 두 벌로 렌더하고
#                 oc adm policy scc-subject-review 로 어떤 SCC가 받아주는지 기록한다. 클러스터 변경 없음.
# MODE=runtime    변경 있음(별도 GO 필요). portable 렌더(replicas 1, Route 없음)를 지정 namespace에
#                 apply → UID/GID·SCC·imageID·RO 루트·liveness/Ready 확인 → 삭제·잔여 확인.
#
# 비용: admission은 조회만이라 추가 비용 없음. runtime은 이미 떠 있는 Worker에 Pod 4개를 잠깐 올리며
#       새 AWS 리소스를 만들지 않는다. 비용 판정은 이권욱 소관.
#
# 입력(모두 필수):
#   CTX, API(https://...), NS, PORT_ENV=ROSA|SHARED_OCP_LAB
#   MSA_DIR  fds-msa clean checkout,  MSA_SHA  기대 40-hex HEAD
#   TX_IMAGE, ENG_IMAGE  <registry>/<repo>@sha256:<64hex>
# 선택: PULL_SECRET_NAME(namespace에 미리 만든 pull secret 이름), OUT_DIR
set -euo pipefail
umask 077

die() { echo "STOP: $*" >&2; exit 1; }

MODE="${MODE:-}"; CTX="${CTX:-}"; API="${API:-}"; NS="${NS:-}"; PORT_ENV="${PORT_ENV:-}"
MSA_DIR="${MSA_DIR:-}"; MSA_SHA="${MSA_SHA:-}"; TX_IMAGE="${TX_IMAGE:-}"; ENG_IMAGE="${ENG_IMAGE:-}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-}"; OUT_DIR="${OUT_DIR:-}"

[[ "$MODE" == admission || "$MODE" == runtime ]] || die "MODE=admission|runtime"
[[ -n "$CTX" ]] || die "CTX 필요"
[[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "API는 https://host[:port]"
[[ "$PORT_ENV" == ROSA || "$PORT_ENV" == SHARED_OCP_LAB ]] || die "PORT_ENV=ROSA|SHARED_OCP_LAB"
(( ${#NS} <= 63 )) && [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "NS는 DNS-1123 label"
IMG_RE='^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[0-9a-f]{64}$'
[[ "$TX_IMAGE" =~ $IMG_RE && "$ENG_IMAGE" =~ $IMG_RE ]] || die "TX_IMAGE/ENG_IMAGE는 @sha256:<64hex> 고정"
[[ -z "$PULL_SECRET_NAME" || "$PULL_SECRET_NAME" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "PULL_SECRET_NAME 형식"
[[ "$MSA_SHA" =~ ^[0-9a-f]{40}$ ]] || die "MSA_SHA는 40-hex"
for c in oc git sha256sum date mktemp realpath; do command -v "$c" >/dev/null || die "명령 없음: $c"; done

# fds-msa source 고정: 지정 SHA + clean worktree
[[ -d "$MSA_DIR/deploy/base" ]] || die "MSA_DIR/deploy/base 없음"
[[ "$(git -C "$MSA_DIR" rev-parse --verify HEAD)" == "$MSA_SHA" ]] || die "fds-msa HEAD != MSA_SHA"
[[ -z "$(git -C "$MSA_DIR" status --porcelain --untracked-files=normal)" ]] || die "fds-msa worktree dirty"
MSA_DIR="$(realpath "$MSA_DIR")"

OC=(oc --context="$CTX" --server="$API" --insecure-skip-tls-verify=false)

if [[ -z "$OUT_DIR" ]]; then
  mkdir -p ./evidence-local/pg03
  OUT_DIR="$(mktemp -d "./evidence-local/pg03/${MODE}.XXXXXX")"
else
  mkdir -m 700 -- "$OUT_DIR" || die "OUT_DIR 이미 있음/생성 실패(덮어쓰지 않음)"
fi
OUT_DIR="$(realpath "$OUT_DIR")"
trap 'rc=$?; [[ $rc -ne 0 ]] && echo "CAPTURE_INCOMPLETE RC=$rc; 보존: $OUT_DIR" >&2' EXIT

# 명령 하나를 rc·stdout·stderr 파일로 남긴다. 실패해도 계속하고 rc로 판정한다.
run() {
  local name="$1"; shift
  set +e
  "$@" >"$OUT_DIR/$name.out" 2>"$OUT_DIR/$name.err"
  echo $? >"$OUT_DIR/$name.rc"
  set -e
  return 0
}
rc_of() { cat "$OUT_DIR/$1.rc"; }

# ---- 대상 확인 ----
NS_UID="$("${OC[@]}" get namespace "$NS" -o jsonpath='{.metadata.uid}')" || die "namespace 조회 실패"
[[ -n "$NS_UID" ]] || die "namespace UID 비어 있음"
{
  echo "ENV=$PORT_ENV"; echo "MODE=$MODE"
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
  echo "CTX=$CTX"; echo "API=$API"; echo "NS=$NS"; echo "NAMESPACE_UID=$NS_UID"
  echo "MSA_SHA=$MSA_SHA"; echo "TX_IMAGE=$TX_IMAGE"; echo "ENG_IMAGE=$ENG_IMAGE"
  echo "PULL_SECRET_NAME=${PULL_SECRET_NAME:-<none>}"
  echo "=== whoami ==="; "${OC[@]}" whoami
  echo "=== version ==="; "${OC[@]}" version
  echo "=== cluster id ==="; "${OC[@]}" get clusterversion version -o jsonpath='{.spec.clusterID}{"\n"}' 2>&1 || true
  echo "=== ns scc annotations (uid-range / supplemental-groups) ==="
  "${OC[@]}" get namespace "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{"\n"}'
} >"$OUT_DIR/context.txt" 2>&1

# ---- 렌더: fds-msa base를 가리키는 임시 overlay 2벌 ----
mkdir -p "$OUT_DIR/portable" "$OUT_DIR/fixed"
REL_BASE="$(realpath -m --relative-to="$OUT_DIR/portable" "$MSA_DIR/deploy/base")"

PULL_PATCH=""
if [[ -n "$PULL_SECRET_NAME" ]]; then
  PULL_PATCH="  - target:
      kind: Deployment
    patch: |-
      - op: add
        path: /spec/template/spec/imagePullSecrets
        value:
          - name: ${PULL_SECRET_NAME}"
fi

# portable = base 그대로(UID/GID 없음) + namespace + digest + replicas 1. Route·lab-db 없음.
cat >"$OUT_DIR/portable/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NS}
resources:
  - ${REL_BASE}
commonLabels:
  fds.321team/probe: pg03
images:
  - name: transaction-api
    newName: ${TX_IMAGE%@*}
    digest: ${TX_IMAGE##*@}
  - name: fds-engine
    newName: ${ENG_IMAGE%@*}
    digest: ${ENG_IMAGE##*@}
patches:
  - target:
      kind: Deployment
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
${PULL_PATCH}
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

run render-portable "${OC[@]:0:1}" kustomize "$OUT_DIR/portable"
run render-fixed    "${OC[@]:0:1}" kustomize "$OUT_DIR/fixed"
[[ "$(rc_of render-portable)" == 0 && "$(rc_of render-fixed)" == 0 ]] || die "kustomize 렌더 실패(*.err 확인)"
cp "$OUT_DIR/render-portable.out" "$OUT_DIR/rendered-portable.yaml"
cp "$OUT_DIR/render-fixed.out"    "$OUT_DIR/rendered-fixed.yaml"
grep -q 'runAsUser' "$OUT_DIR/rendered-portable.yaml" && die "portable 렌더에 runAsUser가 있음"
[[ "$(grep -c 'runAsUser: 10001' "$OUT_DIR/rendered-fixed.yaml")" == 2 ]] || die "fixed 렌더에 고정 UID 2건이 아님"

# ---- admission (읽기 전용) ----
# Deployment의 server dry-run은 SCC를 거치지 않는다(SCC는 Pod 생성 때 평가).
# 그래서 Pod 템플릿을 scc-subject-review로 평가한다. 결과의 allowedBy가 SCC 이름 또는 <none>.
for v in fixed portable; do
  run "t-${v}-scc-subject-review" "${OC[@]}" -n "$NS" adm policy scc-subject-review -f "$OUT_DIR/rendered-${v}.yaml"
done

{
  echo "MSA_SHA=$MSA_SHA"; echo "NS=$NS"; echo "ENV=$PORT_ENV"
  for v in fixed portable; do
    echo "T_${v^^}_REVIEW_RC=$(rc_of "t-${v}-scc-subject-review")"
    echo "--- T_${v^^} allowedBy (raw) ---"
    cat "$OUT_DIR/t-${v}-scc-subject-review.out"
  done
  echo "기대: FIXED → restricted-v2 아님(<none> 또는 더 넓은 SCC), PORTABLE → restricted-v2"
  echo "판정은 사람이 raw를 보고 내린다. 이 파일은 판정이 아니다."
} >"$OUT_DIR/admission-result.txt"

if [[ "$MODE" == admission ]]; then
  [[ "$("${OC[@]}" get namespace "$NS" -o jsonpath='{.metadata.uid}')" == "$NS_UID" ]] || die "namespace UID 변경"
  echo "CLUSTER_MUTATION=NONE" >>"$OUT_DIR/admission-result.txt"
  (cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
  cat "$OUT_DIR/admission-result.txt"; echo "EVIDENCE_DIR=$OUT_DIR"
  exit 0
fi

# ---- runtime (변경 있음) ----
[[ "${PG03_RUNTIME_GO:-}" == yes ]] || die "runtime은 PG03_RUNTIME_GO=yes(별도 GO 기록 후)일 때만"

# transaction-api는 import 시 DATABASE_URL이 없으면 죽는다. 실제 DB가 아닌 연결 불가 더미값을 쓴다.
# 이 Secret에는 credential이 없다. Ready(/readyz)는 DB가 필요하므로 #43 lab-db 범위로 넘긴다.
run secret-get "${OC[@]}" -n "$NS" get secret transaction-api-db-credentials -o name
[[ "$(rc_of secret-get)" != 0 ]] || die "transaction-api-db-credentials가 이미 있음 — 덮어쓰지 않음(#43 소유일 수 있음)"
run secret-create "${OC[@]}" -n "$NS" create secret generic transaction-api-db-credentials \
  --from-literal=DATABASE_URL='postgresql+asyncpg://pg03probe:unused@127.0.0.1:1/none'
[[ "$(rc_of secret-create)" == 0 ]] || die "더미 Secret 생성 실패"
run secret-label "${OC[@]}" -n "$NS" label secret transaction-api-db-credentials fds.321team/probe=pg03

run apply "${OC[@]}" -n "$NS" apply -f "$OUT_DIR/rendered-portable.yaml"
[[ "$(rc_of apply)" == 0 ]] || echo "WARN: apply rc=$(rc_of apply) — 정리 단계로 진행" >&2

run rollout-engine "${OC[@]}" -n "$NS" rollout status deployment/fds-engine --timeout=300s
# transaction-api는 Ready가 되지 않는 것이 정상(DB 없음). 컨테이너 시작까지만 기다린다.
run wait-tx "${OC[@]}" -n "$NS" wait pod -l app=transaction-api --for=jsonpath='{.status.containerStatuses[0].started}'=true --timeout=300s

run pods-yaml "${OC[@]}" -n "$NS" get pod -l fds.321team/probe=pg03 -o yaml
run pods-summary "${OC[@]}" -n "$NS" get pod -l fds.321team/probe=pg03 -o \
  jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\t"}{.spec.securityContext.runAsUser}{"\t"}{.spec.securityContext.fsGroup}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.containerStatuses[0].imageID}{"\n"}{end}'
run events "${OC[@]}" -n "$NS" get events --sort-by=.lastTimestamp

PY_CHECK='import os,urllib.request,sys
print("uid",os.getuid(),"gid",os.getgid(),"groups",os.getgroups())
for p in ("/app/.pg03-write-test","/tmp/.pg03-write-test"):
    try:
        open(p,"w").write("x"); print("WRITE_OK",p)
    except OSError as e:
        print("WRITE_DENIED",p,e.errno,e.strerror)
port=sys.argv[1]
for path in ("/livez","/readyz"):
    try:
        r=urllib.request.urlopen("http://127.0.0.1:"+port+path,timeout=5); print("HTTP",path,r.status)
    except Exception as e:
        print("HTTP",path,"ERR",getattr(e,"code",type(e).__name__))'
for app_port in "fds-engine:8001" "transaction-api:8000"; do
  app="${app_port%%:*}"; port="${app_port##*:}"
  pod="$("${OC[@]}" -n "$NS" get pod -l "app=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    run "exec-$app" "${OC[@]}" -n "$NS" exec "$pod" -- /venv/bin/python3 -c "$PY_CHECK" "$port"
  else
    echo "pod 없음" >"$OUT_DIR/exec-$app.err"; echo 99 >"$OUT_DIR/exec-$app.rc"
  fi
done

# ---- 정리 + 잔여 확인 (namespace는 #5 소유라 지우지 않는다) ----
run delete "${OC[@]}" -n "$NS" delete -f "$OUT_DIR/rendered-portable.yaml" --wait=true --timeout=180s
run delete-secret "${OC[@]}" -n "$NS" delete secret -l fds.321team/probe=pg03 --wait=true
run remaining "${OC[@]}" -n "$NS" get deployment,replicaset,pod,service,serviceaccount,networkpolicy,secret -l fds.321team/probe=pg03 -o name
CLEANUP=FAIL
if [[ "$(rc_of delete)" == 0 && "$(rc_of delete-secret)" == 0 && "$(rc_of remaining)" == 0 && ! -s "$OUT_DIR/remaining.out" ]]; then
  CLEANUP=OK
fi
[[ "$("${OC[@]}" get namespace "$NS" -o jsonpath='{.metadata.uid}')" == "$NS_UID" ]] || die "namespace UID 변경"

{
  echo "MSA_SHA=$MSA_SHA"; echo "NS=$NS"; echo "ENV=$PORT_ENV"
  for s in apply rollout-engine wait-tx exec-fds-engine exec-transaction-api delete delete-secret remaining; do
    echo "RC_${s}=$(rc_of "$s")"
  done
  echo "--- pods (name / scc / runAsUser / fsGroup / phase / ready / restarts / imageID) ---"
  cat "$OUT_DIR/pods-summary.out"
  echo "--- exec fds-engine ---"; cat "$OUT_DIR/exec-fds-engine.out"
  echo "--- exec transaction-api ---"; cat "$OUT_DIR/exec-transaction-api.out"
  echo "CLEANUP=$CLEANUP"
  echo "판정 기준은 계획서 §4. 이 파일은 판정이 아니다."
} >"$OUT_DIR/runtime-result.txt"

(cd "$OUT_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
cat "$OUT_DIR/admission-result.txt" "$OUT_DIR/runtime-result.txt"
echo "EVIDENCE_DIR=$OUT_DIR"
[[ "$CLEANUP" == OK ]] || exit 30
exit 0
