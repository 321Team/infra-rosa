#!/usr/bin/env bash
# infra-rosa#5 — 권한 목록 저장 (첫 설정 순서 v3 ⑩-b, R2)
#
# bootstrap 창 안(임시 cluster-admin 이 살아 있을 때)에서만 실행한다. 읽기 전용, 쓰기 없음.
# 저장: Group 전체, ClusterRoleBinding 전체, 3개 namespace RoleBinding, 참조 ClusterRole/Role.
# 요약: 대상 사용자(기본 hayeoung)에게 권한이 닿는 모든 binding 경로
#       = subject 가 User <U> 이거나, <U> 가 속한 Group 이거나, system:authenticated(:oauth) 인 것.
# 비밀 없음(Secret 은 조회하지 않음). 출력 디렉터리는 umask 077.
set -Eeuo pipefail
U="${U:-hayeoung}"
NAMESPACES="${NAMESPACES:-fds-app monitoring-api ci-cd}"
OUT="${1:?usage: collect-access-inventory.sh <out-dir>}"
umask 077
mkdir -p "$OUT"

oc whoami --show-server >"$OUT/server.txt"
oc get groups -o json >"$OUT/groups.json"
oc get clusterrolebindings -o json >"$OUT/clusterrolebindings.json"
for ns in $NAMESPACES; do
  oc get rolebindings -n "$ns" -o json >"$OUT/rolebindings-$ns.json"
done

# U 가 속한 그룹 + 인증 사용자 기본 그룹
jq -r --arg u "$U" '[.items[] | select((.users // []) | index($u)) | .metadata.name]
  + ["system:authenticated", "system:authenticated:oauth"] | .[]' \
  "$OUT/groups.json" | sort -u >"$OUT/effective-groups-$U.txt"

match='def hit($u; $g): (.subjects // [])
  | any(.[]; (.kind == "User" and .name == $u) or (.kind == "Group" and (.name as $n | $g | index($n))));'

groups_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$OUT/effective-groups-$U.txt")

# 열: scope(cluster | <namespace>) / binding 이름 / roleRef kind / roleRef name / subjects
row='"\(.metadata.name)\t\(.roleRef.kind)\t\(.roleRef.name)\t\([.subjects[] | "\(.kind):\(.name)"] | join(","))"'
{
  echo "# access paths for $U  (server: $(cat "$OUT/server.txt"))"
  printf '# scope\tbinding\troleRef.kind\troleRef.name\tsubjects\n'
  jq -r --arg u "$U" --argjson g "$groups_json" "$match"'
    .items[] | select(hit($u; $g)) | "cluster\t" + '"$row" \
    "$OUT/clusterrolebindings.json"
  for ns in $NAMESPACES; do
    jq -r --arg u "$U" --argjson g "$groups_json" --arg ns "$ns" "$match"'
      .items[] | select(hit($u; $g)) | $ns + "\t" + '"$row" \
      "$OUT/rolebindings-$ns.json"
  done
} >"$OUT/access-paths-$U.tsv"

# 참조된 ClusterRole / Role 규칙 저장(경로 검토용). 조회 실패·참조 부재·미지원 kind 는 실패(nonzero)로 끝낸다.
# Role 은 namespace 와 함께 저장한다(같은 이름이 다른 namespace 에 있어도 섞이지 않게).
grep -v '^#' "$OUT/access-paths-$U.tsv" | cut -f1,3,4 | sort -u >"$OUT/role-refs.tsv"
while IFS=$'\t' read -r scope kind name; do
  case "$kind" in
    ClusterRole)
      oc get clusterrole "$name" -o json >"$OUT/clusterrole-$name.json" ;;
    Role)
      if [[ "$scope" == cluster ]]; then
        echo "STOP: ClusterRoleBinding 이 Role/$name 을 참조(비정상)" >&2; exit 3
      fi
      oc get role "$name" -n "$scope" -o json >"$OUT/role-$scope-$name.json" ;;
    *)
      echo "STOP: 미지원 roleRef.kind=$kind ($scope/$name)" >&2; exit 3 ;;
  esac
done <"$OUT/role-refs.tsv"

( cd "$OUT" && sha256sum -- *.json *.txt *.tsv >SHA256SUMS )
echo "saved: $OUT ($(wc -l <"$OUT/access-paths-$U.tsv") lines in access-paths)"
