#!/usr/bin/env bash
set -u
set -o pipefail

usage() {
  cat <<'EOF'
Usage:
  PORT_NS=<approved-shared-ocp-namespace> \
  APP_IMAGE=<approved-image@sha256:...> \
  ./precheck/portability/uid-scc-admission.sh

Optional:
  OUT_DIR=<local-evidence-dir>

This precheck is admission-only. It never creates or modifies cluster resources.
It submits Pod objects with --dry-run=server to compare:
  T1 fixed UID/GID from Phase 1
  T2 portable securityContext without fixed UID/GID
EOF
}

PORT_NS="${PORT_NS:-}"
APP_IMAGE="${APP_IMAGE:-}"
OUT_DIR="${OUT_DIR:-}"

if [ -z "$PORT_NS" ] || [ -z "$APP_IMAGE" ]; then
  usage >&2
  exit 2
fi

if [[ ! "$APP_IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[0-9a-f]{64}$ ]]; then
  echo "ERROR: APP_IMAGE requires a valid image reference and exact 64-hex SHA256." >&2
  exit 3
fi

if (( ${#PORT_NS} > 63 )) || [[ ! "$PORT_NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "ERROR: PORT_NS must be a DNS-1123 label, length 1..63." >&2
  exit 6
fi

for cmd in oc sha256sum date git; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $cmd" >&2
    exit 4
  }
done

SOURCE_SHA="$(git rev-parse --verify HEAD 2>/dev/null)" || {
  echo "ERROR: exact Git HEAD unavailable." >&2
  exit 7
}
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: exact 40-hex Git HEAD required." >&2
  exit 7
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 7
CALLER_ROOT="$(git rev-parse --show-toplevel)" || exit 7
SCRIPT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 7
if [ "$CALLER_ROOT" != "$SCRIPT_ROOT" ]; then
  echo "ERROR: run from the script's Git repository." >&2
  exit 7
fi
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
git -C "$SCRIPT_DIR" ls-files --error-unmatch -- "$SCRIPT_NAME" >/dev/null 2>&1 || {
  echo "ERROR: executing script is not tracked by this HEAD." >&2
  exit 9
}
SCRIPT_PREFIX="$(git -C "$SCRIPT_DIR" rev-parse --show-prefix)" || exit 9
EXPECTED_SCRIPT_BLOB="$(git rev-parse "HEAD:${SCRIPT_PREFIX}${SCRIPT_NAME}")" || exit 9
ACTUAL_SCRIPT_BLOB="$(git -C "$SCRIPT_DIR" hash-object -- "$SCRIPT_NAME")" || exit 9
if [ "$EXPECTED_SCRIPT_BLOB" != "$ACTUAL_SCRIPT_BLOB" ]; then
  echo "ERROR: executing script differs from HEAD." >&2
  exit 9
fi
DIRTY="$(git status --porcelain --untracked-files=normal)" || exit 7
if [ -n "$DIRTY" ]; then
  echo "ERROR: dirty worktree; commit/review inputs before running." >&2
  exit 8
fi

TS="$(date +%Y%m%dT%H%M%S%z)"
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="./evidence-local/p2-portability-w0/${TS}"
fi
mkdir -p "$OUT_DIR" || exit 5
chmod 700 "$OUT_DIR" 2>/dev/null || true


{
  echo "=== CONTEXT ==="
  date --iso-8601=seconds
  echo "SOURCE_SHA=$SOURCE_SHA"
  echo "PORT_NS=$PORT_NS"
  echo "APP_IMAGE_DIGEST=${APP_IMAGE##*@}"
  echo
  echo "=== OC CLIENT/SERVER ==="
  oc version || true
  echo
  echo "=== NAMESPACE ==="
  oc get namespace "$PORT_NS" -o name
  echo "NS_RC=$?"
  echo
  echo "=== UID RANGE ==="
  oc get namespace "$PORT_NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}' || true
  echo "=== SUPPLEMENTAL GROUP RANGE ==="
  oc get namespace "$PORT_NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{"\n"}' || true
} >"$OUT_DIR/context.txt" 2>&1

if ! oc get namespace "$PORT_NS" >/dev/null 2>&1; then
  echo "ERROR: namespace not accessible: $PORT_NS" >&2
  echo "RESULT=BLOCKED_NAMESPACE_ACCESS" >"$OUT_DIR/result.txt"
  exit 10
fi

render_fixed() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: p2-portability-fixed-uid
  namespace: ${PORT_NS}
  labels:
    app: p2-portability-fixed-uid
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${APP_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
}

render_portable() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: p2-portability-portable-uid
  namespace: ${PORT_NS}
  labels:
    app: p2-portability-portable-uid
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${APP_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
EOF
}

render_fixed >"$OUT_DIR/fixed-uid-pod.yaml"
render_portable >"$OUT_DIR/portable-uid-pod.yaml"

sha256sum   "$OUT_DIR/fixed-uid-pod.yaml"   "$OUT_DIR/portable-uid-pod.yaml"   >"$OUT_DIR/MANIFEST_SHA256SUMS.txt"

set +e
oc create --dry-run=server -f "$OUT_DIR/fixed-uid-pod.yaml" -o yaml   >"$OUT_DIR/t1-fixed-uid.stdout.yaml"   2>"$OUT_DIR/t1-fixed-uid.stderr.txt"
FIXED_RC=$?

oc create --dry-run=server -f "$OUT_DIR/portable-uid-pod.yaml" -o yaml   >"$OUT_DIR/t2-portable-uid.stdout.yaml"   2>"$OUT_DIR/t2-portable-uid.stderr.txt"
PORTABLE_RC=$?
set -e 2>/dev/null || true

{
  echo "SOURCE_SHA=$SOURCE_SHA"
  echo "PORT_NS=$PORT_NS"
  echo "APP_IMAGE_DIGEST=${APP_IMAGE##*@}"
  echo "FIXED_UID_ADMISSION_RC=$FIXED_RC"
  echo "PORTABLE_UID_ADMISSION_RC=$PORTABLE_RC"

  if [ "$FIXED_RC" -eq 0 ]; then
    echo "FIXED_UID_ADMISSION=PASS"
  else
    echo "FIXED_UID_ADMISSION=NOT_ACCEPTED"
    echo "FIXED_UID_FAILURE_CLASS=INSPECT_RAW_ERROR_NOT_ASSUMED_SCC"
  fi

  if [ "$PORTABLE_RC" -eq 0 ]; then
    echo "PORTABLE_UID_ADMISSION=PASS"
    echo "RESULT=ADMISSION_PRECHECK_PASS"
  else
    echo "PORTABLE_UID_ADMISSION=REJECTED"
    echo "RESULT=ADMISSION_PRECHECK_FAIL"
  fi

  echo "CLUSTER_MUTATION=NONE_DRY_RUN_SERVER"
  echo "RUNTIME=NOT_RUN"
  echo "PG03=PARTIAL_ONLY"
} | tee "$OUT_DIR/result.txt"

echo "EVIDENCE_DIR=$OUT_DIR"

if [ "$PORTABLE_RC" -ne 0 ]; then
  exit 20
fi

exit 0
