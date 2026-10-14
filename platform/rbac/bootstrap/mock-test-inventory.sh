#!/usr/bin/env bash
# collect-access-inventory.sh MOCK 시험 — 가짜 oc 가 합성 RBAC JSON 을 돌려준다(클러스터 호출 없음). jq 필요.
# A 기본: hayeoung 에게 닿는 경로 7개(숨은 직접 binding·namespace cluster-admin·두 namespace 의 같은 이름 Role 포함)를 잡고
#         무관한 2개는 빼며, Role 규칙을 namespace 별 파일로 따로 저장해야 한다.
# B Role 참조 부재(조회 실패) → nonzero.  C 미지원 roleRef.kind → nonzero.  D ClusterRoleBinding 이 Role 참조 → nonzero.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
crb_extra=""
[[ "${MOCK_CASE:-A}" == D ]] && crb_extra=',{"metadata":{"name":"bad-crb"},"roleRef":{"kind":"Role","name":"x"},"subjects":[{"kind":"User","name":"hayeoung"}]}'
rb_kind=Role
[[ "${MOCK_CASE:-A}" == C ]] && rb_kind=WeirdKind
case "$*" in
  "whoami --show-server") echo https://api.mock:443 ;;
  "get groups -o json") echo '{"items":[{"metadata":{"name":"cluster-admins"},"users":["hayeoung"]},{"metadata":{"name":"other"},"users":["gwonuk"]}]}' ;;
  "get clusterrolebindings -o json") echo '{"items":[
    {"metadata":{"name":"cluster-admins"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"Group","name":"cluster-admins"}]},
    {"metadata":{"name":"self-provisioners"},"roleRef":{"kind":"ClusterRole","name":"self-provisioner"},"subjects":[{"kind":"Group","name":"system:authenticated:oauth"}]},
    {"metadata":{"name":"hidden-direct"},"roleRef":{"kind":"ClusterRole","name":"sudoer"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"unrelated"},"roleRef":{"kind":"ClusterRole","name":"view"},"subjects":[{"kind":"User","name":"gwonuk"}]}'"$crb_extra"']}' ;;
  "get rolebindings -n fds-app -o json") echo '{"items":[
    {"metadata":{"name":"hayeoung-admin"},"roleRef":{"kind":"ClusterRole","name":"admin"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"ns-cluster-admin"},"roleRef":{"kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"custom-a"},"roleRef":{"kind":"'"$rb_kind"'","name":"custom-admin"},"subjects":[{"kind":"User","name":"hayeoung"}]},
    {"metadata":{"name":"system:image-pullers"},"roleRef":{"kind":"ClusterRole","name":"system:image-puller"},"subjects":[{"kind":"Group","name":"system:serviceaccounts:fds-app"}]}]}' ;;
  "get rolebindings -n ci-cd -o json") echo '{"items":[
    {"metadata":{"name":"custom-c"},"roleRef":{"kind":"Role","name":"custom-admin"},"subjects":[{"kind":"User","name":"hayeoung"}]}]}' ;;
  "get rolebindings -n "*) echo '{"items":[]}' ;;
  "get clusterrole "*) echo '{"kind":"ClusterRole"}' ;;
  "get role custom-admin -n fds-app -o json")
    [[ "${MOCK_CASE:-A}" == B ]] && { echo 'Error from server (NotFound): roles "custom-admin" not found' >&2; exit 1; }
    echo '{"kind":"Role","metadata":{"namespace":"fds-app"},"rules":[{"verbs":["get"]}]}' ;;
  "get role custom-admin -n ci-cd -o json")
    echo '{"kind":"Role","metadata":{"namespace":"ci-cd"},"rules":[{"verbs":["*"]}]}' ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/oc"

fail=0
# A
PATH="$T/bin:$PATH" MOCK_CASE=A bash "$HERE/collect-access-inventory.sh" "$T/A" >/dev/null || { echo "A FAIL: collector rc=$?"; fail=1; }
cat "$T/A/access-paths-hayeoung.tsv" 2>/dev/null
got=$(grep -v '^#' "$T/A/access-paths-hayeoung.tsv" 2>/dev/null | cut -f2 | sort | tr '\n' ' ')
want="cluster-admins custom-a custom-c hayeoung-admin hidden-direct ns-cluster-admin self-provisioners "
ra=$(jq -r .metadata.namespace "$T/A/role-fds-app-custom-admin.json" 2>/dev/null)
rc_=$(jq -r .metadata.namespace "$T/A/role-ci-cd-custom-admin.json" 2>/dev/null)
perm=$(stat -c '%a' "$T/A" 2>/dev/null)
echo "A got:  $got"; echo "A want: $want"
echo "A role files: fds-app=$ra ci-cd=$rc_ (want fds-app / ci-cd)  out dir perm: $perm (want 700)"
[[ "$got" == "$want" && "$ra" == fds-app && "$rc_" == ci-cd && "$perm" == 700 ]] && echo "A PASS" || { echo "A FAIL"; fail=1; }
# B, C, D: 반드시 nonzero
for c in B C D; do
  PATH="$T/bin:$PATH" MOCK_CASE=$c bash "$HERE/collect-access-inventory.sh" "$T/$c" >/dev/null 2>"$T/$c.err"; r=$?
  if [[ $r -ne 0 ]]; then echo "$c PASS (rc=$r: $(tail -n1 "$T/$c.err"))"; else echo "$c FAIL (rc=0)"; fail=1; fi
done
[[ $fail == 0 ]] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
