#!/usr/bin/env bash
# infra-rosa#5 — ⑩-b 권한 경로 분류(오프라인, 읽기 전용). bootstrap(steps.sh)과 회수 뒤(post-revoke-check.sh)에서 같은 규칙으로 쓴다.
#
# 쓰는 법: classify-access-paths.sh <inventory-dir> <user> <policy-file> <out-tsv>
#   inventory-dir : collect-access-inventory.sh 출력(access-paths-<user>.tsv, clusterrole-*.json)
#   policy-file   : 승인된 플랫폼 기본 binding 목록(리뷰를 거친 파일). 없으면 기본 binding 은 PENDING_POLICY.
#
# 분류(PR#40 리뷰 5530426592 R1 — 이름만 보지 않고 범위·binding·roleRef·주체·실제 규칙까지 대조)
#   APPROVED         승인 namespace(정확히 3개)의 <user>-admin = ClusterRole/admin, 주체 정확히 User:<user>
#                    + fds-app 의 <user>-monitoring-edit = ClusterRole/monitoring-edit(⑮ 회차 뒤에만 존재)
#   REVOKE_TARGET    cluster 범위 ClusterRole/cluster-admin, 주체 정확히 Group:cluster-admins (⑪에서 회수)
#   PLATFORM_DEFAULT 주체가 system:authenticated(:oauth) 그룹뿐이고, policy 에 같은 scope·binding·roleRef·주체 행이 있으며
#                    수집된 ClusterRole 의 rules+aggregationRule sha256 이 policy 값과 같을 때만
#   PENDING_POLICY   위 기본 binding 형태인데 policy 파일이 아직 없음(AFTER-CREATE 승인 대기)
#   UNEXPECTED       그 밖의 전부(policy 에 없는 기본 binding, 같은 이름인데 규칙이 바뀜, ClusterRole 파일 누락, 형식 오류 포함)
#
# 종료코드: 0 = 전부 승인 범위 / 3 = UNEXPECTED 없음 + PENDING_POLICY 있음 / 1 = UNEXPECTED 또는 입력 누락·형식 오류
# policy 형식(TSV, # 주석): scope  binding  roleRef.kind  roleRef.name  subjects  rules_sha256
# 주의: 수집한 값으로 policy 를 자동 생성·승인하지 않는다. policy 는 PR 리뷰를 거쳐 저장소에 들어간다.
set -Eeuo pipefail
INV="${1:?inventory-dir}"; U="${2:?user}"; POLICY="${3:?policy-file}"; OUT="${4:?out-tsv}"
APPROVED_NAMESPACES="${APPROVED_NAMESPACES:-fds-app monitoring-api ci-cd}"
paths="$INV/access-paths-$U.tsv"

[[ -s "$paths" ]] || { echo "STOP: $paths 없음 또는 빈 파일(수집 누락)" >&2; exit 1; }
[[ $(grep -vc '^#' "$paths" || true) -gt 0 ]] || { echo "STOP: 권한 경로 0건(수집 누락 의심)" >&2; exit 1; }

have_policy=0
if [[ -f "$POLICY" ]]; then
  have_policy=1
  # policy 형식 검증: 주석 아닌 행은 정확히 6열, 마지막 열은 64자리 hex
  if awk -F'\t' '!/^#/ && NF > 0 && (NF != 6 || $6 !~ /^[0-9a-f]{64}$/) { bad = 1 } END { exit bad }' "$POLICY"; then :; else
    echo "STOP: policy 형식 오류($POLICY)" >&2; exit 1
  fi
fi

rules_sha() { jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' "$1" | sha256sum | cut -d' ' -f1; }
auth_re='^Group:system:authenticated(:oauth)?(,Group:system:authenticated(:oauth)?)*$'

pending=0; bad=0
: >"$OUT"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  IFS=$'\t' read -r scope binding kind name subjects extra <<<"$line"
  c=UNEXPECTED; why=""
  if [[ -z "$subjects" || -n "${extra:-}" ]]; then
    why="형식 오류(5열 아님)"
  elif [[ " $APPROVED_NAMESPACES " == *" $scope "* && "$binding" == "$U-admin" && "$kind" == ClusterRole \
          && "$name" == admin && "$subjects" == "User:$U" ]]; then
    c=APPROVED
  elif [[ "$scope" == fds-app && "$binding" == "$U-monitoring-edit" && "$kind" == ClusterRole \
          && "$name" == monitoring-edit && "$subjects" == "User:$U" ]]; then
    c=APPROVED
  elif [[ "$scope" == cluster && "$kind" == ClusterRole && "$name" == cluster-admin && "$subjects" == "Group:cluster-admins" ]]; then
    c=REVOKE_TARGET
  elif [[ "$kind" == ClusterRole && "$subjects" =~ $auth_re ]]; then
    if [[ $have_policy == 0 ]]; then
      c=PENDING_POLICY; why="policy 없음(AFTER-CREATE 승인 대기)"
    else
      want=$(awk -F'\t' -v s="$scope" -v b="$binding" -v k="$kind" -v n="$name" -v j="$subjects" \
               '!/^#/ && $1 == s && $2 == b && $3 == k && $4 == n && $5 == j { print $6 }' "$POLICY")
      rf="$INV/clusterrole-$name.json"
      if [[ -z "$want" ]]; then
        why="policy 에 없는 기본 binding"
      elif [[ ! -s "$rf" ]]; then
        why="ClusterRole 수집 파일 없음"
      elif [[ "$(rules_sha "$rf")" != "$want" ]]; then
        why="ClusterRole 규칙이 승인값과 다름"
      else
        c=PLATFORM_DEFAULT
      fi
    fi
  fi
  [[ $c == UNEXPECTED ]] && bad=$((bad + 1))
  [[ $c == PENDING_POLICY ]] && pending=$((pending + 1))
  printf '%s\t%s\t%s\n' "$c" "$line" "$why" >>"$OUT"
done <"$paths"

if (( bad > 0 )); then echo "CLASSIFY: UNEXPECTED=$bad PENDING_POLICY=$pending" >&2; exit 1; fi
if (( pending > 0 )); then echo "CLASSIFY: PENDING_POLICY=$pending (policy 승인 대기)" >&2; exit 3; fi
echo "CLASSIFY: OK" >&2
