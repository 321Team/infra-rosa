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

{
  echo "# access paths for $U  (server: $(cat "$OUT/server.txt"))"
  echo "## ClusterRoleBinding"
  jq -r --arg u "$U" --argjson g "$groups_json" "$match"'
    .items[] | select(hit($u; $g))
    | "\(.metadata.name)\t\(.roleRef.kind)/\(.roleRef.name)\t\([.subjects[] | "\(.kind):\(.name)"] | join(","))"' \
    "$OUT/clusterrolebindings.json"
  for ns in $NAMESPACES; do
    echo "## RoleBinding $ns"
    jq -r --arg u "$U" --argjson g "$groups_json" "$match"'
      .items[] | select(hit($u; $g))
      | "\(.metadata.name)\t\(.roleRef.kind)/\(.roleRef.name)\t\([.subjects[] | "\(.kind):\(.name)"] | join(","))"' \
      "$OUT/rolebindings-$ns.json"
  done
} >"$OUT/access-paths-$U.tsv"

# 참조된 ClusterRole 규칙 저장(경로 검토용)
cut -f2 "$OUT/access-paths-$U.tsv" | grep '^ClusterRole/' | cut -d/ -f2 | sort -u | while read -r r; do
  oc get clusterrole "$r" -o json >"$OUT/clusterrole-$r.json"
done

( cd "$OUT" && sha256sum -- *.json *.txt *.tsv >SHA256SUMS )
echo "saved: $OUT ($(wc -l <"$OUT/access-paths-$U.tsv") lines in access-paths)"
