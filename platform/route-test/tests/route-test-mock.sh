#!/usr/bin/env bash
# route-test-run.sh MOCK 시험. 실제 oc·클러스터·네트워크 없이 가짜 oc·curl·getent·openssl로
# 단계 순서·무쓰기(render/precheck)·02 정책 결속·R-1~R-4 판정·실패 진단·OWNED 정리·UID 불일치 보존·
# 목록 변화 중단·정리 재시도를 확인한다. bash·GNU coreutils·awk·sed만 필요(python 없음).
set -euo pipefail
SOURCE_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$SOURCE_ROOT/platform/route-test/route-test-run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/route-test-mock.XXXXXX")"
[[ "$T" == */route-test-mock.* ]] || exit 2
trap '[[ -n "${KEEP:-}" ]] || rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
HOST=fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com
CANON=router-default.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com
IMG="registry.access.redhat.com/ubi9/httpd-24@sha256:$(printf 'b%.0s' {1..64})"

cat >"$T/bin/oc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLLOG"
HOST=fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com
CANON=router-default.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com
uid_for() { case "$1" in pod/*) i=1;; service/*) i=2;; route/*) i=3;; *) i=9;; esac
  [[ -n "${UID_SHIFT:-}" && "$1" == service/route-host-probe && -f "$STATE/ready-done" ]] && i=7
  printf '00000000-0000-0000-0000-%012d' "$i"; }
NPS="fds-platform-default-deny allow-egress-dns allow-ingress-from-router allow-egress-onprem-approved"
case "$1" in
  config) printf 'https://api.mock.invalid:6443'; exit 0;;
  version) echo 'Client Version: 4.22.0-mock'; exit 0;;
esac
[[ "$1" == --request-timeout=* && "$2" == --context=mock && "$3" == --server=https://api.mock.invalid:6443 && "$4" == --insecure-skip-tls-verify=false ]] || exit 97
shift 4
a="$*"; P="-n fds-app"
case "$a" in
  "get clusterversion version -o jsonpath={.spec.clusterID}")
    [[ "$SCENARIO" == cid_forbidden ]] && { echo 'Error from server (Forbidden): clusterversions.config.openshift.io "version" is forbidden' >&2; exit 1; }
    [[ "$SCENARIO" == cid_mismatch ]] && { printf '99999999-0000-0000-0000-000000000000'; exit 0; }
    printf '11111111-2222-3333-4444-555555555555'; exit 0;;
  "get project fds-app -o jsonpath={.metadata.uid}") printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; exit 0;;
  whoami) echo hayeounglee; exit 0;;
  "auth can-i * * --all-namespaces") [[ "$SCENARIO" == admin ]] && { echo yes; exit 0; }; echo no; exit 1;;
  "$P auth can-i "*) [[ "$SCENARIO" == no_custom_host && "$a" == *routes/custom-host ]] && { echo no; exit 1; }; echo yes; exit 0;;
  "$P get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name")
    for n in $NPS; do echo "networkpolicy.networking.k8s.io/$n"; done
    [[ "$SCENARIO" == extra_obj ]] && echo pod/tcp-allowed
    [[ -f "$STATE/drift" ]] && echo service/someone-else
    if [[ -f "$STATE/created" ]]; then
      [[ -f "$STATE/gone-pod-route-host-probe" ]] || echo pod/route-host-probe
      [[ -f "$STATE/gone-service-route-host-probe" ]] || echo service/route-host-probe
      [[ -f "$STATE/gone-route-route-host-probe" ]] || echo route.route.openshift.io/route-host-probe
    fi
    [[ "$SCENARIO" == leftover && -f "$STATE/deleted" ]] && echo configmap/leftover-should-not-matter >/dev/null
    exit 0;;
  "$P get networkpolicy allow-ingress-from-router -o jsonpath="*)
    [[ "$SCENARIO" == np02_port ]] && { printf 'true|TCP|80'; exit 0; }
    printf 'true|TCP|8080'; exit 0;;
  "$P get networkpolicy "*" -o jsonpath={.metadata.uid}{\"\\n\"}{.spec}")
    n="${a#"$P get networkpolicy "}"; n="${n%% *}"
    s="spec-$n"; [[ -f "$STATE/npchange" && "$n" == allow-egress-dns ]] && s="changed"
    printf 'np-uid-%s\n{%s}' "$n" "$s"; exit 0;;
  "create --dry-run=server -f "*) echo "pod/route-host-probe (server dry run)"; exit 0;;
  "create -f "*" -o name")
    touch "$STATE/created"
    if [[ "$SCENARIO" == create_partial ]]; then touch "$STATE/gone-service-route-host-probe" "$STATE/gone-route-route-host-probe"; echo pod/route-host-probe; echo 'Error from server (Forbidden): services' >&2; exit 1; fi
    echo pod/route-host-probe; echo service/route-host-probe; echo route.route.openshift.io/route-host-probe; exit 0;;
  "$P get pod/route-host-probe -o jsonpath={.metadata.uid}"|"$P get service/route-host-probe -o jsonpath={.metadata.uid}"|"$P get route/route-host-probe -o jsonpath={.metadata.uid}")
    r="${a#"$P get "}"; r="${r%% *}"
    [[ -f "$STATE/created" && ! -f "$STATE/gone-${r//\//-}" ]] || { echo "Error from server (NotFound): $r" >&2; exit 1; }
    [[ "$SCENARIO" == create_partial && "$r" != pod/* ]] && { echo "Error from server (NotFound): $r" >&2; exit 1; }
    printf '%s' "$(uid_for "$r")"; exit 0;;
  "$P get pod/route-host-probe -o name"|"$P get service/route-host-probe -o name"|"$P get route/route-host-probe -o name")
    r="${a#"$P get "}"; r="${r%% *}"
    [[ -f "$STATE/gone-${r//\//-}" || ! -f "$STATE/created" ]] && { echo "Error from server (NotFound): $r" >&2; exit 1; }
    echo "$r"; exit 0;;
  "$P delete "*" --wait=true --timeout=120s")
    r="${a#"$P delete "}"; r="${r%% *}"
    [[ "$SCENARIO" == delete_fail && "$r" == route/* && ! -f "$STATE/delete-ok" ]] && { echo 'Error from server (InternalError)' >&2; exit 1; }
    touch "$STATE/gone-${r//\//-}"; echo "$r deleted"
    [[ -f "$STATE/gone-pod-route-host-probe" && -f "$STATE/gone-service-route-host-probe" && -f "$STATE/gone-route-route-host-probe" ]] && rm -f "$STATE/created"
    exit 0;;
  "$P wait --for=condition=Ready pod/route-host-probe --timeout="*) touch "$STATE/ready-done"; [[ "$SCENARIO" == not_ready ]] && { echo 'timed out' >&2; exit 1; }; echo 'condition met'; exit 0;;
  "$P get pod route-host-probe -o jsonpath="*)
    d="$IMG_DIGEST"; [[ "$SCENARIO" == digest_diff ]] && d="sha256:$(printf 'c%.0s' {1..64})"
    printf 'registry.access.redhat.com/ubi9/httpd-24@%s\tip-10-20-10-36' "$d"; exit 0;;
  "$P get route route-host-probe -o jsonpath="*)
    case "$SCENARIO" in
      not_admitted) printf '%s|%s|default|%s|False|HostAlreadyClaimed' "$HOST" "$HOST" "$CANON";;
      host_diff) printf '%s|other.apps.mock|default|%s|True|' "$HOST" "$CANON";;
      *) printf '%s|%s|default|%s|True|' "$HOST" "$HOST" "$CANON";;
    esac; exit 0;;
  "$P describe "*|"$P get endpoints "*|"$P get route route-host-probe -o yaml"|"$P get events "*) echo "diag"; exit 0;;
esac
echo "mock oc: unexpected: $a" >&2; exit 98
MOCK

cat >"$T/bin/getent" <<'MOCK'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >>"$CALLLOG"
case "$2" in
  fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com)
    [[ "$SCENARIO" == dns_nx ]] && exit 2
    [[ "$SCENARIO" == dns_diff ]] && { echo '198.51.100.9 STREAM x'; exit 0; }
    printf '203.0.113.10 STREAM %s\n203.0.113.10 DGRAM\n203.0.113.11 STREAM\n' "$2"; exit 0;;
  router-default.*) printf '203.0.113.11 STREAM %s\n203.0.113.10 STREAM\n' "$2"; exit 0;;
esac
exit 2
MOCK

cat >"$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLLOG"
for x in "$@"; do [[ "$x" == -k || "$x" == --insecure ]] && { echo "insecure flag used" >&2; exit 99; }; done
hdr=""; url=""; prev=""
for x in "$@"; do [[ "$prev" == -D ]] && hdr="$x"; prev="$x"; url="$x"; done
case "$url" in
  https://*)
    [[ "$SCENARIO" == tls_fail ]] && { echo 'curl: (60) SSL certificate problem: unable to get local issuer certificate' >&2; exit 60; }
    n=$(cat "$STATE/r3n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$STATE/r3n"
    if [[ "$SCENARIO" == backend_503 && $n -lt 2 ]]; then printf 'HTTP/1.1 503\r\n' >"$hdr"; printf '503 0'; exit 0; fi
    [[ "$SCENARIO" == https_200 ]] && { printf 'HTTP/1.1 200\r\n' >"$hdr"; printf '200 0'; exit 0; }
    printf 'HTTP/1.1 403 Forbidden\r\n' >"$hdr"; printf '403 0'; exit 0;;
  http://*)
    loc="https://fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com/"
    [[ "$SCENARIO" == redirect_wrong ]] && loc="https://other.example/"
    code=302; [[ "$SCENARIO" == redirect_none ]] && code=200
    printf 'HTTP/1.1 %s Found\r\nlocation: %s\r\n\r\n' "$code" "$loc" >"$hdr"; printf '%s' "$code"; exit 0;;
esac
exit 3
MOCK
cat >"$T/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
echo "subject=CN=*.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com"; exit 0
MOCK
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" ROUTE_POLL_S=0

PASS=0; FAIL=0
ok() { echo "PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $*"; FAIL=$((FAIL+1)); }
expect() { local want="$1" got="$2" name="$3"; [[ "$got" == "$want" ]] && ok "$name (rc=$got)" || bad "$name (rc=$got, want $want)"; }

base_env() { # name -> sets RD, STATE, CALLLOG
  RD="$T/$1/run"; export STATE="$T/$1/state" CALLLOG="$T/$1/calls.log"; mkdir -p "$STATE"; : >"$CALLLOG"
}
render() { RUN_DIR="$RD" NS=fds-app TEAM=321team ROUTE_HOST="$HOST" HTTP_IMAGE="$IMG" bash "$SCRIPT" render >"$T/$1.render.out" 2>&1; }
bundle() { sed -n 's/^RENDER_OK BUNDLE_SHA256=//p' "$T/$1.render.out"; }
pre() { RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" CTX=mock API=https://api.mock.invalid:6443 \
  EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555 EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
  bash "$SCRIPT" precheck >"$T/$1.pre.out" 2>&1; }
GO=https://github.com/321Team/fds-project-baseline/issues/38#issuecomment-1
SEVEN=https://github.com/321Team/infra-rosa/issues/7#issuecomment-2
runp() { RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" GO_REF="$GO" SEVEN_DONE_REF="$SEVEN" READY_TIMEOUT_S=5 ADMIT_TIMEOUT_S=1 DNS_TIMEOUT_S=1 HTTP_TIMEOUT_S=1 \
  bash "$SCRIPT" run >"$T/$1.run.out" 2>&1; }
clean() { RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" bash "$SCRIPT" cleanup >"$T/$1.clean.out" 2>&1; }
export IMG_DIGEST="${IMG#*@}"
scenario() { # name SCENARIO  → render+precheck(+run)
  base_env "$1"; export SCENARIO="$2"; render "$1"; B="$(bundle "$1")"
}
writes() { grep -v 'auth can-i' "$CALLLOG" | grep -cE '(^| )(create -f|delete |apply |patch |label |annotate |scale )' || true; }
result() { awk -F= -v k="$2" '$1==k {print $2}' "$RD/run/result.txt"; }

# 1. 정상 경로
scenario ok ok; set +e; pre ok; rc=$?; set -e; expect 0 "$rc" "precheck 정상"
[[ "$(writes)" == 0 ]] && ok "render·precheck는 쓰기 0 (dry-run만)" || bad "render·precheck 쓰기 발생"
grep -q 'create --dry-run=server' "$CALLLOG" && ok "precheck가 server dry-run 수행" || bad "dry-run 없음"
set +e; runp ok; rc=$?; set -e; expect 0 "$rc" "run 정상 R-1~R-5 PASS"
for id in CREATE READY R-1 R-2 R-3 R-4 R-5; do [[ "$(result ok "$id")" == PASS ]] || bad "정상: $id=$(result ok "$id")"; done
ok "정상: 결과 7항목 확인"
[[ -f "$RD/cleanup.done" ]] && grep -q 'INVENTORY RESTORED' "$RD/run/cleanup.txt" && grep -q 'PLATFORM_NP UNCHANGED' "$RD/run/cleanup.txt" \
  && ok "R-5: OWNED 3개 삭제·목록 복원·정책 불변" || bad "R-5 정리 기록"
[[ "$(grep -c $'\tOWNED\t' "$RD/run/created.tsv")" == 3 ]] && ok "created.tsv OWNED 3/3" || bad "OWNED 기록"
! grep '^curl ' "$CALLLOG" | grep -qE -- ' (-k|--insecure)( |$)' && ok "curl에 -k/--insecure 없음(TLS 검증 유지)" || bad "insecure 사용"
grep -q 'host: '"$HOST"'$' "$RD/manifests/route-host-probe.yaml" && grep -q 'route-exposed: "true"' "$RD/manifests/route-host-probe.yaml" \
  && grep -q 'targetPort: 8080' "$RD/manifests/route-host-probe.yaml" && ok "렌더: 승인 host·route-exposed·targetPort 8080" || bad "렌더 결속"
grep -q 'r3-cert' "$RD/run/commands.tsv" && ok "R-3 인증서 정보 기록(openssl)" || bad "R-3 인증서 정보 기록 없음"
set +e; runp ok; rc=$?; set -e; expect 30 "$rc" "같은 RUN에서 run 재실행 거부"
set +e; clean ok; rc=$?; set -e; expect 30 "$rc" "정리 완료 뒤 cleanup 재실행 거부"

# 2. precheck 거부들
for s in admin no_custom_host extra_obj np02_port cid_mismatch; do
  scenario "p-$s" "$s"; set +e; pre "p-$s"; rc=$?; set -e
  want=20; [[ "$s" == cid_mismatch ]] && want=10
  expect "$want" "$rc" "precheck 거부: $s"
  [[ "$(writes)" == 0 ]] || bad "precheck 거부($s) 중 쓰기 발생"
done
scenario p-cidf cid_forbidden; set +e; pre p-cidf; rc=$?; set -e; expect 0 "$rc" "Cluster ID Forbidden(일반 계정) → 기록 후 진행"
grep -q 'CLUSTER_ID_CHECK=UNREADABLE_FORBIDDEN' "$RD/target.env" && ok "target.env에 UNREADABLE_FORBIDDEN 기록" || bad "Forbidden 기록 없음"

# 3. run 실패 분기: 원본 진단 후 OWNED 정리, 종료 코드
for pair in not_admitted:50:R-1 host_diff:50:R-1 dns_nx:50:R-2 dns_diff:50:R-2 tls_fail:50:R-3 https_200:50:R-3 redirect_wrong:50:R-4 redirect_none:50:R-4 not_ready:41:READY digest_diff:41:READY; do
  s="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; id="${rest#*:}"
  scenario "r-$s" "$s"; pre "r-$s"; set +e; runp "r-$s"; rc=$?; set -e
  expect "$want" "$rc" "run 실패 분기: $s"
  [[ "$(result "r-$s" "$id")" == FAIL ]] && ok "$s: $id=FAIL" || bad "$s: $id=$(result "r-$s" "$id")"
  [[ -f "$RD/run/diag-describe.out" ]] && ok "$s: 정리 전 진단 원본 보존" || bad "$s: 진단 없음"
  [[ "$(result "r-$s" R-5)" == PASS && -f "$RD/cleanup.done" ]] && ok "$s: 실패해도 OWNED 정리 완료(R-5 PASS)" || bad "$s: 정리 안 됨"
done
scenario r-503 backend_503; pre r-503; set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" GO_REF="$GO" SEVEN_DONE_REF="$SEVEN" HTTP_TIMEOUT_S=30 \
  bash "$SCRIPT" run >"$T/r-503.run.out" 2>&1; rc=$?; set -e
expect 0 "$rc" "backend 503은 상한 안에서 다시 보고 403이면 PASS"
grep -q $'^curl .*https://' "$CALLLOG" && [[ "$(grep -c 'https://'"$HOST" "$CALLLOG")" -ge 2 ]] && ok "503 재확인 2회 이상" || bad "503 재확인"
scenario r-part create_partial; pre r-part; set +e; runp r-part; rc=$?; set -e
expect 41 "$rc" "생성 일부 실패 → 41"
[[ "$(grep -c $'\tOWNED\t' "$RD/run/created.tsv")" == 1 ]] && grep -q 'pod/route-host-probe DELETED' "$RD/run/cleanup.txt" \
  && ok "부분 생성: 만들어진 OWNED(pod)만 정리" || bad "부분 생성 정리"

# 4. 정리 HOLD: UID 불일치(이름만 같은 객체)는 지우지 않음 → 60
scenario h-uid ok; pre h-uid; export UID_SHIFT=1; set +e; runp h-uid; rc=$?; set -e; unset UID_SHIFT
expect 60 "$rc" "UID 불일치 → 정리 HOLD 60"
grep -q 'service/route-host-probe HOLD(UID 불일치' "$RD/run/cleanup.txt" && ! grep -q '^service/route-host-probe DELETED' "$RD/run/cleanup.txt" \
  && ok "UID 불일치 객체는 삭제하지 않음" || bad "UID 불일치 객체 삭제됨"
[[ ! -f "$RD/cleanup.done" ]] && ok "HOLD면 cleanup.done 없음(앱 배포 금지 상태)" || bad "HOLD인데 done"

# 5. 삭제 실패 → HOLD → 원인 해소 뒤 같은 RUN cleanup 재시도
scenario h-del delete_fail; pre h-del; set +e; runp h-del; rc=$?; set -e
expect 60 "$rc" "삭제 실패 → HOLD 60"
touch "$STATE/delete-ok"; set +e; clean h-del; rc=$?; set -e
expect 0 "$rc" "같은 RUN cleanup 재시도 성공"
[[ -d "$RD/cleanup-attempt-1" && -f "$RD/cleanup.done" ]] && ok "cleanup-attempt-1 기록·완료" || bad "재시도 기록"

# 6. precheck 뒤 목록 변화 → 생성 전 중단(쓰기 0)
scenario d-drift ok; pre d-drift; touch "$STATE/drift"; c0="$(writes)"; set +e; runp d-drift; rc=$?; set -e
expect 30 "$rc" "precheck 뒤 목록 변화 → 30"
[[ "$(writes)" == "$c0" ]] && ok "목록 변화 시 생성 없음" || bad "목록 변화인데 생성"
rm -f "$STATE/drift"

# 7. precheck 뒤 플랫폼 정책 변화 → 생성 전 중단
scenario n-np2 ok; pre n-np2; touch "$STATE/npchange"; set +e; runp n-np2; rc=$?; set -e
expect 30 "$rc" "precheck 뒤 정책 변화 → 생성 전 30"

# 8. 입력·순서 가드
base_env g; export SCENARIO=ok
set +e; RUN_DIR="$RD" NS=fds-app TEAM=321team ROUTE_HOST='*.apps.mock' HTTP_IMAGE="$IMG" bash "$SCRIPT" render >/dev/null 2>&1; rc=$?; set -e
expect 2 "$rc" "wildcard host 거부"
set +e; RUN_DIR="$RD" NS=fds-app TEAM=321team ROUTE_HOST="$HOST" HTTP_IMAGE=registry.access.redhat.com/ubi9/httpd-24:latest bash "$SCRIPT" render >/dev/null 2>&1; rc=$?; set -e
expect 2 "$rc" "digest 없는 이미지 거부"
set +e; RUN_DIR="$RD" NS=openshift-ingress TEAM=321team ROUTE_HOST="$HOST" HTTP_IMAGE="$IMG" bash "$SCRIPT" render >/dev/null 2>&1; rc=$?; set -e
expect 2 "$rc" "system namespace 거부"
scenario g2 ok; set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" GO_REF="$GO" SEVEN_DONE_REF="$SEVEN" bash "$SCRIPT" run >/dev/null 2>&1; rc=$?; set -e
expect 30 "$rc" "precheck 없이 run 거부"
pre g2; set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" SEVEN_DONE_REF="$SEVEN" bash "$SCRIPT" run >/dev/null 2>&1; rc=$?; set -e
expect 30 "$rc" "GO_REF 없으면 run 거부"
set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" GO_REF="$GO" bash "$SCRIPT" run >/dev/null 2>&1; rc=$?; set -e
expect 30 "$rc" "SEVEN_DONE_REF 없으면 run 거부"
set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$(printf '0%.0s' {1..64})" bash "$SCRIPT" precheck >/dev/null 2>&1; rc=$?; set -e
expect 21 "$rc" "승인 bundle 해시 불일치 거부"
chmod u+w "$RD/manifests/route-host-probe.yaml"; echo '# tamper' >>"$RD/manifests/route-host-probe.yaml"
set +e; RUN_DIR="$RD" APPROVED_BUNDLE_SHA256="$B" GO_REF="$GO" SEVEN_DONE_REF="$SEVEN" bash "$SCRIPT" run >/dev/null 2>&1; rc=$?; set -e
expect 21 "$rc" "렌더 manifest 변조 거부"
set +e; RUN_DIR="$T/g3/run" NS=fds-app TEAM=321team ROUTE_HOST="$HOST" HTTP_IMAGE="$IMG" bash "$SCRIPT" render >/dev/null 2>&1; set -e
B3="$(sha256sum "$T/g3/run/bundle.txt" | cut -d' ' -f1)"
set +e; RUN_DIR="$T/g3/run" APPROVED_BUNDLE_SHA256="$B3" CTX=mock API=https://api.other.invalid:6443 EXPECTED_CLUSTER_ID=11111111-2222-3333-4444-555555555555 \
  EXPECTED_NS_UID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee bash "$SCRIPT" precheck >/dev/null 2>&1; rc=$?; set -e
expect 10 "$rc" "CTX 서버 ≠ API → 첫 요청 전 중단"

echo "----"
if (( FAIL )); then echo "route-test-mock: $FAIL FAIL / $PASS PASS"; exit 1; fi
echo "route-test-mock: ALL PASS ($PASS)"
