#!/usr/bin/env bash
# collect-access-inventory.sh MOCK 시험 — 가짜 oc 가 합성 RBAC JSON 을 돌려준다(클러스터 호출 없음).
# 기대: hayeoung 에게 닿는 경로 5개를 모두 잡고(숨은 직접 binding·namespace cluster-admin 포함), 무관한 2개는 빼야 한다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "whoami --show-server") echo https://api.mock:443 ;;
  "get groups -o json") echo '{"items":[{"metadata":{"name":"cluster-admins"},"users":["hayeoung"]},{"metadata":{"name":"other"},"users":["gwonuk"]}]}' ;;
  "get clusterrolebindings -o json") echo '{"items":[
    {"metadata":{"name":"cluster-admins"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"Group","name":"cluster-admins"}]},
    {"metadata":{"name":"self-provisioners"},"roleRef":{"kind":"ClusterRole","name":"self-provisioner"},"subjects":[{"kind":"Group","name":"system:authenticated:oauth"}]},
    {"metadata":{"name":"hidden-direct"},"roleRef":{"kind":"ClusterRole","name":"sudoer"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"unrelated"},"roleRef":{"kind":"ClusterRole","name":"view"},"subjects":[{"kind":"User","name":"gwonuk"}]}]}' ;;
  "get rolebindings -n fds-app -o json") echo '{"items":[
    {"metadata":{"name":"hayeoung-admin"},"roleRef":{"kind":"ClusterRole","name":"admin"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"ns-cluster-admin"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"system:image-pullers"},"roleRef":{"kind":"ClusterRole","name":"system:image-puller"},"subjects":[{"kind":"Group","name":"system:serviceaccounts:fds-app"}]}]}' ;;
  "get rolebindings -n "*) echo '{"items":[]}' ;;
  "get clusterrole "*) echo '{"kind":"ClusterRole"}' ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/oc"
PATH="$T/bin:$PATH" bash "$HERE/collect-access-inventory.sh" "$T/out" || { echo "FAIL: collector rc=$?"; exit 1; }
cat "$T/out/access-paths-hayeoung.tsv"
got=$(grep -v '^#' "$T/out/access-paths-hayeoung.tsv" | cut -f1 | sort | tr '\n' ' ')
want="cluster-admins hayeoung-admin hidden-direct ns-cluster-admin self-provisioners "
perm=$(stat -c '%a' "$T/out")
echo "got:  $got"; echo "want: $want"; echo "out dir perm: $perm (want 700)"
[[ "$got" == "$want" && "$perm" == 700 ]] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
