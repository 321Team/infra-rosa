#!/usr/bin/env bash
# netpol-run.sh MOCK 시험. 실제 oc/클러스터 없이 가짜 oc·curl로 단계 순서·판정 분기·중단·무쓰기를 확인한다.
# bash·GNU coreutils·awk·sed만 필요하다(python 없음).
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SOURCE_ROOT/platform/netpol/netpol-run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/netpol-run-mock.XXXXXX")"
[[ "$T" == */netpol-run-mock.* ]] || exit 2
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/oc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLLOG"
uid_for() {
  local i
  case "$1" in
    pod/tcp-allowed) i=1;; pod/tcp-control) i=2;; pod/route-probe) i=3;; pod/ingress-probe) i=4;;
    service/route-probe) i=5;; route/route-probe) i=6;; networkpolicy/probe-egress-to-route) i=7;;
    *) i=9;;
  esac
  [[ -n "${UID_SHIFT:-}" && "$1" == pod/tcp-control ]] && i=8
  printf '00000000-0000-0000-0000-%012d' "$i"
}
if [[ "$1" == config ]]; then printf 'https://api.mock.invalid:6443'; exit 0; fi
[[ "$1" == --context=mock && "$2" == --server=https://api.mock.invalid:6443 && "$3" == --insecure-skip-tls-verify=false ]] || exit 97
shift 3
a="$*"
P="-n fds-app"
case "$a" in
  "get clusterversion version -o jsonpath={.spec.clusterID}")
    [[ "$SCENARIO" == cluster_mismatch ]] && { printf '99999999-0000-0000-0000-000000000000'; exit 0; }
    printf '11111111-2222-3333-4444-555555555555'; exit 0;;
  "get namespace fds-app -o jsonpath={.metadata.uid}") printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; exit 0;;
  whoami) echo mock-admin; exit 0;;
  "get nodes -o jsonpath="*)
    if [[ "$SCENARIO" == worker_out ]]; then printf 'n1\t10.20.10.11 \nn2\t10.20.11.5 \n'
    else printf 'n1\t10.20.10.11 \nn2\t10.20.10.12 \nn3\t10.20.10.13 \n'; fi; exit 0;;
  "get network.config cluster -o jsonpath={.status.networkType}") printf 'OVNKubernetes'; exit 0;;
  "get namespace -l policy-group.network.openshift.io/ingress -o name") echo namespace/openshift-ingress; exit 0;;
  "-n openshift-dns get pods -o jsonpath={..containerPort}") printf '5353 9154'; exit 0;;
  "$P get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name")
    [[ "$SCENARIO" == ns_not_empty ]] && echo networkpolicy.networking.k8s.io/transaction-api-allow
    [[ -f "$STATE/applied-10" ]] && echo pod/tcp-allowed
    echo 'No resources found in fds-app namespace.' >&2; exit 0;;
  "apply --dry-run=server -f "*) echo "dry-run ok"; exit 0;;
  "apply -f "*" -o name")
    f="${a#apply -f }"; f="${f% -o name}"; b="$(basename "$f" .yaml)"
    [[ "$SCENARIO" == apply_fail_02 && "$b" == 02 ]] && { echo 'Error from server (Forbidden)' >&2; exit 1; }
    touch "$STATE/applied-$b"; echo "applied $b"; exit 0;;
  "$P wait "*) exit 0;;
  "$P get pod route-probe -o jsonpath={.status.podIP}") printf '10.128.2.15'; exit 0;;
  "$P get pod "*" -o jsonpath={.metadata.uid} {.metadata.creationTimestamp}")
    r="${a#"$P get pod "}"; r="pod/${r%% *}"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ "$SCENARIO" == pod_old ]] && ts=2000-01-01T00:00:00Z
    printf '%s %s' "$(uid_for "$r")" "$ts"; exit 0;;
  "$P get networkpolicy -o name")
    [[ -f "$STATE/applied-12" ]] && echo networkpolicy.networking.k8s.io/probe-egress-to-route
    [[ -f "$STATE/applied-00" ]] && echo networkpolicy.networking.k8s.io/fds-platform-default-deny
    [[ -f "$STATE/applied-01" ]] && echo networkpolicy.networking.k8s.io/allow-egress-dns
    [[ -f "$STATE/applied-02" ]] && echo networkpolicy.networking.k8s.io/allow-ingress-from-router
    [[ -f "$STATE/applied-03" ]] && echo networkpolicy.networking.k8s.io/allow-egress-onprem-approved
    [[ "$SCENARIO" == extra_np ]] && echo networkpolicy.networking.k8s.io/allow-all-from-someone
    exit 0;;
  "$P get networkpolicy fds-platform-default-deny -o jsonpath={.spec.podSelector}|"*)
    printf '{}|["Ingress","Egress"]||'; exit 0;;
  "$P get networkpolicy "*" -o jsonpath={.metadata.uid}{\"\\n\"}{.spec}")
    n="${a#"$P get networkpolicy "}"; n="${n%% *}"
    s="spec-$n"; [[ -n "${NP_CHANGED:-}" && "$n" == allow-egress-dns ]] && s="spec-changed"
    printf '11111111-0000-0000-0000-%012d\n{%s}' "${#n}" "$s"; exit 0;;
  "$P get networkpolicy -o yaml") echo 'items: []'; exit 0;;
  "$P get route route-probe -o jsonpath={.spec.host}") printf 'route-probe-fds-app.apps.mock.invalid'; exit 0;;
  "$P get route route-probe -o jsonpath="*) printf 'True'; exit 0;;
  "$P get "*" -o jsonpath={.metadata.uid}")
    r="${a#"$P get "}"; r="${r%% *}"
    [[ -f "$STATE/del-${r//\//-}" ]] && { echo "Error from server (NotFound): $r not found" >&2; exit 1; }
    printf '%s' "$(uid_for "$r")"; exit 0;;
  "$P delete "*)
    r="${a#"$P delete "}"; r="${r%% *}"; touch "$STATE/del-${r//\//-}"; echo "deleted $r"; exit 0;;
  "$P get all,networkpolicy,route -o name") exit 0;;
  "$P exec "*)
    pod="$(awk '{print $4}' <<<"$a")"
    [[ "$a" == *getent* ]] && { echo '172.30.0.1 kubernetes.default.svc.cluster.local'; exit 0; }
    tgt="${a##*</dev/tcp/}"; ip="${tgt%/*}"; port="${tgt#*/}"
    pol=0; [[ -f "$STATE/applied-00" ]] && pol=1
    if [[ "$ip:$port" == 10.1.93.55:5432 ]]; then
      if (( pol == 0 )); then
        [[ "$SCENARIO" == b_p1_timeout && "$pod" == tcp-allowed ]] && exit 124
        exit 0
      fi
      [[ "$pod" == tcp-allowed ]] && exit 0
      [[ "$SCENARIO" == a_n1_refused ]] && { echo 'bash: connect: Connection refused' >&2; exit 1; }
      exit 124
    fi
    if [[ "$ip:$port" == 10.128.2.15:8080 ]]; then (( pol == 0 )) && exit 0; exit 124; fi
    if [[ "$ip:$port" == 1.1.1.1:443 ]]; then (( pol == 0 )) && exit 0; exit 124; fi
    if [[ "$ip:$port" == 10.1.93.55:22 && "$SCENARIO" == a_n2_connected && $pol == 1 ]]; then exit 0; fi
    exit 124;;
esac
echo "unexpected: $a" >&2
exit 98
MOCK
cat >"$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >>"$CALLLOG"
printf '200'
MOCK
chmod +x "$T/bin/oc" "$T/bin/curl"
export PATH="$T/bin:$PATH"

D64="$(printf 'a%.0s' {1..64})"
export CTX=mock API=https://api.mock.invalid:6443
export EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555 EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
REF=https://github.com/321Team/fds-project-baseline/issues/37#issuecomment-1

pass=0; fail=0
check() { # name want-rc cmd...
  local name="$1" want="$2" rc; shift 2
  set +e; "$@" >"$T/last.log" 2>&1; rc=$?; set -e
  if [[ "$rc" == "$want" ]]; then pass=$((pass+1)); echo "ok   $name (rc=$rc)"
  else fail=$((fail+1)); echo "FAIL $name: rc=$rc want=$want"; sed 's/^/     /' "$T/last.log" | tail -n 8; fi
}
assert() { # name condition...
  local name="$1"; shift
  if "$@"; then pass=$((pass+1)); echo "ok   $name"; else fail=$((fail+1)); echo "FAIL $name"; fi
}
new_case() { # id [scenario]
  export SCENARIO="${2:-normal}" STATE="$T/state.$1" CALLLOG="$T/calls.$1" RUN_DIR="$T/run.$1"
  unset UID_SHIFT NP_CHANGED APPROVED_RENDER_SUMS_SHA256 STAGE_C_REF T3_REF DB_WINDOW_REF N3_TARGET
  mkdir -p "$STATE"; : >"$CALLLOG"
}
do_render() {
  env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 REG_MODE="${REG:-none}" REG_IP=10.1.93.54 REG_PORT=443 \
      TEST_IMAGE="registry.invalid/ubi9/ubi-minimal@sha256:$D64" HTTP_IMAGE="registry.invalid/ubi9/httpd-24@sha256:$D64" \
      bash "$SCRIPT" render
}
approve() { export APPROVED_RENDER_SUMS_SHA256="$(sed -n 's/^RENDER_SUMS_SHA256=//p' "$RUN_DIR/state.env")"; }
refs() { export STAGE_C_REF="$REF" T3_REF="$REF" DB_WINDOW_REF="$REF" N3_TARGET=10.1.93.50:443; }
to_stage_b() { do_render >/dev/null; approve; bash "$SCRIPT" precheck >/dev/null; refs; }
to_stage_a() { to_stage_b; bash "$SCRIPT" stage-b >/dev/null; }
no_writes() { ! grep -E -e '^--context=mock .* (apply -f|delete|exec|create|patch|label) ' "$CALLLOG" | grep -v 'apply --dry-run=server' | grep -q .; }

# ---- render ----
new_case r1
check "render: 정상(REG none)" 0 do_render
assert "render: oc 호출 0" bash -c '! [[ -s "$CALLLOG" ]]'
assert "render: 03 ipBlock 1개(IF-19 제거)" bash -c '[[ $(grep -c "ipBlock:" "$RUN_DIR/manifests/03.yaml") == 1 ]]'
assert "render: 자리표시자 0" bash -c '! grep -q "__[A-Z_]*__" "$RUN_DIR"/manifests/*.yaml'
check "render: 같은 RUN_DIR 재사용 거부" 2 do_render
new_case r2; REG=include
check "render: REG include" 0 do_render
assert "render: 03 ipBlock 2개" bash -c '[[ $(grep -c "ipBlock:" "$RUN_DIR/manifests/03.yaml") == 2 ]]'
unset REG
new_case r3
check "render: digest 없는 이미지 거부" 2 env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 REG_MODE=none \
  TEST_IMAGE=registry.invalid/ubi:latest HTTP_IMAGE="registry.invalid/h@sha256:$D64" bash "$SCRIPT" render
new_case r4
check "render: REG_MODE 미지정 거부(D22)" 2 env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 \
  TEST_IMAGE="registry.invalid/u@sha256:$D64" HTTP_IMAGE="registry.invalid/h@sha256:$D64" bash "$SCRIPT" render

# ---- precheck ----
new_case p1; do_render >/dev/null; approve
check "precheck: 정상" 0 bash "$SCRIPT" precheck
assert "precheck: 쓰기 호출 0(dry-run만)" no_writes
check "precheck: 재실행 거부" 30 bash "$SCRIPT" precheck
new_case p2 worker_out; do_render >/dev/null; approve
check "precheck: Worker가 10.20.10.0/24 밖 → STOP" 20 bash "$SCRIPT" precheck
new_case p3 ns_not_empty; do_render >/dev/null; approve
check "precheck: 대상 NS에 기존 NetworkPolicy → STOP" 20 bash "$SCRIPT" precheck
new_case p4; do_render >/dev/null; export APPROVED_RENDER_SUMS_SHA256="$D64"
check "precheck: 렌더 해시가 승인값과 다름" 21 bash "$SCRIPT" precheck
new_case p5; do_render >/dev/null; approve; echo '# edit' >>"$RUN_DIR/manifests/03.yaml"
check "precheck: 렌더 파일 변조" 21 bash "$SCRIPT" precheck
new_case p6 cluster_mismatch; do_render >/dev/null; approve
check "precheck: Cluster ID 불일치" 10 bash "$SCRIPT" precheck

# ---- stage-b ----
new_case b1; do_render >/dev/null; approve; refs
check "stage-b: precheck 없이 거부" 30 bash "$SCRIPT" stage-b
new_case b2; do_render >/dev/null; approve; bash "$SCRIPT" precheck >/dev/null; : >"$CALLLOG"
check "stage-b: #37 단계 C·T3 기록 링크 없음 → 시작 안 함" 30 bash "$SCRIPT" stage-b
assert "stage-b: 링크 없을 때 oc 호출 0" bash -c '! [[ -s "$CALLLOG" ]]'
new_case b3; to_stage_b; export N3_TARGET=10.1.93.55:443
check "stage-b: N3가 승인 DB IP와 같음 거부" 2 bash "$SCRIPT" stage-b
new_case b4 b_p1_timeout; to_stage_b
check "stage-b: B에서 P1 TIMEOUT → 기준 불성립" 40 bash "$SCRIPT" stage-b
assert "stage-b: 기준 불성립 시 플랫폼 00 미적용" bash -c '! [[ -f "$STATE/applied-00" ]]'
check "stage-a: B 실패 RUN에서 거부" 30 bash "$SCRIPT" stage-a

# ---- 전체 흐름 ----
new_case f1; to_stage_b
check "stage-b: 정상" 0 bash "$SCRIPT" stage-b
assert "stage-b: created.tsv 7개" bash -c '[[ $(wc -l <"$RUN_DIR/stage-b/created.tsv") == 7 ]]'
check "stage-b: 같은 RUN 재실행 거부" 30 bash "$SCRIPT" stage-b
check "stage-a: 정상" 0 bash "$SCRIPT" stage-a
assert "stage-a: 00→01→02→03 순서" bash -c 'grep -o "apply -f [^ ]*/0[0-3].yaml" "$CALLLOG" | sed "s#.*/##" | tr "\n" " " | grep -qx "00.yaml 01.yaml 02.yaml 03.yaml "'
assert "stage-a: Handoff READY/YES" bash -c 'grep -q "^ROUTE_READY=YES" "$RUN_DIR/stage-a/handoff.txt" && grep -q "^HYBRID_ROUTE=READY" "$RUN_DIR/stage-a/handoff.txt"'
check "cleanup: 정상" 0 bash "$SCRIPT" cleanup
assert "cleanup: 시험 자원 7개 삭제, 00~03 삭제 없음" bash -c '[[ $(grep -c " delete " "$CALLLOG") == 7 ]] && ! grep -E " delete networkpolicy/(fds-platform|allow-)" "$CALLLOG" | grep -q .'

# ---- stage-a 분기 ----
new_case a1 extra_np; to_stage_a
check "stage-a: 다른 allow 정책 혼입 → STOP" 42 bash "$SCRIPT" stage-a
new_case a2 a_n1_refused; to_stage_a
check "stage-a: N1 REFUSED → 판정 불가" 51 bash "$SCRIPT" stage-a
new_case a3 a_n2_connected; to_stage_a
check "stage-a: N2 연결됨 → FAIL" 50 bash "$SCRIPT" stage-a
new_case a4 pod_old; to_stage_a
check "stage-a: 시험 Pod 수명 초과 → STOP" 30 bash "$SCRIPT" stage-a
assert "stage-a: 수명 초과 시 정책 미적용" bash -c '! [[ -f "$STATE/applied-00" ]]'
new_case a5 apply_fail_02; to_stage_a
check "stage-a: 02 apply 실패 → STOP" 41 bash "$SCRIPT" stage-a
assert "stage-a: 실패 뒤 03 미적용" bash -c '! [[ -f "$STATE/applied-03" ]]'

# ---- cleanup 분기 ----
new_case c1; to_stage_a; bash "$SCRIPT" stage-a >/dev/null; export UID_SHIFT=1
check "cleanup: UID 불일치 자원은 HOLD" 60 bash "$SCRIPT" cleanup
assert "cleanup: UID 불일치 자원 삭제 안 함" bash -c '! grep -q " delete pod/tcp-control" "$CALLLOG"'
new_case c2; to_stage_a; bash "$SCRIPT" stage-a >/dev/null; export NP_CHANGED=1
check "cleanup: 00~03 spec 변화 → HOLD" 60 bash "$SCRIPT" cleanup

echo "----"
echo "PASS=$pass FAIL=$fail"
(( fail == 0 ))
