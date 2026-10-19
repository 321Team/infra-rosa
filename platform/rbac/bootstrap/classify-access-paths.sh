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
# 승인 namespace 는 고정값이다(리뷰 5530751510 R1). 환경변수로 넓힐 수 없다 — 범위를 바꾸려면 이 파일을 PR 리뷰로 바꾼다.
readonly APPROVED_NAMESPACES="fds-app monitoring-api ci-cd"
paths="$INV/access-paths-$U.tsv"

[[ -s "$paths" ]] || { echo "STOP: $paths 없음 또는 빈 파일(수집 누락)" >&2; exit 1; }
# 주석·빈 줄을 뺀 '유효 5열 행'이 1개 이상이어야 한다(줄바꿈만 있는 파일 = 수집 누락)
valid=$(awk -F'\t' '!/^#/ && NF == 5 && $1 != "" && $5 != "" { n++ } END { print n + 0 }' "$paths")
[[ "$valid" =~ ^[0-9]+$ && "$valid" -gt 0 ]] || { echo "STOP: 유효 권한 경로 0건(수집 누락 의심)" >&2; exit 1; }

have_policy=0
if [[ -f "$POLICY" ]]; then
  have_policy=1
  # policy 형식 검증: 주석 아닌 행은 정확히 6열, 마지막 열은 64자리 hex
  if awk -F'\t' '!/^#/ && NF > 0 && (NF != 6 || $6 !~ /^[0-9a-f]{64}$/) { bad = 1 } END { exit bad }' "$POLICY"; then :; else
    echo "STOP: policy 형식 오류($POLICY)" >&2; exit 1
  fi
fi

# ClusterRole 규칙 정규화 해시. JSON 구조·jq·해시 중 하나라도 실패하면 rc1(빈 입력 해시로 대신하지 않음, 리뷰 R1).
rules_sha() {
  local norm out
  jq -e 'type == "object" and .kind == "ClusterRole"' "$1" >/dev/null 2>&1 || return 1
  norm=$(jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' "$1") || return 1
  [[ -n "$norm" ]] || return 1
  out=$(printf '%s\n' "$norm" | sha256sum) || return 1
  out=${out%% *}
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}
auth_re='^Group:system:authenticated(:oauth)?(,Group:system:authenticated(:oauth)?)*$'

# 키트 manifest(human-bindings.yaml)의 fds-clusterversion-reader 규칙을 같은 정규화로 해시한 기대값.
# manifest 를 바꾸면 이 JSON 도 같은 PR 에서 같이 바꾼다.
CV_READER_JSON='{"kind":"ClusterRole","rules":[{"apiGroups":["config.openshift.io"],"resources":["clusterversions"],"resourceNames":["version"],"verbs":["get"]}]}'
CV_READER_SHA=$(printf '%s\n' "$CV_READER_JSON" | jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' | sha256sum) \
  || { echo "STOP: clusterversion-reader 기대 해시 계산 실패" >&2; exit 1; }
CV_READER_SHA=${CV_READER_SHA%% *}
[[ "$CV_READER_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "STOP: clusterversion-reader 기대 해시 형식 오류" >&2; exit 1; }

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
  elif [[ "$scope" == cluster && "$binding" == "$U-clusterversion-reader" && "$kind" == ClusterRole \
          && "$name" == fds-clusterversion-reader && "$subjects" == "User:$U" ]]; then
    # 키트가 만드는 cluster 범위 최소 권한(clusterversion/version get, #5 6258874244).
    # 이름만으로 승인하지 않는다 — 수집된 규칙이 manifest 와 정확히 같을 때만 APPROVED(넓어지면 STOP).
    rf="$INV/clusterrole-$name.json"
    if [[ ! -s "$rf" ]]; then
      why="ClusterRole 수집 파일 없음"
    else
      got=$(rules_sha "$rf") || { echo "STOP: ClusterRole JSON·정규화·해시 실패($rf)" >&2; exit 1; }
      if [[ "$got" == "$CV_READER_SHA" ]]; then c=APPROVED; else why="fds-clusterversion-reader 규칙이 manifest 와 다름"; fi
    fi
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
      else
        # 해시를 계산하지 못하면 비교하지 않고 즉시 STOP(빈 값끼리 같다고 보지 않음)
        got=$(rules_sha "$rf") || { echo "STOP: ClusterRole JSON·정규화·해시 실패($rf)" >&2; exit 1; }
        if [[ "$got" != "$want" ]]; then why="ClusterRole 규칙이 승인값과 다름"; else c=PLATFORM_DEFAULT; fi
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
