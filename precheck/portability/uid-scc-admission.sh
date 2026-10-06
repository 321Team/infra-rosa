#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  PORT_NS=<approved-shared-ocp-namespace> \
  OC_CONTEXT=<approved-context> EXPECTED_API_SERVER=https://<approved-api> \
  PORT_ENV=SHARED_OCP_LAB \
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

OC_CONTEXT="${OC_CONTEXT:-}"
EXPECTED_API_SERVER="${EXPECTED_API_SERVER:-}"
PORT_ENV="${PORT_ENV:-}"
if [[ -z "$OC_CONTEXT" || ! "$EXPECTED_API_SERVER" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || [[ "$PORT_ENV" != SHARED_OCP_LAB && "$PORT_ENV" != ROSA ]]; then
  echo 'ERROR: OC_CONTEXT, HTTPS EXPECTED_API_SERVER and PORT_ENV=SHARED_OCP_LAB|ROSA required.' >&2
  exit 11
fi
for cmd in oc sha256sum date git mktemp; do
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

# Pin every authenticated request; never inherit mutable current-context/server.
OC=(oc --context="$OC_CONTEXT" --server="$EXPECTED_API_SERVER" --insecure-skip-tls-verify=false)
if [ -z "$OUT_DIR" ]; then
  mkdir -p ./evidence-local/p2-portability-w0
  OUT_DIR="$(mktemp -d ./evidence-local/p2-portability-w0/capture.XXXXXX)" || exit 5
else
  # Atomic creation; any existing path (including symlink) is refused.
  mkdir -m 700 -- "$OUT_DIR" || exit 5
fi
chmod 700 -- "$OUT_DIR" || exit 5
OUT_DIR="$(cd -- "$OUT_DIR" && pwd -P)"
trap 'rc=$?; echo "CAPTURE_INCOMPLETE RC=$rc; preserve $OUT_DIR" >&2; exit "$rc"' ERR
NS_UID="$("${OC[@]}" get namespace "$PORT_NS" -o jsonpath='{.metadata.uid}')" || exit 10
[[ -n "$NS_UID" ]] || exit 10
{
  echo "ENV=$PORT_ENV"
  echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "KST=$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
  echo "SOURCE_SHA=$SOURCE_SHA"
  echo "OC_CONTEXT=$OC_CONTEXT"
  echo "API_SERVER=$EXPECTED_API_SERVER"
  echo "PORT_NS=$PORT_NS"
  echo "NAMESPACE_UID=$NS_UID"
  echo "APP_IMAGE=$APP_IMAGE"
  echo "=== EXECUTION IDENTITY ==="
  "${OC[@]}" whoami
  echo "=== CLIENT/SERVER ==="
  "${OC[@]}" version
  echo "=== UID/GROUP RANGES ==="
  "${OC[@]}" get namespace "$PORT_NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}{"\n"}{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}{"\n"}'
} >"$OUT_DIR/context.txt" 2>&1

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

(cd "$OUT_DIR" && sha256sum fixed-uid-pod.yaml portable-uid-pod.yaml > MANIFEST_SHA256SUMS.txt)

exec 3>"$OUT_DIR/t1-fixed-uid.stdout.yaml" 4>"$OUT_DIR/t1-fixed-uid.stderr.txt"
FIXED_RC=0
"${OC[@]}" create --dry-run=server -f "$OUT_DIR/fixed-uid-pod.yaml" -o yaml   >&3 2>&4 || FIXED_RC=$?

exec 3>&- 4>&-
exec 3>"$OUT_DIR/t2-portable-uid.stdout.yaml" 4>"$OUT_DIR/t2-portable-uid.stderr.txt"
PORTABLE_RC=0
"${OC[@]}" create --dry-run=server -f "$OUT_DIR/portable-uid-pod.yaml" -o yaml   >&3 2>&4 || PORTABLE_RC=$?
exec 3>&- 4>&-
# Redirection/IO failures must not become a successful capture.
for f in t1-fixed-uid.stdout.yaml t1-fixed-uid.stderr.txt t2-portable-uid.stdout.yaml t2-portable-uid.stderr.txt; do
  [[ -f "$OUT_DIR/$f" ]] || exit 12
done
FINAL_NS_UID="$("${OC[@]}" get namespace "$PORT_NS" -o jsonpath='{.metadata.uid}')" || exit 10
[[ "$NS_UID" == "$FINAL_NS_UID" ]] || { echo "STOP: namespace identity changed" >&2; exit 13; }

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
} > "$OUT_DIR/result.txt"
(cd "$OUT_DIR" && sha256sum context.txt fixed-uid-pod.yaml portable-uid-pod.yaml MANIFEST_SHA256SUMS.txt t1-fixed-uid.stdout.yaml t1-fixed-uid.stderr.txt t2-portable-uid.stdout.yaml t2-portable-uid.stderr.txt result.txt > SHA256SUMS && sha256sum SHA256SUMS > SHA256SUMS.sha256 && sha256sum -c SHA256SUMS >/dev/null)
cat "$OUT_DIR/result.txt"

echo "EVIDENCE_DIR=$OUT_DIR"

if [ "$PORTABLE_RC" -ne 0 ]; then
  exit 20
fi

exit 0
