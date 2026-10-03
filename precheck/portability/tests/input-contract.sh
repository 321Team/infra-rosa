#!/usr/bin/env bash
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/rosa-contract.XXXXXX")"
[[ "$TASK_TMP" == /*/rosa-contract.* ]] || exit 2
trap 'rm -rf -- "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/rosa-test/precheck/portability" "$TASK_TMP/mockbin"
cp "$SOURCE_ROOT/precheck/portability/uid-scc-admission.sh" "$TASK_TMP/rosa-test/precheck/portability/"
printf 'evidence-local/\n' > "$TASK_TMP/rosa-test/.gitignore"
git -C "$TASK_TMP/rosa-test" init -q
git -C "$TASK_TMP/rosa-test" add .
git -C "$TASK_TMP/rosa-test" -c user.name=ContractFixture -c user.email=fixture@example.invalid commit -qm fixture
cat > "$TASK_TMP/mockbin/oc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLLOG"
case "$1" in
  version) echo 'MOCK oc/OpenShift';;
  get) echo 'namespace/mock';;
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
: > "$CALLLOG"
env PORT_NS=j1-fds-app APP_IMAGE="$IMAGE" OUT_DIR="$FIXTURE/evidence-local/mock" bash "$SCRIPT" > "$ROOT/valid.stdout"
[[ "$(grep -c '^create ' "$CALLLOG")" == 2 ]]
[[ "$(grep '^create ' "$CALLLOG" | grep -c -- '--dry-run=server')" == 2 ]]
! grep -Eq '^(apply|delete|patch|replace|edit|login) ' "$CALLLOG"
grep -q '^RUNTIME=NOT_RUN$' "$FIXTURE/evidence-local/mock/result.txt"
grep -q '^PG03=PARTIAL_ONLY$' "$FIXTURE/evidence-local/mock/result.txt"
echo 'PASS: 9 fail-closed cases before oc; 2 server-dry-run creates; no cluster mutation; PG03 not promoted'
