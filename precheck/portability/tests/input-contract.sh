#!/usr/bin/env bash
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/rosa-contract.XXXXXX")"
[[ "$TASK_TMP" == /*/rosa-contract.* ]] || exit 2
trap 'rm -rf -- "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/rosa-test/precheck/portability" "$TASK_TMP/mockbin"
cp "$SOURCE_ROOT/precheck/portability/uid-scc-admission.sh" "$TASK_TMP/rosa-test/precheck/portability/"
printf 'evidence-local/\nignored-copy.sh\n' > "$TASK_TMP/rosa-test/.gitignore"
git -C "$TASK_TMP/rosa-test" init -q
git -C "$TASK_TMP/rosa-test" add .
git -C "$TASK_TMP/rosa-test" -c user.name=ContractFixture -c user.email=fixture@example.invalid commit -qm fixture
cat > "$TASK_TMP/mockbin/oc" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == --context=mock && "$2" == --server=https://api.mock.invalid:6443 && "$3" == --insecure-skip-tls-verify=false ]] || exit 97
shift 3
printf '%s\n' "$*" >> "$CALLLOG"
case "$1" in
  whoami) echo mock-user;;
  version) echo 'MOCK oc/OpenShift';;
  get)
    if [[ "${FAIL_IO:-0}" == 1 ]]; then mkdir -p "$OUT_DIR/t1-fixed-uid.stdout.yaml"; fi
    echo 'namespace/mock';;
  create)
    [[ "$*" == *"--dry-run=server"* ]] || exit 99
    [[ "$*" == *fixed-uid-pod.yaml* ]] && { echo 'MOCK fixed UID rejected' >&2; exit 1; }
    echo 'MOCK portable admission response';;
  *) exit 98;;
esac
MOCK
chmod +x "$TASK_TMP/mockbin/oc"
ROOT="$TASK_TMP"
FIXTURE="$ROOT/rosa-test"
export PATH="$ROOT/mockbin:$PATH"
export OC_CONTEXT=mock EXPECTED_API_SERVER=https://api.mock.invalid:6443 PORT_ENV=SHARED_OCP_LAB
export CALLLOG="$ROOT/oc-calls.log"
DIGEST="$(printf 'a%.0s' {1..64})"
IMAGE="registry.invalid/fds/app@sha256:$DIGEST"
SCRIPT="$FIXTURE/precheck/portability/uid-scc-admission.sh"
expect_rc() {
  local want="$1"; shift
  : > "$CALLLOG"
  set +e
  "$@" > "$ROOT/last.stdout" 2> "$ROOT/last.stderr"
  local actual=$?
  set -e
  [[ "$actual" == "$want" ]] || { echo "FAIL expected=$want actual=$actual"; cat "$ROOT/last.stderr"; exit 1; }
  [[ ! -s "$CALLLOG" ]] || { echo 'FAIL oc called before rejected input'; exit 1; }
}
cd "$FIXTURE"
expect_rc 3 env PORT_NS=j1-fds-app APP_IMAGE=repo@sha256: bash "$SCRIPT"
expect_rc 3 env PORT_NS=j1-fds-app APP_IMAGE=repo@sha256:abc bash "$SCRIPT"
expect_rc 3 env PORT_NS=j1-fds-app APP_IMAGE="repo@sha256:${DIGEST/a/z}" bash "$SCRIPT"
expect_rc 3 env PORT_NS=j1-fds-app APP_IMAGE=$'repo\n@sha256:'"$DIGEST" bash "$SCRIPT"
expect_rc 6 env PORT_NS=$'j1-fds-app\nspec:' APP_IMAGE="$IMAGE" bash "$SCRIPT"
expect_rc 6 env PORT_NS=UpperCase APP_IMAGE="$IMAGE" bash "$SCRIPT"
expect_rc 6 env PORT_NS="$(printf 'a%.0s' {1..64})" APP_IMAGE="$IMAGE" bash "$SCRIPT"
cd "$ROOT"
expect_rc 7 env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" bash "$SCRIPT"
cd "$FIXTURE"
printf 'dirty\n' > dirty-input.txt
expect_rc 8 env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" bash "$SCRIPT"
rm dirty-input.txt
cp "$SCRIPT" "$FIXTURE/ignored-copy.sh"
expect_rc 9 env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" bash "$FIXTURE/ignored-copy.sh"
rm "$FIXTURE/ignored-copy.sh"
mkdir -p "$FIXTURE/evidence-local"
: > "$CALLLOG"
env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" OUT_DIR="$FIXTURE/evidence-local/mock" bash "$SCRIPT" > "$ROOT/valid.stdout"
[[ "$(grep -c '^create ' "$CALLLOG")" == 2 ]]
[[ "$(grep '^create ' "$CALLLOG" | grep -c -- '--dry-run=server')" == 2 ]]
! grep -Eq '^(apply|delete|patch|replace|edit|login) ' "$CALLLOG"
grep -q '^RUNTIME=NOT_RUN$' "$FIXTURE/evidence-local/mock/result.txt"
grep -q '^PG03=PARTIAL_ONLY$' "$FIXTURE/evidence-local/mock/result.txt"
echo 'PASS: 10 fail-closed cases before oc; 2 server-dry-run creates; no cluster mutation; PG03 not promoted'

# Existing directory refusal preserves all original bytes.
(cd "$FIXTURE/evidence-local/mock" && sha256sum -c SHA256SUMS && sha256sum -c SHA256SUMS.sha256) >/dev/null
expect_rc 5 env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" OUT_DIR="$FIXTURE/evidence-local/mock" bash "$SCRIPT"
(cd "$FIXTURE/evidence-local/mock" && sha256sum -c SHA256SUMS) >/dev/null
printf 'tampered\n' >> "$FIXTURE/evidence-local/mock/t2-portable-uid.stdout.yaml"
if (cd "$FIXTURE/evidence-local/mock" && sha256sum -c SHA256SUMS) >/dev/null 2>&1; then exit 1; fi
expect_rc 11 env OC_CONTEXT= PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" bash "$SCRIPT"
expect_rc 11 env EXPECTED_API_SERVER=https://user:password@bad PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" bash "$SCRIPT"
# Output file open failure must abort before PASS.
set +e
env FAIL_IO=1 PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" OUT_DIR="$FIXTURE/evidence-local/io-fail" bash "$SCRIPT" > "$ROOT/io.stdout" 2> "$ROOT/io.stderr"
rc=$?
set -e
[[ "$rc" != 0 ]]
! grep -q 'RESULT=ADMISSION_PRECHECK_PASS' "$ROOT/io.stdout"
# Fail checksum generation after admission; no success emitted to stdout.
cat > "$ROOT/mockbin/sha256sum" <<'MOCKHASH'
#!/usr/bin/env bash
exit 88
MOCKHASH
chmod +x "$ROOT/mockbin/sha256sum"
set +e
env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" OUT_DIR="$FIXTURE/evidence-local/hash-fail" bash "$SCRIPT" > "$ROOT/fail.stdout" 2> "$ROOT/fail.stderr"
rc=$?
set -e
[[ "$rc" != 0 ]]
! grep -q 'RESULT=ADMISSION_PRECHECK_PASS' "$ROOT/fail.stdout"
echo 'PASS: context pin, existing-directory preservation, raw tamper detection, invalid target rejection, file-open/hash failure closed'
