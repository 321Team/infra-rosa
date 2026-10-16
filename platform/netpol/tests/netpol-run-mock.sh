#!/usr/bin/env bash
# netpol-run.sh MOCK 시험. 실제 oc/클러스터 없이 가짜 oc·curl로 단계 순서·판정 분기·중단·무쓰기·
# 부분 생성 기록·cleanup 재시도·승인 입력 결속을 확인한다. bash·GNU coreutils·awk·sed만 필요(python 없음).
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SOURCE_ROOT/platform/netpol/netpol-run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/netpol-run-mock.XXXXXX")"
[[ "$T" == */netpol-run-mock.* ]] || exit 2
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"

# 가짜 oc: 객체 존재를 $STATE/obj-<kind>-<name> 파일로 흉내 낸다.
cat >"$T/bin/oc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLLOG"
once() { [[ -f "$STATE/once-$1" ]] && return 1; touch "$STATE/once-$1"; }
uid_for() {
  local i
  case "$1" in
    pod/tcp-allowed) i=1;; pod/tcp-control) i=2;; pod/route-probe) i=3;; pod/ingress-probe) i=4;;
    service/route-probe) i=5;; route/route-probe) i=6;; networkpolicy/probe-egress-to-route) i=7;;
    networkpolicy/fds-platform-default-deny) i=10;; networkpolicy/allow-egress-dns) i=11;;
    networkpolicy/allow-ingress-from-router) i=12;; networkpolicy/allow-egress-onprem-approved) i=13;;
    *) i=99;;
  esac
  [[ -n "${UID_SHIFT:-}" && "$1" == pod/tcp-control ]] && i=8
  printf '00000000-0000-0000-0000-%012d' "$i"
}
long_name() { case "${1%%/*}" in route) echo "route.route.openshift.io/${1#*/}";; networkpolicy) echo "networkpolicy.networking.k8s.io/${1#*/}";; *) echo "$1";; esac; }
objs_of() {
  case "$1" in
    10) echo pod/tcp-allowed pod/tcp-control;; 11) echo pod/route-probe service/route-probe route/route-probe;;
    12) echo pod/ingress-probe networkpolicy/probe-egress-to-route;;
    00) echo networkpolicy/fds-platform-default-deny;; 01) echo networkpolicy/allow-egress-dns;;
    02) echo networkpolicy/allow-ingress-from-router;; 03) echo networkpolicy/allow-egress-onprem-approved;;
  esac
}
exists() { [[ -f "$STATE/obj-${1//\//-}" ]]; }
case "$1" in
  config) printf 'https://api.mock.invalid:6443'; exit 0;;
  version) echo 'Client Version: 4.22.0-mock'; exit 0;;
esac
[[ "$1" == --request-timeout=* && "$2" == --context=mock && "$3" == --server=https://api.mock.invalid:6443 && "$4" == --insecure-skip-tls-verify=false ]] || exit 97
shift 4
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
    for f in "$STATE"/obj-*; do [[ -e "$f" ]] || continue; b="${f##*/obj-}"; long_name "${b%%-*}/${b#*-}"; done
    echo 'No resources found in fds-app namespace.' >&2; exit 0;;
  "apply --dry-run=server -f "*) echo "dry-run ok"; exit 0;;
  "apply -f "*" -o name")
    f="${a#apply -f }"; f="${f% -o name}"; n="$(basename "$f" .yaml)"; rc=0; first=1
    for o in $(objs_of "$n"); do
      if [[ "$SCENARIO" == "apply_fail_$n" ]]; then
        # 다중 객체 파일은 첫 객체만 만들고 실패, 단일 객체 파일은 아무것도 만들지 않고 실패
        if (( first )) && [[ "$(objs_of "$n" | wc -w)" -gt 1 ]]; then touch "$STATE/obj-${o//\//-}"; long_name "$o"; first=0; continue; fi
        echo "Error from server (Forbidden): $o" >&2; rc=1; continue
      fi
      touch "$STATE/obj-${o//\//-}"; long_name "$o"
    done
    exit $rc;;
  "$P wait "*) exit 0;;
  "$P get pod "*" -o jsonpath={.metadata.uid}{\"\\t\"}{.status.podIP}"*)
    r="${a#"$P get pod "}"; r="${r%% *}"
    D="$(printf 'a%.0s' {1..64})"
    case "$r" in
      tcp-allowed) node=n1; ip=10.128.2.11; img="registry.invalid/ubi9/ubi-minimal@sha256:$D";;
      tcp-control) node=n2; ip=10.129.0.12; img="registry.invalid/ubi9/ubi-minimal@sha256:$D"; [[ -f "$STATE/moved" ]] && node=n3;;
      ingress-probe) node=n1; ip=10.128.2.14; img="registry.invalid/ubi9/ubi-minimal@sha256:$D";;
      route-probe) node=n3; ip=10.128.2.15; img="registry.invalid/ubi9/httpd-24@sha256:$D";;
    esac
    [[ "$SCENARIO" == digest_diff && "$r" == tcp-allowed ]] && img="registry.invalid/ubi9/ubi-minimal@sha256:$(printf 'b%.0s' {1..64})"
    printf '%s\t%s\t%s\t%s\t{"app":"%s"}' "$(uid_for "pod/$r")" "$ip" "$node" "$img" "$r"; exit 0;;
  "get node "*" -o jsonpath="*)
    n="${a#get node }"; n="${n%% *}"
    case "$n" in n1) ip=10.20.10.11;; n2) ip=10.20.10.12;; n3) ip=10.20.10.13;; *) echo "NotFound node $n" >&2; exit 1;; esac
    printf 'node-uid-%s\t%s' "$n" "$ip"; exit 0;;
  "get pods -A --field-selector spec.nodeName="*)
    n="${a#get pods -A --field-selector spec.nodeName=}"; n="${n%% *}"
    printf 'openshift-dns\tdns-default-%s\nopenshift-ovn-kubernetes\tovnkube-node-%s\n' "$n" "$n"
    [[ "$n" == n1 ]] && printf 'fds-app\ttcp-allowed\nfds-app\tingress-probe\n'
    [[ "$n" == n2 ]] && printf 'fds-app\ttcp-control\n'
    { [[ "$SCENARIO" == app_pod_on_node ]] || [[ -f "$STATE/apppod" ]]; } && [[ "$n" == n2 ]] && printf 'payments\tapi-7d9f\n'
    exit 0;;
  "$P get pod route-probe -o jsonpath={.status.podIP}") printf '10.128.2.15'; exit 0;;
  "$P get pod "*" -o jsonpath={.metadata.uid} {.metadata.creationTimestamp}")
    r="${a#"$P get pod "}"; r="pod/${r%% *}"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ "$SCENARIO" == pod_old ]] && ts=2000-01-01T00:00:00Z
    printf '%s %s' "$(uid_for "$r")" "$ts"; exit 0;;
  "$P get networkpolicy -o name")
    for f in "$STATE"/obj-networkpolicy-*; do [[ -e "$f" ]] || continue; echo "networkpolicy.networking.k8s.io/${f##*/obj-networkpolicy-}"; done
    [[ "$SCENARIO" == extra_np ]] && echo networkpolicy.networking.k8s.io/allow-all-from-someone
    exit 0;;
  "$P get networkpolicy fds-platform-default-deny -o jsonpath={.spec.podSelector}|"*)
    printf '{}|["Ingress","Egress"]||'; exit 0;;
  "$P get networkpolicy "*" -o jsonpath={.metadata.uid}{\"\\n\"}{.spec}")
    n="${a#"$P get networkpolicy "}"; n="${n%% *}"
    exists "networkpolicy/$n" || { echo "Error from server (NotFound): $n" >&2; exit 1; }
    s="spec-$n"; [[ -n "${NP_CHANGED:-}" && "$n" == allow-egress-dns ]] && s="spec-changed"
    printf '%s\n{%s}' "$(uid_for "networkpolicy/$n")" "$s"; exit 0;;
  "$P get networkpolicy -o yaml")
    [[ "$SCENARIO" == np_yaml_fail ]] && { echo 'Error from server (Timeout)' >&2; exit 1; }
    echo 'items: []'; exit 0;;
  "$P get route route-probe -o jsonpath={.spec.host}") printf 'route-probe-fds-app.apps.mock.invalid'; exit 0;;
  "$P get route route-probe -o jsonpath="*)
    [[ "$SCENARIO" == r2_rc_fail ]] && { printf 'True'; exit 1; }
    printf 'True'; exit 0;;
  "$P get all,networkpolicy,route -o name")
    [[ "$SCENARIO" == after_fail ]] && { echo 'Error from server (Timeout)' >&2; exit 1; }
    for f in "$STATE"/obj-*; do [[ -e "$f" ]] || continue; b="${f##*/obj-}"; long_name "${b%%-*}/${b#*-}"; done
    exit 0;;
  "$P get "*" -o jsonpath={.metadata.uid}")
    r="${a#"$P get "}"; r="${r%% *}"
    if [[ "$SCENARIO" == uid_fail && "$r" == pod/tcp-control ]] && once uidfail; then echo 'Error from server (Forbidden)' >&2; exit 1; fi
    exists "$r" || { echo "Error from server (NotFound): $r not found" >&2; exit 1; }
    printf '%s' "$(uid_for "$r")"; exit 0;;
  "$P delete "*)
    r="${a#"$P delete "}"; r="${r%% *}"
    if [[ "$SCENARIO" == del_fail_once && "$r" == pod/tcp-control ]] && once delfail; then echo 'Error from server (InternalError)' >&2; exit 1; fi
    rm -f "$STATE/obj-${r//\//-}"; echo "deleted $r"; exit 0;;
  "$P exec "*)
    pod="$(awk '{print $4}' <<<"$a")"
    [[ "$a" == *getent* ]] && { echo '172.30.0.1 kubernetes.default.svc.cluster.local'; exit 0; }
    ip="${@: -2:1}"; port="${@: -1}"
    printf '%s %s %s\n' "$pod" "$ip" "$port" >>"$STATE/exec-targets"
    [[ "$SCENARIO" == exec_hang && "$pod" == tcp-control && -f "$STATE/obj-networkpolicy-fds-platform-default-deny" ]] && { sleep 10; exit 0; }
    pol=0; [[ -f "$STATE/obj-networkpolicy-fds-platform-default-deny" ]] && pol=1
    # R5: 원격 표식은 찍혔지만 바깥 exec가 실패
    [[ "$SCENARIO" == exec_rc_marker && "$pod" == tcp-control && $pol == 1 ]] && { echo "NETPOL_RC=124"; echo 'error: stream closed' >&2; exit 42; }
    [[ "$SCENARIO" == exec_rc_marker_b && "$pod" == tcp-allowed && "$ip:$port" == 10.1.93.55:5432 && $pol == 0 ]] && { echo "NETPOL_RC=0"; echo 'error: stream closed' >&2; exit 42; }
    if [[ "$ip:$port" == 10.1.93.55:22 ]] && { [[ "$SCENARIO" == b_n2_toolerror && $pol == 0 ]] || [[ "$SCENARIO" == a_n2_toolerror && $pol == 1 ]]; }; then
      echo 'error: unable to upgrade connection: container not found' >&2; exit 1
    fi
    r=124
    if [[ "$ip:$port" == 10.1.93.55:5432 ]]; then
      if (( pol == 0 )); then r=0; [[ "$SCENARIO" == b_p1_timeout && "$pod" == tcp-allowed ]] && r=124
      elif [[ "$pod" == tcp-allowed ]]; then r=0
      elif [[ "$SCENARIO" == a_n1_refused ]]; then echo 'bash: connect: Connection refused' >&2; r=1; fi
    elif [[ "$ip:$port" == 10.1.93.50:443 && "$SCENARIO" == a_n3_refused && $pol == 1 ]]; then echo 'bash: connect: Connection refused' >&2; r=1
    elif [[ "$ip:$port" == 1.1.1.1:443 ]]; then
      (( pol == 0 )) && r=0
      [[ "$SCENARIO" == a_n4_refused && $pol == 1 ]] && { echo 'bash: connect: Connection refused' >&2; r=1; }
    elif [[ "$ip:$port" == 10.128.2.15:8080 ]]; then (( pol == 0 )) && r=0
    elif [[ "$ip:$port" == 10.1.93.55:22 && "$SCENARIO" == a_n2_connected && $pol == 1 ]]; then r=0
    fi
    echo "NETPOL_RC=$r"; exit 0;;
esac
echo "unexpected: $a" >&2
exit 98
MOCK
cat >"$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >>"$CALLLOG"
[[ "$*" == *" -k"* || "$*" == *"-sSk"* ]] && { printf '200'; exit 0; }
[[ "$SCENARIO" == tls_fail ]] && { echo 'curl: (60) SSL certificate problem' >&2; exit 60; }
printf '200'
MOCK
chmod +x "$T/bin/oc" "$T/bin/curl"
export PATH="$T/bin:$PATH"

D64="$(printf 'a%.0s' {1..64})"
TARGET_ENV=(CTX=mock API=https://api.mock.invalid:6443 EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555 EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)
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
  unset UID_SHIFT NP_CHANGED APPROVED_BUNDLE_SHA256 BINDING_SHA256 STAGE_C_REF T3_REF DB_WINDOW_REF NETPOL_EXEC_TIMEOUT_S CTX API EXPECTED_CLUSTER_ID EXPECTED_NS_UID
  mkdir -p "$STATE"; : >"$CALLLOG"
}
do_render() {
  env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 REG_MODE="${REG:-none}" REG_IP=10.1.93.54 REG_PORT=443 \
      TEST_IMAGE="registry.invalid/ubi9/ubi-minimal@sha256:$D64" HTTP_IMAGE="registry.invalid/ubi9/httpd-24@sha256:$D64" \
      N3_TARGET="${N3:-10.1.93.50:443}" bash "$SCRIPT" render
}
approve() { export APPROVED_BUNDLE_SHA256="$(sha256sum "$RUN_DIR/bundle.txt" | cut -d' ' -f1)"; }
precheck() { env "${TARGET_ENV[@]}" bash "$SCRIPT" precheck; }
refs() { export STAGE_C_REF="$REF" T3_REF="$REF" DB_WINDOW_REF="$REF"; }
to_prepare() { do_render >/dev/null; approve; precheck >/dev/null; refs; }
bind() { export BINDING_SHA256="$(sha256sum "$RUN_DIR/prepare/binding.tsv" | cut -d" " -f1)"; }
to_stage_b() { to_prepare; bash "$SCRIPT" prepare >/dev/null; bind; }
to_stage_a() { to_stage_b; bash "$SCRIPT" stage-b >/dev/null; }
calls_writes() { grep -E -e ' (apply -f|delete|exec|create|patch|label) ' "$CALLLOG" | grep -v 'apply --dry-run=server' | grep -q .; }
export -f calls_writes

# ---- render ----
new_case r1
check "render: 정상(REG none)" 0 do_render
assert "render: oc 호출 0" bash -c '! [[ -s "$CALLLOG" ]]'
assert "render: 03 ipBlock 1개(IF-19 제거)" bash -c '[[ $(grep -c "ipBlock:" "$RUN_DIR/manifests/03.yaml") == 1 ]]'
assert "render: 자리표시자 0" bash -c '! grep -q "__[A-Z_]*__" "$RUN_DIR"/manifests/*.yaml'
assert "render: 승인 입력에 N3·R1 코드 포함" bash -c 'grep -qx "N3_TARGET=10.1.93.50:443" "$RUN_DIR/approved-inputs.env" && grep -qx "R1_EXPECTED_CODES=200" "$RUN_DIR/approved-inputs.env"'
assert "render: bundle에 kit·manifest·입력 해시" bash -c 'grep -q "^KIT_SHA256=" "$RUN_DIR/bundle.txt" && grep -q "^MANIFEST_SUMS_SHA256=" "$RUN_DIR/bundle.txt" && grep -q "^INPUTS_SHA256=" "$RUN_DIR/bundle.txt"'
check "render: 같은 RUN_DIR 재사용 거부" 2 do_render
new_case r2; REG=include
check "render: REG include" 0 do_render
assert "render: 03 ipBlock 2개" bash -c '[[ $(grep -c "ipBlock:" "$RUN_DIR/manifests/03.yaml") == 2 ]]'
unset REG
new_case r3
check "render: digest 없는 이미지 거부" 2 env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 REG_MODE=none N3_TARGET=10.1.93.50:443 \
  TEST_IMAGE=registry.invalid/ubi:latest HTTP_IMAGE="registry.invalid/h@sha256:$D64" bash "$SCRIPT" render
new_case r4
check "render: REG_MODE 미지정 거부(D22)" 2 env NS=fds-app TEAM=321team DB_IP=10.1.93.55 DB_PORT=5432 N3_TARGET=10.1.93.50:443 \
  TEST_IMAGE="registry.invalid/u@sha256:$D64" HTTP_IMAGE="registry.invalid/h@sha256:$D64" bash "$SCRIPT" render
new_case r5; N3=10.1.93.55:443
check "render: N3가 승인 DB IP와 같음 거부" 2 do_render
unset N3

# ---- precheck ----
new_case p1; do_render >/dev/null; approve
check "precheck: 정상" 0 precheck
assert "precheck: 쓰기 호출 0(dry-run만)" bash -c '! calls_writes'
assert "precheck: WORKER_COUNT=3(dry-run 변수와 분리)" bash -c 'grep -qx "WORKER_COUNT=3" "$RUN_DIR/precheck/context.txt"'
assert "precheck: target.env 고정" bash -c 'grep -qx "CLUSTER_ID=11111111-2222-3333-4444-555555555555" "$RUN_DIR/target.env"'
assert "precheck: KST가 +0900" bash -c 'grep -q "^KST=.*+0900$" "$RUN_DIR/precheck/context.txt"'
assert "precheck: commands.tsv에 argv 기록" bash -c 'grep -q "get clusterversion version" "$RUN_DIR/precheck/commands.tsv"'
check "precheck: 재실행 거부" 30 precheck
new_case p2 worker_out; do_render >/dev/null; approve
check "precheck: Worker가 10.20.10.0/24 밖 → STOP" 20 precheck
new_case p3 ns_not_empty; do_render >/dev/null; approve
check "precheck: 대상 NS에 기존 NetworkPolicy → STOP" 20 precheck
new_case p4; do_render >/dev/null; export APPROVED_BUNDLE_SHA256="$D64"
check "precheck: bundle 해시가 승인값과 다름" 21 precheck
new_case p5; do_render >/dev/null; approve; chmod u+w "$RUN_DIR/manifests/03.yaml"; echo '# edit' >>"$RUN_DIR/manifests/03.yaml"
check "precheck: 렌더 파일 변조" 21 precheck
new_case p6 cluster_mismatch; do_render >/dev/null; approve
check "precheck: Cluster ID 불일치" 10 precheck
new_case p7; do_render >/dev/null; approve; chmod u+w "$RUN_DIR/approved-inputs.env"; echo 'DB_IP=203.0.113.77' >>"$RUN_DIR/approved-inputs.env"
check "precheck: 승인 입력 변조 → 쓰기 전 STOP" 21 precheck
assert "precheck: 그때 oc 호출 0" bash -c '! [[ -s "$CALLLOG" ]]'

# ---- 승인 입력·대상 결속 (R3) ----
new_case k1; to_stage_b; echo 'DB_IP=203.0.113.77' >>"$RUN_DIR/state.env"
check "결속: state.env에 DB_IP를 덧붙여도 정상 진행" 0 bash "$SCRIPT" stage-b
assert "결속: probe는 승인 입력의 DB만 호출(203.0.113.77 호출 0)" bash -c '! grep -q 203.0.113.77 "$STATE/exec-targets" && grep -q "10.1.93.55 5432" "$STATE/exec-targets"'
new_case k2; to_stage_b; : >"$CALLLOG"
check "결속: stage-b에 다른 Cluster ID 기대값 → STOP" 10 env EXPECTED_CLUSTER_ID=99999999-0000-0000-0000-000000000000 bash "$SCRIPT" stage-b
assert "결속: 그때 쓰기 0" bash -c '! calls_writes'
new_case k3; to_stage_b; cp "$SCRIPT" "$T/kit-copy.sh"; echo '# changed' >>"$T/kit-copy.sh"
check "결속: kit가 바뀌면 STOP" 21 bash "$T/kit-copy.sh" stage-b
new_case k4; to_stage_b; chmod u+w "$RUN_DIR/precheck.ok"; printf 'BUNDLE=x TARGET=y' >"$RUN_DIR/precheck.ok"
check "결속: precheck.ok가 다른 bundle·대상 → STOP" 30 bash "$SCRIPT" stage-b

# ---- prepare (측정 전 확인점) ----
new_case b1; do_render >/dev/null; approve; refs
check "prepare: precheck 없이 거부" 30 bash "$SCRIPT" prepare
check "stage-b: prepare 없이 거부" 30 bash "$SCRIPT" stage-b
new_case b2; do_render >/dev/null; approve; precheck >/dev/null; : >"$CALLLOG"
check "prepare: #37 단계 C·T3·db01 기록 링크 없음 → 시작 안 함" 30 bash "$SCRIPT" prepare
assert "prepare: 링크 없을 때 oc 호출 0" bash -c '! [[ -s "$CALLLOG" ]]'
new_case b3; to_prepare
check "prepare: 정상" 0 bash "$SCRIPT" prepare
assert "prepare: TCP 시도 0" bash -c '! [[ -s "$STATE/exec-targets" ]]'
assert "prepare: 결속 4행(Pod·UID·Pod IP·노드·노드 UID·egress IP·imageID)" bash -c '[[ $(wc -l <"$RUN_DIR/prepare/binding.tsv") == 4 ]] && grep -q "^tcp-allowed	.*	n1	node-uid-n1	10.20.10.11	" "$RUN_DIR/prepare/binding.tsv"'
check "stage-b: BINDING_SHA256 없음 → TCP 전 거부" 30 bash "$SCRIPT" stage-b
check "stage-b: BINDING_SHA256 다름 → 거부" 30 env BINDING_SHA256="$D64" bash "$SCRIPT" stage-b
assert "stage-b: 그때 TCP 시도 0" bash -c '! [[ -s "$STATE/exec-targets" ]]'
new_case b7 digest_diff; to_prepare
check "prepare: imageID digest가 승인값과 다름 → STOP" 22 bash "$SCRIPT" prepare
new_case b8 app_pod_on_node; to_prepare
check "prepare: 시험 노드에 시험 외 앱 Pod → STOP" 22 bash "$SCRIPT" prepare
assert "prepare: 그 Pod 이름 기록" bash -c 'grep -q "payments/api-7d9f" "$RUN_DIR/prepare/binding-stop.txt"'
check "cleanup: 결속 STOP 뒤 시험 자원 정리" 0 bash "$SCRIPT" cleanup
new_case b9; to_stage_b; touch "$STATE/moved"
check "stage-b: prepare 뒤 tcp-control 노드 이동 → 첫 TCP 전 STOP" 22 bash "$SCRIPT" stage-b
assert "stage-b: 그때 TCP 시도 0" bash -c '! [[ -s "$STATE/exec-targets" ]]'
new_case b10; to_stage_b; touch "$STATE/apppod"
check "stage-b: prepare 뒤 시험 노드에 앱 Pod 등장 → 첫 TCP 전 STOP" 22 bash "$SCRIPT" stage-b
new_case b5 apply_fail_11; to_prepare
check "prepare: 11 일부만 생성 → STOP" 41 bash "$SCRIPT" prepare
assert "prepare: 10의 2개·11의 첫 객체는 OWNED로 즉시 기록" bash -c '[[ $(grep -c "	OWNED	" "$RUN_DIR/prepare/created.tsv") == 3 ]] && grep -q "^pod/route-probe	.*	OWNED	11" "$RUN_DIR/prepare/created.tsv"'
check "cleanup: 부분 생성 RUN도 OWNED 정리 가능" 0 bash "$SCRIPT" cleanup
assert "cleanup: 만든 3개 삭제, 남은 자원 0" bash -c '[[ $(grep -c " delete " "$CALLLOG") == 3 ]] && ! ls "$STATE"/obj-* >/dev/null 2>&1'
new_case b6 uid_fail; to_prepare
check "prepare: UID 조회 실패 → 미확인 기록 후 STOP" 41 bash "$SCRIPT" prepare
assert "prepare: tcp-control은 UNCONFIRMED" bash -c 'grep -q "^pod/tcp-control	-	UNCONFIRMED" "$RUN_DIR/prepare/created.tsv"'

# ---- stage-b ----
new_case b4 b_p1_timeout; to_stage_b
check "stage-b: B에서 P1 TIMEOUT → 기준 불성립" 40 bash "$SCRIPT" stage-b
assert "stage-b: 기준 불성립 시 플랫폼 00 미적용" bash -c '! [[ -f "$STATE/obj-networkpolicy-fds-platform-default-deny" ]]'
check "stage-a: B 실패 RUN에서 거부" 30 bash "$SCRIPT" stage-a
check "cleanup: B 실패 뒤 시험 자원 정리(POLICY_SET=NONE)" 0 bash "$SCRIPT" cleanup
new_case b11 exec_rc_marker_b; to_stage_b
check "stage-b: 표식 NETPOL_RC=0이어도 바깥 exec rc≠0 → P1 TOOL_ERROR, 기준 불성립(R5)" 40 bash "$SCRIPT" stage-b
assert "stage-b: P1은 TOOL_ERROR" bash -c 'grep -q "^B	P1	.*	exec=42,tcp=0	TOOL_ERROR$" "$RUN_DIR/stage-b/results.tsv"'
new_case b6c uid_fail; to_prepare; bash "$SCRIPT" prepare >/dev/null 2>&1 || true
check "cleanup: UNCONFIRMED 있으면 HOLD" 60 bash "$SCRIPT" cleanup
assert "cleanup: UNCONFIRMED 자원은 삭제 안 함" bash -c '! grep -q " delete pod/tcp-control" "$CALLLOG"'

# ---- 전체 흐름 ----
new_case f1; to_stage_b
check "stage-b: 정상" 0 bash "$SCRIPT" stage-b
assert "prepare: created.tsv 7개 OWNED" bash -c '[[ $(grep -c "	OWNED	" "$RUN_DIR/prepare/created.tsv") == 7 ]]'
assert "stage-b: B단계 R1 기록" bash -c 'grep -q "^B	R1	" "$RUN_DIR/stage-b/results.tsv"'
check "stage-b: 같은 RUN 재실행 거부" 30 bash "$SCRIPT" stage-b
check "stage-a: 정상" 0 bash "$SCRIPT" stage-a
assert "stage-a: 00→01→02→03 순서" bash -c 'grep -o "apply -f [^ ]*/0[0-3].yaml" "$CALLLOG" | sed "s#.*/##" | tr "\n" " " | grep -qx "00.yaml 01.yaml 02.yaml 03.yaml "'
assert "stage-a: Handoff READY/YES·POLICY_SET=FULL" bash -c 'grep -q "^ROUTE_READY=YES" "$RUN_DIR/stage-a/handoff.txt" && grep -q "^HYBRID_ROUTE=READY" "$RUN_DIR/stage-a/handoff.txt" && grep -q "^POLICY_SET=FULL" "$RUN_DIR/policy-set.txt"'
assert "stage-a: B부터 막힌 N2·N3는 정책 효과 미주장" bash -c 'grep -qx "N2	TIMEOUT	TIMEOUT	NO_CLAIM_UPSTREAM" "$RUN_DIR/stage-a/np-effect.tsv" && grep -qx "N3	TIMEOUT	TIMEOUT	NO_CLAIM_UPSTREAM" "$RUN_DIR/stage-a/np-effect.tsv"'
assert "stage-a: B CONNECTED→A TIMEOUT만 NP_EFFECT(N1,N4,N5)" bash -c 'grep -q "^NP_EFFECT=N1,N4,N5 " "$RUN_DIR/stage-a/handoff.txt" && grep -q "^NO_CLAIM_UPSTREAM=N2,N3 " "$RUN_DIR/stage-a/handoff.txt"'
assert "stage-a: curl -k 호출 0" bash -c '! grep -E "curl .*(-k|-sSk)" "$CALLLOG" | grep -q .'
check "cleanup: 정상" 0 bash "$SCRIPT" cleanup
assert "cleanup: 시험 자원 7개 삭제, 00~03 삭제 없음" bash -c '[[ $(grep -c " delete " "$CALLLOG") == 7 ]] && ! grep -E " delete networkpolicy/(fds-platform|allow-)" "$CALLLOG" | grep -q .'
check "cleanup: 완료 뒤 재실행 거부" 30 bash "$SCRIPT" cleanup

# ---- stage-a 분기 ----
new_case a1 extra_np; to_stage_a
check "stage-a: 다른 allow 정책 혼입 → STOP" 42 bash "$SCRIPT" stage-a
new_case a2 a_n1_refused; to_stage_a
check "stage-a: N1 REFUSED → 판정 불가" 51 bash "$SCRIPT" stage-a
new_case a3 a_n2_connected; to_stage_a
check "stage-a: N2 연결됨 → FAIL" 50 bash "$SCRIPT" stage-a
new_case a6 a_n3_refused; to_stage_a
check "stage-a: B부터 막힌 N3가 A에서 REFUSED → 미주장 기록(통과)" 0 bash "$SCRIPT" stage-a
assert "stage-a: 그 N3는 NO_CLAIM_UPSTREAM" bash -c 'grep -qx "N3	TIMEOUT	REFUSED	NO_CLAIM_UPSTREAM" "$RUN_DIR/stage-a/np-effect.tsv"'
new_case a7 a_n4_refused; to_stage_a
check "stage-a: B CONNECTED였던 N4가 A에서 REFUSED → 판정 불가" 51 bash "$SCRIPT" stage-a
new_case a12 a_n2_toolerror; to_stage_a
check "stage-a: B=TIMEOUT·A=TOOL_ERROR(N2) → 미주장이 아니라 판정 불가" 51 bash "$SCRIPT" stage-a
assert "stage-a: 그 N2는 INCONCLUSIVE" bash -c 'grep -q "^N2	TIMEOUT	TOOL_ERROR	INCONCLUSIVE$" "$RUN_DIR/stage-a/np-effect.tsv"'
new_case a13 b_n2_toolerror; to_stage_a
check "stage-a: B=TOOL_ERROR·A=TIMEOUT(N2) → B 기준 미확인, 판정 불가" 51 bash "$SCRIPT" stage-a
assert "stage-a: 그 N2는 INCONCLUSIVE" bash -c 'grep -q "^N2	TOOL_ERROR	TIMEOUT	INCONCLUSIVE$" "$RUN_DIR/stage-a/np-effect.tsv"'
new_case a14 exec_rc_marker; to_stage_a
check "stage-a: 표식 NETPOL_RC=124여도 바깥 exec rc≠0 → TOOL_ERROR·판정 불가(R5)" 51 bash "$SCRIPT" stage-a
assert "stage-a: N1 TOOL_ERROR, NP_EFFECT 아님, HYBRID_ROUTE=BLOCKED" bash -c 'grep -q "^A	N1	.*	exec=42,tcp=124	TOOL_ERROR$" "$RUN_DIR/stage-a/results.tsv" && grep -q "^N1	CONNECTED	TOOL_ERROR	INCONCLUSIVE$" "$RUN_DIR/stage-a/np-effect.tsv" && grep -q "^HYBRID_ROUTE=BLOCKED" "$RUN_DIR/stage-a/handoff.txt"'
new_case a15; to_stage_a; touch "$STATE/moved"
check "stage-a: stage-b 뒤 노드 이동 → 정책 적용 전 STOP" 22 bash "$SCRIPT" stage-a
assert "stage-a: 그때 플랫폼 00 미적용" bash -c '! [[ -f "$STATE/obj-networkpolicy-fds-platform-default-deny" ]]'
new_case a8 exec_hang; to_stage_a; export NETPOL_EXEC_TIMEOUT_S=2
check "stage-a: oc exec 바깥 시간 초과 → TCP TIMEOUT과 구분(판정 불가)" 51 bash "$SCRIPT" stage-a
assert "stage-a: N1은 EXEC_TIMEOUT으로 기록" bash -c 'grep -q "^A	N1	.*	EXEC_TIMEOUT$" "$RUN_DIR/stage-a/results.tsv"'
new_case a9 tls_fail; to_stage_a
check "stage-a: TLS 검증 실패 → R1 FAIL(-k 재시도 없음)" 50 bash "$SCRIPT" stage-a
assert "stage-a: TLS 실패 시 ROUTE_READY=NO" bash -c 'grep -q "^ROUTE_READY=NO" "$RUN_DIR/stage-a/handoff.txt"'
new_case a10 r2_rc_fail; to_stage_a
check "stage-a: R2 조회 rc≠0이면 True여도 FAIL" 50 bash "$SCRIPT" stage-a
new_case a11 np_yaml_fail; to_stage_a
check "stage-a: 정책 원본 증적 실패 → EVIDENCE_INCOMPLETE" 11 bash "$SCRIPT" stage-a
new_case a4 pod_old; to_stage_a
check "stage-a: 시험 Pod 수명 초과 → STOP" 30 bash "$SCRIPT" stage-a
assert "stage-a: 수명 초과 시 정책 미적용" bash -c '! [[ -f "$STATE/obj-networkpolicy-fds-platform-default-deny" ]]'
new_case a5 apply_fail_02; to_stage_a
check "stage-a: 02 apply 실패 → STOP" 41 bash "$SCRIPT" stage-a
assert "stage-a: 실패 뒤 03 미적용, POLICY_SET=PARTIAL" bash -c '! [[ -f "$STATE/obj-networkpolicy-allow-egress-onprem-approved" ]] && grep -q "^POLICY_SET=PARTIAL" "$RUN_DIR/policy-set.txt"'
assert "stage-a: 00·01은 성공 즉시 APPLIED 기록" bash -c '[[ $(grep -c "	APPLIED$" "$RUN_DIR/stage-a/np-applied.tsv") == 2 ]]'
check "cleanup: 부분 정책 → 시험 자원 정리 후 rc 61(READY 금지)" 61 bash "$SCRIPT" cleanup
assert "cleanup: 00·01은 남김" bash -c '[[ -f "$STATE/obj-networkpolicy-fds-platform-default-deny" && -f "$STATE/obj-networkpolicy-allow-egress-dns" ]]'

# ---- cleanup 분기 ----
new_case c1; to_stage_a; bash "$SCRIPT" stage-a >/dev/null; export UID_SHIFT=1
check "cleanup: UID 불일치 자원은 HOLD" 60 bash "$SCRIPT" cleanup
assert "cleanup: UID 불일치 자원 삭제 안 함" bash -c '! grep -q " delete pod/tcp-control" "$CALLLOG"'
new_case c2; to_stage_a; bash "$SCRIPT" stage-a >/dev/null; export NP_CHANGED=1
check "cleanup: 00~03 spec 변화 → HOLD" 60 bash "$SCRIPT" cleanup
new_case c3 del_fail_once; to_stage_a; bash "$SCRIPT" stage-a >/dev/null
check "cleanup: 첫 시도 삭제 실패 → HOLD" 60 bash "$SCRIPT" cleanup
check "cleanup: 같은 RUN 두 번째 시도 → 성공" 0 bash "$SCRIPT" cleanup
assert "cleanup: attempt-1·2 기록 보존, 이미 지운 자원은 ALREADY_ABSENT" bash -c '[[ -d "$RUN_DIR/cleanup-attempt-1" && -d "$RUN_DIR/cleanup-attempt-2" ]] && grep -q "ALREADY_ABSENT" "$RUN_DIR/cleanup-attempt-2/cleanup.txt"'
new_case c4 after_fail; to_stage_a; bash "$SCRIPT" stage-a >/dev/null
check "cleanup: 최종 목록 조회 실패 → HOLD" 60 bash "$SCRIPT" cleanup

echo "----"
echo "PASS=$pass FAIL=$fail"
(( fail == 0 ))
