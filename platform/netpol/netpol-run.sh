#!/usr/bin/env bash
# infra-rosa#7 — NetworkPolicy·Egress·Hybrid Route TCP 시험 실행기 (ROSA 생성 후 키트)
#
# 사용: netpol-run.sh <render|precheck|stage-b|stage-a|cleanup>
#   단계마다 따로 실행한다. baseline#37 단계 C·D(이재환)와의 끼워 넣기 순서는 RUN-KIT.md.
#
#   render    로컬만(oc 호출 없음). 00~03·10~12 자리표시자를 승인 입력으로 채우고 SHA256SUMS를 만든다.
#   precheck  읽기 + server dry-run만(클러스터 변경 없음). 대상 확인, Worker IP가 WORKER_CIDR 안인지,
#             OVN·router 라벨·DNS 포트, 대상 Namespace가 비어 있는지(NetworkPolicy·workload 0개).
#   stage-b   시험 자원(10·11·12) 생성 → 정책 전(B) 측정. #37 단계 C·T3 기록 링크가 있어야 시작한다.
#   stage-a   플랫폼 정책 00→01→02→03 적용 → 정책 후(A) 측정 → Handoff 8·9.
#   cleanup   이 RUN이 만든 시험 자원만 UID 대조 후 삭제. 00~03은 남기고 UID·spec이 그대로인지 확인한다.
#
# 하지 않는 것: 기존 NetworkPolicy·workload 삭제/수정, route·Relay·db01 조회/변경, 자동 재시도·자동 원복,
#   00~03 삭제, 디렉터리 일괄 delete. 한 단계는 RUN_DIR 안에서 한 번만 실행된다(재실행은 새 RUN_DIR).
#
# 공통 입력: RUN_DIR (render는 없어야 함, 나머지는 render가 만든 것)
# 클러스터 단계 입력: CTX, API(https://host[:port]), EXPECTED_CLUSTER_ID, EXPECTED_NS_UID,
#                     APPROVED_RENDER_SUMS_SHA256 (render 출력값을 리뷰로 승인한 값)
# render 입력: NS, TEAM, DB_IP, DB_PORT, REG_MODE=none|include (include면 REG_IP, REG_PORT),
#              TEST_IMAGE, HTTP_IMAGE (<registry>/<repo>@sha256:<64hex>)
# precheck 선택: WORKER_CIDR (기본 10.20.10.0/24 = private_a, db01 사전 창 허용 출발지)
# stage-b 입력: STAGE_C_REF (단계 C 상시 터널·Route ON 기록), T3_REF (단계 D T3 PASS 기록),
#               DB_WINDOW_REF (db01 사전 창 pre-apply 기록) — 모두 GitHub 댓글 URL
#               N3_TARGET=<ip>:<port> (승인 밖 On-Prem 대상)
#   선택: N2_PORT (기본 22), N4_TARGET (기본 1.1.1.1:443)
# stage-a 선택: POD_MAX_AGE_MIN (기본 50; 시험 Pod는 sleep 3600), R1_EXPECTED_CODES (기본 "200")
#
# 종료 코드:
#   0  단계 성공          2  입력 오류(oc 호출 전)       10 대상 불일치(서버/Cluster ID/NS UID)
#   11 조회 오류          20 precheck 조건 불충족       21 렌더 자리표시자 남음·렌더 해시 불일치
#   30 단계 순서·시각 조건 위반(이전 단계 없음, 이미 실행됨, Pod 수명 초과)
#   40 B 기준 불성립(P1·N1·N5·P3 기대값 아님) — 정책 시험으로 넘어가지 않음
#   41 apply·Ready 실패      42 A 정책 집합/00 spec이 계약과 다름
#   50 A 판정 FAIL(기대와 반대)  51 A 판정 불가(REFUSED/UNREACHABLE/TOOL_ERROR)
#   60 cleanup HOLD(UID 불일치·조회 오류·삭제 실패·00~03 변화)
set -euo pipefail
umask 077

die() { local rc="$1"; shift; echo "STOP: $*" >&2; exit "$rc"; }

PHASE="${1:-}"
case "$PHASE" in render|precheck|stage-b|stage-a|cleanup) ;; *) die 2 "사용: $0 <render|precheck|stage-b|stage-a|cleanup>";; esac

for c in sha256sum date awk sed grep sort cmp realpath mkdir; do command -v "$c" >/dev/null || die 2 "명령 없음: $c"; done

SELF="$(realpath "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "$SELF")"
SELF_SHA="$(sha256sum "$SELF" | cut -d' ' -f1)"
RUN_DIR="${RUN_DIR:-}"
[[ -n "$RUN_DIR" && "$RUN_DIR" != *$'\n'* ]] || die 2 "RUN_DIR 필요"

IPV4_RE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
IMG_RE='^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[0-9a-f]{64}$'
REF_RE='^https://github\.com/321Team/[A-Za-z0-9._-]+/(issues|pull)/[0-9]+#issuecomment-[0-9]+$'
SHA_RE='^[0-9a-f]{64}$'

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_target() { [[ "$1" == *:* ]] && [[ "${1%:*}" =~ $IPV4_RE ]] && is_port "${1##*:}"; }
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
in_cidr() { # ip cidr
  local net="${2%/*}" bits="${2#*/}" mask
  (( bits >= 0 && bits <= 32 )) || return 1
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip2int "$1") & mask) == ($(ip2int "$net") & mask) ))
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_kst() { TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z; }

st() { sed -n "s/^$1=//p" "$RUN_DIR/state.env" | tail -n 1; }
st_add() { printf '%s=%s\n' "$1" "$2" >>"$RUN_DIR/state.env"; }

# 단계별 기록 폴더. 이미 있으면 그 단계는 실행된 것이므로 거부한다.
PD=""
open_phase() {
  PD="$RUN_DIR/$PHASE"
  mkdir -m 700 -- "$PD" 2>/dev/null || die 30 "$PHASE 기록 폴더가 이미 있음(같은 RUN에서 재실행 금지 — 새 RUN_DIR로 render부터)"
  printf 'phase=%s\nstart_utc=%s\nstart_kst=%s\nkit_sha256=%s\n' "$PHASE" "$(now_utc)" "$(now_kst)" "$SELF_SHA" >"$PD/phase.txt"
  trap 'rc=$?; echo "end_utc=$(now_utc) rc=$rc" >>"$PD/phase.txt"; [[ $rc -ne 0 ]] && echo "RESULT_RC=$rc; 보존: $PD" >&2' EXIT
}

run() {
  local name="$1"; shift
  local start rc; start="$(now_utc)"
  set +e
  "$@" >"$PD/$name.out" 2>"$PD/$name.err"
  rc=$?
  set -e
  echo "$rc" >"$PD/$name.rc"
  printf '%s\t%s\t%s\t%s\n' "$start" "$(now_utc)" "$rc" "$name" >>"$PD/commands.tsv"
  return 0
}
rc_of() { cat "$PD/$1.rc"; }
out_of() { cat "$PD/$1.out"; }

# ======================================================================
if [[ "$PHASE" == render ]]; then
  NS="${NS:-}"; TEAM="${TEAM:-}"; DB_IP="${DB_IP:-}"; DB_PORT="${DB_PORT:-}"
  REG_MODE="${REG_MODE:-}"; REG_IP="${REG_IP:-}"; REG_PORT="${REG_PORT:-}"
  TEST_IMAGE="${TEST_IMAGE:-}"; HTTP_IMAGE="${HTTP_IMAGE:-}"
  (( ${#NS} <= 63 )) && [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 2 "NS는 DNS-1123 label"
  [[ ! "$NS" =~ ^(openshift|kube)(-|$) && "$NS" != default ]] || die 2 "System namespace는 대상 아님"
  [[ "$TEAM" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 2 "TEAM 형식 오류"
  [[ "$DB_IP" =~ $IPV4_RE ]] && is_port "$DB_PORT" || die 2 "DB_IP/DB_PORT 형식 오류(IF-18 승인값)"
  case "$REG_MODE" in
    none) REG_IP=""; REG_PORT="" ;;
    include) [[ "$REG_IP" =~ $IPV4_RE ]] && is_port "$REG_PORT" || die 2 "REG_IP/REG_PORT 형식 오류(D22 승인값)" ;;
    *) die 2 "REG_MODE=none|include (D22 결정)" ;;
  esac
  [[ "$TEST_IMAGE" =~ $IMG_RE && "$HTTP_IMAGE" =~ $IMG_RE ]] || die 2 "TEST_IMAGE/HTTP_IMAGE는 @sha256:<64hex> 고정"
  [[ ! -e "$RUN_DIR" ]] || die 2 "RUN_DIR이 이미 있음(덮어쓰지 않음)"
  mkdir -p -m 700 -- "$RUN_DIR"
  RUN_DIR="$(realpath "$RUN_DIR")"
  open_phase
  R="$RUN_DIR/manifests"; mkdir -m 700 "$R"
  for n in 00 01 02 03 10 11 12; do
    set -- "$SRC_DIR"/$n-*.yaml
    [[ $# -eq 1 && -f "$1" ]] || die 2 "source $n-*.yaml가 정확히 1개가 아님"
    src="$1"
    if [[ "$n" == 03 && "$REG_MODE" == none ]]; then
      awk '/# IF-19/{exit} {print}' "$src"
    else
      cat "$src"
    fi | sed -e "s|__NS__|$NS|g" -e "s|__TEAM__|$TEAM|g" \
             -e "s|__APPROVED_DB_IP__|$DB_IP|g" -e "s|__APPROVED_DB_PORT__|$DB_PORT|g" \
             -e "s|__APPROVED_REG_IP__|$REG_IP|g" -e "s|__APPROVED_REG_PORT__|$REG_PORT|g" \
             -e "s|__TEST_IMAGE__|$TEST_IMAGE|g" -e "s|__HTTP_IMAGE__|$HTTP_IMAGE|g" >"$R/$n.yaml"
    printf '%s\t%s\n' "$n" "$(sha256sum "$src" | cut -d' ' -f1)" >>"$PD/source-sha.tsv"
  done
  # 자리표시자는 주석까지 포함해 하나도 남기지 않는다(03 주석의 설명 문구는 실제 값으로 바뀐다).
  if grep -n '__[A-Z_]*__' "$R"/*.yaml >"$PD/placeholder-left.txt"; then die 21 "자리표시자 남음: $PD/placeholder-left.txt"; fi
  grep -q "cidr: $DB_IP/32" "$R/03.yaml" && grep -q "port: $DB_PORT }" "$R/03.yaml" || die 21 "03에 IF-18 규칙이 없음"
  if [[ "$REG_MODE" == none ]]; then
    [[ "$(grep -c 'ipBlock:' "$R/03.yaml")" == 1 ]] || die 21 "REG_MODE=none인데 03에 IF-18 외 ipBlock이 남음"
  else
    grep -q "cidr: $REG_IP/32" "$R/03.yaml" || die 21 "03에 IF-19 규칙이 없음"
  fi
  ( cd "$R" && sha256sum 00.yaml 01.yaml 02.yaml 03.yaml 10.yaml 11.yaml 12.yaml >SHA256SUMS )
  SUMS_SHA="$(sha256sum "$R/SHA256SUMS" | cut -d' ' -f1)"
  {
    echo "NS=$NS"; echo "TEAM=$TEAM"; echo "DB_IP=$DB_IP"; echo "DB_PORT=$DB_PORT"
    echo "REG_MODE=$REG_MODE"; echo "REG_IP=$REG_IP"; echo "REG_PORT=$REG_PORT"
    echo "TEST_IMAGE=$TEST_IMAGE"; echo "HTTP_IMAGE=$HTTP_IMAGE"
    echo "RENDER_SUMS_SHA256=$SUMS_SHA"; echo "KIT_SHA256=$SELF_SHA"
    echo "SOURCE_GIT_HEAD=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "RENDERED_AT_KST=$(now_kst)"
  } >"$RUN_DIR/state.env"
  echo "RENDER_OK RENDER_SUMS_SHA256=$SUMS_SHA"
  echo "다음: 이 값을 리뷰로 승인받은 뒤 APPROVED_RENDER_SUMS_SHA256로 precheck 실행"
  exit 0
fi

# ======================================================================
# 클러스터 단계 공통: 입력·RUN·렌더 무결성·대상 확인
command -v oc >/dev/null || die 2 "명령 없음: oc"
[[ -d "$RUN_DIR" && -f "$RUN_DIR/state.env" ]] || die 30 "RUN_DIR에 render 결과가 없음(render 먼저)"
RUN_DIR="$(realpath "$RUN_DIR")"
CTX="${CTX:-}"; API="${API:-}"
EXPECTED_CLUSTER_ID="${EXPECTED_CLUSTER_ID:-}"; EXPECTED_NS_UID="${EXPECTED_NS_UID:-}"
APPROVED_RENDER_SUMS_SHA256="${APPROVED_RENDER_SUMS_SHA256:-}"
[[ -n "$CTX" && "$CTX" != *$'\n'* ]] || die 2 "CTX 필요"
[[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die 2 "API는 https://host[:port]"
[[ "$EXPECTED_CLUSTER_ID" =~ $UUID_RE && "$EXPECTED_NS_UID" =~ $UUID_RE ]] || die 2 "EXPECTED_CLUSTER_ID/EXPECTED_NS_UID는 승인 inventory의 UUID"
[[ "$APPROVED_RENDER_SUMS_SHA256" =~ $SHA_RE ]] || die 2 "APPROVED_RENDER_SUMS_SHA256 필요(64hex)"
NS="$(st NS)"; DB_IP="$(st DB_IP)"; DB_PORT="$(st DB_PORT)"; REG_MODE="$(st REG_MODE)"
REG_IP="$(st REG_IP)"; REG_PORT="$(st REG_PORT)"
R="$RUN_DIR/manifests"

case "$PHASE" in
  precheck) : ;;
  stage-b) [[ -f "$RUN_DIR/precheck.ok" ]] || die 30 "precheck PASS 기록 없음" ;;
  stage-a) [[ -f "$RUN_DIR/stage-b.ok" ]] || die 30 "stage-b PASS 기록 없음(B 기준 없이 정책 적용 금지)" ;;
  cleanup) [[ -f "$RUN_DIR/stage-b/created.tsv" ]] || die 30 "이 RUN이 만든 자원 기록 없음(정리할 것 없음)" ;;
esac

# stage-b 전용 입력은 oc 호출 전에 검사한다.
if [[ "$PHASE" == stage-b ]]; then
  STAGE_C_REF="${STAGE_C_REF:-}"; T3_REF="${T3_REF:-}"; DB_WINDOW_REF="${DB_WINDOW_REF:-}"
  N3_TARGET="${N3_TARGET:-}"; N2_PORT="${N2_PORT:-22}"; N4_TARGET="${N4_TARGET:-1.1.1.1:443}"
  for v in STAGE_C_REF T3_REF DB_WINDOW_REF; do [[ "${!v}" =~ $REF_RE ]] || die 30 "$v 필요(#37 단계 C·D 기록 댓글 URL) — 없으면 시작하지 않음"; done
  is_target "$N3_TARGET" || die 2 "N3_TARGET=<ip>:<port> 필요(승인 밖 On-Prem 대상)"
  [[ "${N3_TARGET%:*}" != "$DB_IP" && "${N3_TARGET%:*}" != "$REG_IP" ]] || die 2 "N3_TARGET이 승인 대상과 같음"
  is_port "$N2_PORT" && [[ "$N2_PORT" != "$DB_PORT" ]] || die 2 "N2_PORT 형식 오류 또는 승인 포트와 같음"
  is_target "$N4_TARGET" || die 2 "N4_TARGET=<ip>:<port>"
fi

open_phase

( cd "$R" && sha256sum -c --quiet SHA256SUMS ) >"$PD/render-check.txt" 2>&1 || die 21 "렌더 파일이 SHA256SUMS와 다름"
NOW_SUMS="$(sha256sum "$R/SHA256SUMS" | cut -d' ' -f1)"
[[ "$NOW_SUMS" == "$(st RENDER_SUMS_SHA256)" && "$NOW_SUMS" == "$APPROVED_RENDER_SUMS_SHA256" ]] \
  || die 21 "렌더 SHA256SUMS 해시가 승인값과 다름"

run ctx-server oc config view --minify --context="$CTX" -o 'jsonpath={.clusters[0].cluster.server}'
[[ "$(rc_of ctx-server)" == 0 && "$(out_of ctx-server)" == "$API" ]] || die 10 "CTX의 서버가 API와 다름(첫 API 요청 전 중단)"
OC=(oc --context="$CTX" --server="$API" --insecure-skip-tls-verify=false)
run cluster-id "${OC[@]}" get clusterversion version -o 'jsonpath={.spec.clusterID}'
[[ "$(rc_of cluster-id)" == 0 && "$(out_of cluster-id)" == "$EXPECTED_CLUSTER_ID" ]] || die 10 "Cluster ID가 승인 inventory와 다르거나 조회 불가"
run ns-uid "${OC[@]}" get namespace "$NS" -o 'jsonpath={.metadata.uid}'
[[ "$(rc_of ns-uid)" == 0 && "$(out_of ns-uid)" == "$EXPECTED_NS_UID" ]] || die 10 "Namespace UID가 승인 inventory와 다르거나 조회 불가"
run whoami "${OC[@]}" whoami
{
  echo "ENV=ROSA"; echo "PHASE=$PHASE"; echo "KST=$(now_kst)"; echo "CTX=$CTX"; echo "API=$API"
  echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID"; echo "NS=$NS"; echo "NAMESPACE_UID=$EXPECTED_NS_UID"
  echo "RENDER_SUMS_SHA256=$NOW_SUMS"; echo "KIT_SHA256=$SELF_SHA"
  echo "WHOAMI_RC=$(rc_of whoami) WHOAMI=$(out_of whoami)"
} >"$PD/context.txt"

# ---- 시험 함수 ----
probe() { # stage id pod ip port
  local stage="$1" id="$2" pod="$3" ip="$4" port="$5" t0 rc v f="$PD/probe-$2"
  t0="$(now_utc)"
  set +e
  "${OC[@]}" -n "$NS" exec "$pod" -c probe -- timeout 5 bash -c "</dev/tcp/$ip/$port" >"$f.out" 2>"$f.err"
  rc=$?
  set -e
  if (( rc == 0 )); then v=CONNECTED
  elif (( rc == 124 )); then v=TIMEOUT
  elif grep -qi 'connection refused' "$f.err"; then v=REFUSED
  elif grep -qi 'no route to host' "$f.err"; then v=UNREACHABLE
  else v=TOOL_ERROR; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s:%s\t%s\t%s\n' "$stage" "$id" "$t0" "$(now_utc)" "$pod" "$ip" "$port" "$rc" "$v" >>"$PD/results.tsv"
}
dns_probe() { # stage
  local t0 rc; t0="$(now_utc)"
  set +e
  "${OC[@]}" -n "$NS" exec tcp-allowed -c probe -- getent hosts kubernetes.default.svc.cluster.local >"$PD/probe-P3.out" 2>"$PD/probe-P3.err"
  rc=$?
  set -e
  printf '%s\tP3\t%s\t%s\ttcp-allowed\tdns:kubernetes.default\t%s\t%s\n' "$1" "$t0" "$(now_utc)" "$rc" "$([[ $rc == 0 ]] && echo OK || echo FAIL)" >>"$PD/results.tsv"
}
verdict() { awk -F'\t' -v id="$1" '$2==id {v=$8} END {print v}' "$PD/results.tsv"; }

FAILS=(); INCONCL=()
expect() { # id expected
  local got; got="$(verdict "$1")"
  [[ "$got" == "$2" ]] && return 0
  if [[ "$2" == TIMEOUT && "$got" != CONNECTED ]]; then INCONCL+=("$1:$got"); else FAILS+=("$1:$got(기대 $2)"); fi
}

measure() { # stage
  local s="$1" n3ip n3port n4ip n4port pod_ip
  n3ip="${N3_TARGET%:*}"; n3port="${N3_TARGET##*:}"; n4ip="${N4_TARGET%:*}"; n4port="${N4_TARGET##*:}"
  probe "$s" P1 tcp-allowed "$DB_IP" "$DB_PORT"
  [[ "$REG_MODE" == include ]] && probe "$s" P2 tcp-allowed "$REG_IP" "$REG_PORT"
  dns_probe "$s"
  probe "$s" N1 tcp-control "$DB_IP" "$DB_PORT"
  probe "$s" N2 tcp-allowed "$DB_IP" "$N2_PORT"
  probe "$s" N3 tcp-allowed "$n3ip" "$n3port"
  probe "$s" N4 tcp-allowed "$n4ip" "$n4port"
  pod_ip="$(cat "$RUN_DIR/stage-b/route-probe-ip.txt")"
  probe "$s" N5 ingress-probe "$pod_ip" 8080
}

# ======================================================================
if [[ "$PHASE" == precheck ]]; then
  WORKER_CIDR="${WORKER_CIDR:-10.20.10.0/24}"
  [[ "${WORKER_CIDR%/*}" =~ $IPV4_RE && "${WORKER_CIDR#*/}" =~ ^[0-9]{1,2}$ ]] || die 2 "WORKER_CIDR 형식 오류"
  P=(); F=()
  # C1 — Worker InternalIP 전부 WORKER_CIDR 안(Pod egress는 Worker IP로 SNAT, db01 사전 창은 이 대역만 허용)
  run nodes "${OC[@]}" get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}{"\n"}{end}'
  [[ "$(rc_of nodes)" == 0 ]] || die 11 "nodes 조회 실패"
  n=0
  while IFS=$'\t' read -r name ips; do
    [[ -n "$name" ]] || continue
    ips="${ips% }"; n=$((n+1))
    [[ "$ips" =~ $IPV4_RE ]] || { F+=("C1:$name InternalIP 1개 IPv4 아님($ips)"); continue; }
    in_cidr "$ips" "$WORKER_CIDR" || F+=("C1:$name $ips ∉ $WORKER_CIDR")
  done <"$PD/nodes.out"
  (( n > 0 )) || F+=("C1:노드 0개")
  # C3 — OVNKubernetes
  run network "${OC[@]}" get network.config cluster -o 'jsonpath={.status.networkType}'
  [[ "$(rc_of network)" == 0 ]] || die 11 "network.config 조회 실패"
  [[ "$(out_of network)" == OVNKubernetes ]] || F+=("C3:networkType=$(out_of network)")
  # C4 — router Namespace 라벨(02가 이 라벨로 진입을 연다)
  run ingress-ns "${OC[@]}" get namespace -l policy-group.network.openshift.io/ingress -o name
  [[ "$(rc_of ingress-ns)" == 0 ]] || die 11 "ingress namespace 조회 실패"
  grep -qx 'namespace/openshift-ingress' "$PD/ingress-ns.out" || F+=("C4:openshift-ingress에 policy-group 라벨 없음")
  # C5 — DNS Pod 포트 5353(01)
  run dns-ports "${OC[@]}" -n openshift-dns get pods -o 'jsonpath={..containerPort}'
  [[ "$(rc_of dns-ports)" == 0 ]] || die 11 "openshift-dns 조회 실패"
  grep -qw 5353 "$PD/dns-ports.out" || F+=("C5:DNS Pod 포트에 5353 없음")
  # 대상 Namespace가 비어 있어야 B단계가 성립(허용 정책은 합산, 기존 workload는 혼입)
  run ns-inventory "${OC[@]}" -n "$NS" get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name
  [[ "$(rc_of ns-inventory)" == 0 ]] || die 11 "Namespace inventory 조회 실패"
  [[ ! -s "$PD/ns-inventory.out" ]] || F+=("NS:대상 Namespace가 비어 있지 않음($(tr '\n' ' ' <"$PD/ns-inventory.out"))")
  # server dry-run(변경 없음): 렌더본이 실제 API·admission을 통과하는지
  for n in 00 01 02 03 10 11 12; do
    run "dryrun-$n" "${OC[@]}" apply --dry-run=server -f "$R/$n.yaml" -o name
    [[ "$(rc_of "dryrun-$n")" == 0 ]] || F+=("DRYRUN:$n.yaml rc=$(rc_of "dryrun-$n")")
  done
  printf 'WORKER_CIDR=%s\nWORKER_COUNT=%s\n' "$WORKER_CIDR" "$n" >>"$PD/context.txt"
  if (( ${#F[@]} )); then printf '%s\n' "${F[@]}" >"$PD/stop.txt"; die 20 "precheck 조건 불충족: $(tr '\n' ';' <"$PD/stop.txt")"; fi
  st_add WORKER_CIDR "$WORKER_CIDR"; st_add C1 PASS
  touch "$RUN_DIR/precheck.ok"
  echo "PRECHECK_OK workers=$n cidr=$WORKER_CIDR (클러스터 변경 없음)"
  exit 0
fi

# ======================================================================
if [[ "$PHASE" == stage-b ]]; then
  { echo "STAGE_C_REF=$STAGE_C_REF"; echo "T3_REF=$T3_REF"; echo "DB_WINDOW_REF=$DB_WINDOW_REF"
    echo "N2_PORT=$N2_PORT"; echo "N3_TARGET=$N3_TARGET"; echo "N4_TARGET=$N4_TARGET"; } >>"$RUN_DIR/state.env"
  # 시작 직전 다시: 대상 Namespace가 비어 있는지(precheck 이후 혼입)
  run ns-inventory "${OC[@]}" -n "$NS" get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name
  [[ "$(rc_of ns-inventory)" == 0 ]] || die 11 "Namespace inventory 조회 실패"
  [[ ! -s "$PD/ns-inventory.out" ]] || die 20 "precheck 이후 대상 Namespace에 자원이 생김 — 변경 없이 STOP"
  echo "#7 stage-b 시작 $(now_kst) — 재환 님께 카운터 기록 시작 요청 시각" | tee "$PD/notice.txt"
  for n in 10 11 12; do
    run "apply-$n" "${OC[@]}" apply -f "$R/$n.yaml" -o name
    [[ "$(rc_of "apply-$n")" == 0 ]] || die 41 "$n.yaml apply 실패(자동 원복 없음 — cleanup 단계로 이 RUN 자원만 정리)"
  done
  # 만든 자원의 이름·UID 기록(cleanup은 이 값과 같은 것만 지운다)
  for r in pod/tcp-allowed pod/tcp-control pod/route-probe pod/ingress-probe service/route-probe route/route-probe networkpolicy/probe-egress-to-route; do
    run "uid-${r//\//-}" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
    [[ "$(rc_of "uid-${r//\//-}")" == 0 && "$(out_of "uid-${r//\//-}")" =~ $UUID_RE ]] || die 41 "$r UID 조회 실패"
    printf '%s\t%s\n' "$r" "$(out_of "uid-${r//\//-}")" >>"$PD/created.tsv"
  done
  run wait "${OC[@]}" -n "$NS" wait --for=condition=Ready pod/tcp-allowed pod/tcp-control pod/route-probe pod/ingress-probe --timeout=180s
  [[ "$(rc_of wait)" == 0 ]] || die 41 "시험 Pod Ready 실패(180초)"
  run route-probe-ip "${OC[@]}" -n "$NS" get pod route-probe -o 'jsonpath={.status.podIP}'
  [[ "$(rc_of route-probe-ip)" == 0 && "$(out_of route-probe-ip)" =~ $IPV4_RE ]] || die 11 "route-probe Pod IP 조회 실패"
  out_of route-probe-ip >"$PD/route-probe-ip.txt"
  measure B
  # B 기준: 정책이 없을 때 승인 경로·대조 Pod·Pod 간 진입·DNS가 열려 있어야 A의 차단을 정책 효과로 본다.
  for id in P1 N1 N5; do [[ "$(verdict "$id")" == CONNECTED ]] || FAILS+=("$id:$(verdict "$id")(기대 CONNECTED)"); done
  [[ "$REG_MODE" != include || "$(verdict P2)" == CONNECTED ]] || FAILS+=("P2:$(verdict P2)(기대 CONNECTED)")
  [[ "$(verdict P3)" == OK ]] || FAILS+=("P3:DNS FAIL")
  echo "#7 stage-b 측정 끝 $(now_kst)" | tee -a "$PD/notice.txt"
  if (( ${#FAILS[@]} )); then
    printf '%s\n' "${FAILS[@]}" >"$PD/stop.txt"
    die 40 "B 기준 불성립 — 정책 시험으로 넘어가지 않음: $(tr '\n' ';' <"$PD/stop.txt") (경로·#37 T3 상태 확인, cleanup으로 시험 자원 정리)"
  fi
  touch "$RUN_DIR/stage-b.ok"
  echo "STAGE_B_OK — 이어서 stage-a (시험 Pod 수명 안에)"
  exit 0
fi

# ======================================================================
if [[ "$PHASE" == stage-a ]]; then
  POD_MAX_AGE_MIN="${POD_MAX_AGE_MIN:-50}"; R1_EXPECTED_CODES="${R1_EXPECTED_CODES:-200}"
  [[ "$POD_MAX_AGE_MIN" =~ ^[0-9]+$ ]] && (( POD_MAX_AGE_MIN >= 1 && POD_MAX_AGE_MIN <= 55 )) || die 2 "POD_MAX_AGE_MIN 1~55"
  [[ "$R1_EXPECTED_CODES" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || die 2 "R1_EXPECTED_CODES 형식: 200 또는 200,403"
  N2_PORT="$(st N2_PORT)"; N3_TARGET="$(st N3_TARGET)"; N4_TARGET="$(st N4_TARGET)"
  # 시험 Pod는 sleep 3600 + restartPolicy Never. 수명 끝에 걸리면 A 결과가 Pod 종료와 섞인다.
  for p in tcp-allowed tcp-control ingress-probe; do
    run "age-$p" "${OC[@]}" -n "$NS" get pod "$p" -o 'jsonpath={.metadata.uid} {.metadata.creationTimestamp}'
    [[ "$(rc_of "age-$p")" == 0 ]] || die 11 "$p 조회 실패"
    read -r uid ts <"$PD/age-$p.out" || true
    grep -qx "pod/$p"$'\t'"$uid" "$RUN_DIR/stage-b/created.tsv" || die 30 "$p UID가 stage-b 기록과 다름(재생성 혼입)"
    age=$(( ( $(date -u +%s) - $(date -u -d "$ts" +%s) ) / 60 ))
    (( age < POD_MAX_AGE_MIN )) || die 30 "$p 생성 후 ${age}분 — 수명 한도 ${POD_MAX_AGE_MIN}분 이상(새 RUN으로 다시)"
  done
  echo "#7 stage-a 정책 적용 시작 $(now_kst) — 00 적용~03 적용 사이 DB 경로가 잠깐 막힘(의도)" | tee "$PD/notice.txt"
  for n in 00 01 02 03; do
    run "apply-$n" "${OC[@]}" apply -f "$R/$n.yaml" -o name
    [[ "$(rc_of "apply-$n")" == 0 ]] || die 41 "$n.yaml apply 실패 — 이미 적용된 정책은 그대로 두고 보고(자동 원복 없음)"
  done
  # 정책 집합이 정확히 이 시험의 5개인지(다른 실행자의 allow 정책 혼입 탐지)
  run np-list "${OC[@]}" -n "$NS" get networkpolicy -o name
  [[ "$(rc_of np-list)" == 0 ]] || die 11 "NetworkPolicy 목록 조회 실패"
  printf '%s\n' networkpolicy.networking.k8s.io/{allow-egress-dns,allow-egress-onprem-approved,allow-ingress-from-router,fds-platform-default-deny,probe-egress-to-route} >"$PD/np-expected.txt"
  sort "$PD/np-list.out" >"$PD/np-list.sorted"
  cmp -s "$PD/np-list.sorted" "$PD/np-expected.txt" || die 42 "NetworkPolicy 집합이 계약 5개와 다름(np-list.sorted)"
  # 00은 이름이 아니라 실제 spec으로: 모든 Pod 선택 + Ingress·Egress 기본 차단, 허용 규칙 없음
  run np00-spec "${OC[@]}" -n "$NS" get networkpolicy fds-platform-default-deny -o 'jsonpath={.spec.podSelector}|{.spec.policyTypes}|{.spec.ingress}|{.spec.egress}'
  [[ "$(rc_of np00-spec)" == 0 && "$(out_of np00-spec)" == '{}|["Ingress","Egress"]||' ]] || die 42 "00 spec이 기본 차단 계약과 다름: $(out_of np00-spec)"
  for np in fds-platform-default-deny allow-egress-dns allow-ingress-from-router allow-egress-onprem-approved; do
    run "np-$np" "${OC[@]}" -n "$NS" get networkpolicy "$np" -o 'jsonpath={.metadata.uid}{"\n"}{.spec}'
    [[ "$(rc_of "np-$np")" == 0 ]] || die 11 "$np 조회 실패"
    printf '%s\t%s\t%s\n' "$np" "$(head -n 1 "$PD/np-$np.out")" "$(tail -n +2 "$PD/np-$np.out" | sha256sum | cut -d' ' -f1)" >>"$PD/np-applied.tsv"
  done
  run np-yaml "${OC[@]}" -n "$NS" get networkpolicy -o yaml
  measure A
  # R1(클러스터 밖=실행 위치에서) / R2(Admitted)
  run route-host "${OC[@]}" -n "$NS" get route route-probe -o 'jsonpath={.spec.host}'
  HOST="$(out_of route-host)"
  r1_code=000; r1_tls=NOT_RUN
  if [[ "$(rc_of route-host)" == 0 && "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] && command -v curl >/dev/null; then
    run r1 curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOST/"
    if [[ "$(rc_of r1)" == 0 ]]; then r1_code="$(out_of r1)"; r1_tls=VERIFIED
    else
      run r1-insecure curl -sSk -o /dev/null -w '%{http_code}' --max-time 15 "https://$HOST/"
      r1_code="$(out_of r1-insecure)"; r1_tls="UNVERIFIED(curl rc=$(rc_of r1))"
    fi
  fi
  printf 'A\tR1\t%s\t%s\trunner\thttps://%s/\t%s\t%s\n' "$(now_utc)" "$(now_utc)" "$HOST" "$r1_tls" "$r1_code" >>"$PD/results.tsv"
  run r2 "${OC[@]}" -n "$NS" get route route-probe -o 'jsonpath={.status.ingress[0].conditions[?(@.type=="Admitted")].status}'
  printf 'A\tR2\t%s\t%s\t-\troute/route-probe\t%s\t%s\n' "$(now_utc)" "$(now_utc)" "$(rc_of r2)" "$(out_of r2)" >>"$PD/results.tsv"
  echo "#7 stage-a 측정 끝 $(now_kst) — 재환 님께 #7 종료 통보 후 T6 진행" | tee -a "$PD/notice.txt"

  expect P1 CONNECTED
  [[ "$REG_MODE" == include ]] && expect P2 CONNECTED
  [[ "$(verdict P3)" == OK ]] || FAILS+=("P3:DNS FAIL")
  # NetworkPolicy 효과는 B CONNECTED → A TIMEOUT일 때만 주장한다.
  # N2~N4는 B에서 이미 막힐 수 있다(예: Relay SG가 worker 서브넷에서 5432만 허용 — #37 6205733242 Q3).
  # 그때 A TIMEOUT은 "승인 밖은 열려 있지 않음" 기록일 뿐 정책 차단 증거가 아니다(NO_CLAIM_UPSTREAM).
  for id in N1 N2 N3 N4 N5; do
    b="$(awk -F'\t' -v id="$id" '$2==id {v=$8} END {print v}' "$RUN_DIR/stage-b/results.tsv")"; a="$(verdict "$id")"
    if [[ "$a" == CONNECTED ]]; then claim=FAIL_OPEN; FAILS+=("$id:CONNECTED(정책 후 열림)")
    elif [[ "$b" == CONNECTED ]]; then
      if [[ "$a" == TIMEOUT ]]; then claim=NP_EFFECT; else claim=INCONCLUSIVE; INCONCL+=("$id:$a"); fi
    else claim=NO_CLAIM_UPSTREAM; fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$b" "$a" "$claim" >>"$PD/np-effect.tsv"
  done
  r1_ok=NO; [[ ",$R1_EXPECTED_CODES," == *",$r1_code,"* ]] && r1_ok=YES
  r2_ok=NO; [[ "$(out_of r2)" == True ]] && r2_ok=YES
  [[ $r1_ok == YES ]] || FAILS+=("R1:$r1_code(기대 $R1_EXPECTED_CODES)")
  [[ $r2_ok == YES ]] || FAILS+=("R2:$(out_of r2)(기대 True)")

  # Handoff 8·9 (#4)
  route_ready=NO; [[ $r1_ok == YES && $r2_ok == YES ]] && route_ready=YES
  hybrid=BLOCKED
  b_n1="$(awk -F'\t' '$2=="N1" {print $8}' "$RUN_DIR/stage-b/results.tsv")"
  if [[ "$(st C1)" == PASS && "$(verdict P1)" == CONNECTED && "$b_n1" == CONNECTED && "$(verdict N1)" == TIMEOUT ]]; then hybrid=READY; fi
  {
    echo "ROUTE_READY=$route_ready  # R1=$r1_code TLS=$r1_tls, R2=$(out_of r2)"
    echo "HYBRID_ROUTE=$hybrid  # C1=$(st C1) P1(A)=$(verdict P1) N1(B→A)=$b_n1→$(verdict N1)"
    echo "NP_EFFECT=$(awk -F'\t' '$4=="NP_EFFECT" {printf "%s%s", s, $1; s=","}' "$PD/np-effect.tsv")  # B CONNECTED→A TIMEOUT만"
    echo "NO_CLAIM_UPSTREAM=$(awk -F'\t' '$4=="NO_CLAIM_UPSTREAM" {printf "%s%s", s, $1; s=","}' "$PD/np-effect.tsv")  # B부터 막힘(SG 등) — 정책 효과 미주장"
    echo "STAGE_C_REF=$(st STAGE_C_REF)"; echo "T3_REF=$(st T3_REF)"; echo "DB_WINDOW_REF=$(st DB_WINDOW_REF)"
  } >"$PD/handoff.txt"
  cat "$PD/handoff.txt"
  touch "$RUN_DIR/stage-a.done"
  if (( ${#FAILS[@]} )); then printf '%s\n' "${FAILS[@]}" >"$PD/fail.txt"; die 50 "A 판정 FAIL: $(tr '\n' ';' <"$PD/fail.txt")"; fi
  if (( ${#INCONCL[@]} )); then printf '%s\n' "${INCONCL[@]}" >"$PD/inconclusive.txt"; die 51 "A 판정 불가(차단 증거 아님): $(tr '\n' ';' <"$PD/inconclusive.txt")"; fi
  echo "STAGE_A_PASS — 다음: cleanup (00~03은 남김)"
  exit 0
fi

# ======================================================================
if [[ "$PHASE" == cleanup ]]; then
  HOLD=()
  while IFS=$'\t' read -r r uid; do
    k="${r//\//-}"
    run "cur-$k" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
    if [[ "$(rc_of "cur-$k")" != 0 ]]; then
      if grep -q NotFound "$PD/cur-$k.err"; then echo "$r ALREADY_ABSENT" >>"$PD/cleanup.txt"; else HOLD+=("$r:조회 오류"); echo "$r HOLD(조회 오류)" >>"$PD/cleanup.txt"; fi
      continue
    fi
    if [[ "$(out_of "cur-$k")" != "$uid" ]]; then HOLD+=("$r:UID 불일치"); echo "$r HOLD(UID 불일치 $(out_of "cur-$k"))" >>"$PD/cleanup.txt"; continue; fi
    run "del-$k" "${OC[@]}" -n "$NS" delete "$r" --wait=true
    if [[ "$(rc_of "del-$k")" == 0 ]]; then echo "$r DELETED $uid" >>"$PD/cleanup.txt"; else HOLD+=("$r:삭제 실패"); echo "$r HOLD(삭제 실패)" >>"$PD/cleanup.txt"; fi
  done <"$RUN_DIR/stage-b/created.tsv"
  # 남겨야 하는 00~03이 stage-a 기록과 같은지(UID·spec)
  if [[ -f "$RUN_DIR/stage-a/np-applied.tsv" ]]; then
    while IFS=$'\t' read -r np uid sha; do
      run "keep-$np" "${OC[@]}" -n "$NS" get networkpolicy "$np" -o 'jsonpath={.metadata.uid}{"\n"}{.spec}'
      if [[ "$(rc_of "keep-$np")" != 0 ]]; then HOLD+=("$np:조회 실패"); continue; fi
      [[ "$(head -n 1 "$PD/keep-$np.out")" == "$uid" && "$(tail -n +2 "$PD/keep-$np.out" | sha256sum | cut -d' ' -f1)" == "$sha" ]] \
        || HOLD+=("$np:UID/spec 변화")
    done <"$RUN_DIR/stage-a/np-applied.tsv"
  fi
  run after "${OC[@]}" -n "$NS" get all,networkpolicy,route -o name
  cat "$PD/cleanup.txt"
  if (( ${#HOLD[@]} )); then printf '%s\n' "${HOLD[@]}" >"$PD/hold.txt"; die 60 "CLEANUP=HOLD: $(tr '\n' ';' <"$PD/hold.txt")"; fi
  echo "CLEANUP_OK — 시험 자원 정리, 00~03 유지 확인"
  exit 0
fi
