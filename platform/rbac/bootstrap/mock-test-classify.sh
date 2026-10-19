#!/usr/bin/env bash
# classify-access-paths.sh 단위 시험(오프라인, jq 필요). 하나라도 FAIL 이면 rc1.
# 리뷰 5530751510 R1 의 반례 3건 + 기존 조건을 직접 확인하고, 'b' 대조는 수정 전 코드가 실제로 통과시켰음을 보여 준다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
C="$HERE/classify-access-paths.sh"

norm() { jq -cS '{rules: (.rules // []), aggregationRule: (.aggregationRule // null)}' | sha256sum | cut -d' ' -f1; }
SP_SHA=$(printf '{"kind":"ClusterRole"}' | norm)
EMPTY_SHA=$(printf '' | sha256sum | cut -d' ' -f1)   # 빈 입력의 해시 — jq 실패 시 수정 전 코드가 만들던 값

# 수정 전(1272def) 분류기 재현: 환경변수 namespace, 주석만 아니면 행으로 셈, 실패를 무시하는 해시
cp "$C" "$T/old.sh"
perl -0pi -e 's/readonly APPROVED_NAMESPACES="fds-app monitoring-api ci-cd"/APPROVED_NAMESPACES="\${APPROVED_NAMESPACES:-fds-app monitoring-api ci-cd}"/;
  s/valid=\$\(awk [^\n]*\n\[\[ "\$valid"[^\n]*\n/[[ \$(grep -vc \x27^#\x27 "\$paths" || true) -gt 0 ]] || { echo "STOP" >&2; exit 1; }\n/;
  s/rules_sha\(\) \{\n.*?\n\}\n/rules_sha() { jq -cS \x27{rules: (.rules \/\/ []), aggregationRule: (.aggregationRule \/\/ null)}\x27 "\$1" | sha256sum | cut -d\x27 \x27 -f1; }\n/s;
  s/got=\$\(rules_sha "\$rf"\) \|\| \{[^\n]*\}/got=\$(rules_sha "\$rf") || true/' "$T/old.sh"   # 수정 전: 계산 실패를 무시
fail=0
cmp -s "$C" "$T/old.sh" && { echo "FAIL: 대조 사본이 원본과 같음(치환 실패)"; fail=1; }

mk() { # dir — 정상 인벤토리
  local d=$1; mkdir -p "$d"
  {
    printf '# access paths for hayeoung\n# scope\tbinding\troleRef.kind\troleRef.name\tsubjects\n'
    printf 'cluster\tcluster-admins\tClusterRole\tcluster-admin\tGroup:cluster-admins\n'
    printf 'cluster\tself-provisioners\tClusterRole\tself-provisioner\tGroup:system:authenticated:oauth\n'
    for ns in fds-app monitoring-api ci-cd; do printf '%s\thayeoung-admin\tClusterRole\tadmin\tUser:hayeoung\n' "$ns"; done
    printf 'cluster\thayeoung-clusterversion-reader\tClusterRole\tfds-clusterversion-reader\tUser:hayeoung\n'   # #5 6258874244
  } >"$d/access-paths-hayeoung.tsv"
  for r in cluster-admin self-provisioner admin; do echo '{"kind":"ClusterRole"}' >"$d/clusterrole-$r.json"; done
  echo '{"kind":"ClusterRole","rules":[{"apiGroups":["config.openshift.io"],"resources":["clusterversions"],"resourceNames":["version"],"verbs":["get"]}]}' >"$d/clusterrole-fds-clusterversion-reader.json"
}
policy() { printf '# scope\tbinding\troleRef.kind\troleRef.name\tsubjects\trules_sha256\ncluster\tself-provisioners\tClusterRole\tself-provisioner\tGroup:system:authenticated:oauth\t%s\n' "$1"; }

t() { # name expect_rc script inv policy [env...]
  local name=$1 expect=$2 sc=$3 inv=$4 pol=$5; shift 5
  env "$@" bash "$sc" "$inv" hayeoung "$pol" "$T/$name.out" 2>"$T/$name.err"; local rc=$?
  local ok=PASS; [[ $rc == "$expect" ]] || { ok=FAIL; fail=1; }
  printf '%-34s rc=%-2s expect=%-2s => %s\n' "$name" "$rc" "$expect" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s) / jq $(jq --version 2>/dev/null || echo MISSING)"
mk "$T/i1"; policy "$SP_SHA" >"$T/p1"
t C1_normal                    0 "$C" "$T/i1" "$T/p1"
t C2_no_policy_pending         3 "$C" "$T/i1" "$T/no-such-policy"
printf 'not a policy row\n' >"$T/p-bad"
t C3_policy_malformed          1 "$C" "$T/i1" "$T/p-bad"
# 리뷰 R1 반례 ① 환경변수로 승인 namespace 확대
mk "$T/i4"; printf 'extra-scope\thayeoung-admin\tClusterRole\tadmin\tUser:hayeoung\n' >>"$T/i4/access-paths-hayeoung.tsv"
t C4_env_namespace_ignored     1 "$C"         "$T/i4" "$T/p1" APPROVED_NAMESPACES="fds-app monitoring-api ci-cd extra-scope"
t C4b_old_env_widens           0 "$T/old.sh"  "$T/i4" "$T/p1" APPROVED_NAMESPACES="fds-app monitoring-api ci-cd extra-scope"
t C5_fourth_namespace_default  1 "$C"         "$T/i4" "$T/p1"
# 리뷰 R1 반례 ② 줄바꿈만 있는 경로표
mkdir -p "$T/i6"; printf '# access paths\n\n\n' >"$T/i6/access-paths-hayeoung.tsv"
t C6_newline_only_paths        1 "$C"        "$T/i6" "$T/p1"
t C6b_old_newline_only_passes  0 "$T/old.sh" "$T/i6" "$T/p1"
# 리뷰 R1 반례 ③ 깨진 ClusterRole JSON + 빈 입력 해시를 가진 합성 policy
mk "$T/i7"; echo '{broken' >"$T/i7/clusterrole-self-provisioner.json"; policy "$EMPTY_SHA" >"$T/p7"
t C7_broken_json_stops         1 "$C"        "$T/i7" "$T/p7"
t C7b_old_broken_json_passes   0 "$T/old.sh" "$T/i7" "$T/p7"
# 기존 조건 유지: 같은 이름·규칙 변경
mk "$T/i8"; echo '{"kind":"ClusterRole","rules":[{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]}]}' >"$T/i8/clusterrole-self-provisioner.json"
t C8_rules_changed             1 "$C" "$T/i8" "$T/p1"
# 형식은 맞지만 kind 가 ClusterRole 이 아닌 JSON
mk "$T/i9"; echo '{"kind":"Role"}' >"$T/i9/clusterrole-self-provisioner.json"
t C9_wrong_kind_json           1 "$C" "$T/i9" "$T/p1"
# #5 6258874244: 키트 ClusterRole fds-clusterversion-reader — 정상은 APPROVED(C1), 규칙이 넓어지면(list 추가) STOP
mk "$T/i10"; echo '{"kind":"ClusterRole","rules":[{"apiGroups":["config.openshift.io"],"resources":["clusterversions"],"resourceNames":["version"],"verbs":["get","list"]}]}' >"$T/i10/clusterrole-fds-clusterversion-reader.json"
t C10_cv_reader_rules_widened   1 "$C" "$T/i10" "$T/p1"
grep -q $'^APPROVED	cluster	hayeoung-clusterversion-reader' "$T/C1_normal.out" 2>/dev/null || { echo "FAIL: C1 에서 clusterversion-reader 가 APPROVED 가 아님"; fail=1; }
# C7 은 PLATFORM_DEFAULT 로 분류되지 않아야 함
grep -q '^PLATFORM_DEFAULT' "$T/C7_broken_json_stops.out" 2>/dev/null && { echo "FAIL: C7 이 PLATFORM_DEFAULT 로 분류됨"; fail=1; }
exit "$fail"
