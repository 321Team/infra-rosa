#!/usr/bin/env bash
# infra-rosa#7 — NetworkPolicy·Egress·Hybrid Route TCP 시험 실행기 (ROSA 생성 후 키트)
#
# 사용: netpol-run.sh <render|precheck|stage-b|stage-a|cleanup>
#   단계마다 따로 실행한다. baseline#37 단계 C·D(이재환)와의 끼워 넣기 순서는 RUN-KIT.md.
#
#   render    로컬만(oc 호출 없음). 승인 입력을 approved-inputs.env로 고정하고 00~03·10~12를 렌더한다.
#             kit·source·manifest·입력 해시를 bundle.txt에 묶고 그 해시(BUNDLE_SHA256)를 리뷰 승인값으로 쓴다.
#   precheck  읽기 + server dry-run만(클러스터 변경 없음). 대상(API·Cluster ID·NS UID)을 target.env로 고정하고
#             Worker IP가 WORKER_CIDR 안인지, OVN·router 라벨·DNS 포트, 대상 Namespace가 비어 있는지 본다.
#   stage-b   시험 자원(10·11·12) 생성 → 정책 전(B) 측정. #37 단계 C·T3·db01 창 기록 링크가 있어야 시작한다.
#   stage-a   플랫폼 정책 00→01→02→03 적용 → 정책 후(A) 측정 → Handoff 8·9.
#   cleanup   stage-b가 OWNED로 기록한 시험 자원만 UID 대조 후 삭제. 00~03은 남기고 UID·spec을 확인한다.
#             완료 전까지 같은 RUN에서 cleanup-attempt-N으로 다시 시도할 수 있다.
#
# 하지 않는 것: 기존 NetworkPolicy·workload 삭제/수정, route·Relay·db01 조회/변경, 자동 재시도·자동 원복,
#   00~03 삭제, 디렉터리 일괄 delete, 이름만 보고 자원 인수·삭제. render~stage-a는 RUN_DIR당 한 번만 실행된다.
#
# 입력
#   공통: RUN_DIR (render는 없어야 함, 나머지는 render가 만든 것)
#   render: NS, TEAM, DB_IP, DB_PORT, REG_MODE=none|include (include면 REG_IP, REG_PORT),
#           TEST_IMAGE, HTTP_IMAGE (<registry>/<repo>@sha256:<64hex>), N3_TARGET=<ip>:<port>
#     선택: N2_PORT(22), N4_TARGET(1.1.1.1:443), WORKER_CIDR(10.20.10.0/24), R1_EXPECTED_CODES(200),
#           POD_MAX_AGE_MIN(50)
#   클러스터 단계: APPROVED_BUNDLE_SHA256 (render 출력을 리뷰로 승인한 값)
#     precheck만: CTX, API(https://host[:port]), EXPECTED_CLUSTER_ID, EXPECTED_NS_UID — 이후 단계는 target.env 사용
#                 (이후 단계에 이 변수가 있으면 target.env와 같아야 함)
#   stage-b: STAGE_C_REF, T3_REF, DB_WINDOW_REF — #37/#11 기록 댓글 URL(실행 시점 기록, 승인 입력 아님)
#
# 종료 코드:
#   0  단계 성공          2  입력 오류(oc 호출 전)       10 대상 불일치(서버/Cluster ID/NS UID/target.env)
#   11 조회 오류·필수 증적 수집 실패(EVIDENCE_INCOMPLETE)   20 precheck 조건 불충족
#   21 bundle 불일치(kit·manifest·승인 입력 해시, 자리표시자)
#   30 단계 순서·시각 조건 위반(이전 단계 없음·다른 bundle/대상, 이미 실행됨, Pod 수명 초과)
#   40 B 기준 불성립 — 정책 시험으로 넘어가지 않음
#   41 apply·Ready 실패(부분 생성·부분 정책은 created.tsv·policy-set.txt에 기록)
#   42 A 정책 집합/00 spec이 계약과 다름
#   50 A 판정 FAIL(기대와 반대)  51 A 판정 불가(REFUSED/UNREACHABLE/TOOL_ERROR/EXEC_TIMEOUT)
#   60 cleanup HOLD(UID 불일치·미확인 자원·조회 오류·삭제 실패·00~03 변화·최종 목록 불일치)
#   61 시험 자원 정리는 끝났으나 POLICY_SET=PARTIAL — 앱 배포·Handoff READY 금지
set -euo pipefail
umask 077

die() { local rc="$1"; shift; echo "STOP: $*" >&2; exit "$rc"; }

PHASE="${1:-}"
case "$PHASE" in render|precheck|stage-b|stage-a|cleanup) ;; *) die 2 "사용: $0 <render|precheck|stage-b|stage-a|cleanup>";; esac

for c in sha256sum date awk sed grep sort cmp realpath mkdir timeout; do command -v "$c" >/dev/null || die 2 "명령 없음: $c"; done

SELF="$(realpath "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "$SELF")"
SELF_SHA="$(sha256sum "$SELF" | cut -d' ' -f1)"
RUN_DIR="${RUN_DIR:-}"
[[ -n "$RUN_DIR" && "$RUN_DIR" != *$'\n'* ]] || die 2 "RUN_DIR 필요"
# 바깥 명령 시간 상한(원격 TCP 5초와 별개). 이 값은 판정 기준이 아니라 도구 hang 방지용이다.
EXEC_TIMEOUT_S="${NETPOL_EXEC_TIMEOUT_S:-60}"
[[ "$EXEC_TIMEOUT_S" =~ ^[0-9]+$ ]] && (( EXEC_TIMEOUT_S >= 1 && EXEC_TIMEOUT_S <= 300 )) || die 2 "NETPOL_EXEC_TIMEOUT_S 1~300"

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
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_kst() { TZ=KST-9 date +%Y-%m-%dT%H:%M:%S%z; }   # 고정 KST(+0900). tzdata 없는 환경에서도 같은 값

# key=value 파일에서 정확히 1줄인 값만 읽는다(중복·누락이면 빈 값).
kv() { awk -F= -v k="$2" '$1==k {n++; sub(/^[^=]*=/, ""); v=$0} END {if (n==1) print v}' "$1"; }
st() { kv "$RUN_DIR/state.env" "$1"; }
st_add() { printf '%s=%s\n' "$1" "$2" >>"$RUN_DIR/state.env"; }
ai() { kv "$RUN_DIR/approved-inputs.env" "$1"; }
journal() { printf '%s\t%s\t%s\t%s\n' "$(now_utc)" "$PHASE" "$1" "${2:-}" >>"$RUN_DIR/journal.tsv"; }

# 승인 입력 형식 검사. render 입력과 이후 단계의 approved-inputs.env 양쪽에 같은 규칙을 쓴다.
validate_inputs() { # rc
  local rc="$1"
  (( ${#NS} <= 63 )) && [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$rc" "NS는 DNS-1123 label"
  [[ ! "$NS" =~ ^(openshift|kube)(-|$) && "$NS" != default ]] || die "$rc" "System namespace는 대상 아님"
  [[ "$TEAM" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$rc" "TEAM 형식 오류"
  [[ "$DB_IP" =~ $IPV4_RE ]] && is_port "$DB_PORT" || die "$rc" "DB_IP/DB_PORT 형식 오류(IF-18 승인값)"
  case "$REG_MODE" in
    none) [[ -z "$REG_IP" && -z "$REG_PORT" ]] || die "$rc" "REG_MODE=none인데 REG_IP/REG_PORT 값이 있음" ;;
    include) [[ "$REG_IP" =~ $IPV4_RE ]] && is_port "$REG_PORT" || die "$rc" "REG_IP/REG_PORT 형식 오류(D22 승인값)" ;;
    *) die "$rc" "REG_MODE=none|include (D22 결정)" ;;
  esac
  [[ "$TEST_IMAGE" =~ $IMG_RE && "$HTTP_IMAGE" =~ $IMG_RE ]] || die "$rc" "TEST_IMAGE/HTTP_IMAGE는 @sha256:<64hex> 고정"
  is_target "$N3_TARGET" || die "$rc" "N3_TARGET=<ip>:<port> 필요(승인 밖 On-Prem 대상)"
  [[ "${N3_TARGET%:*}" != "$DB_IP" && ( -z "$REG_IP" || "${N3_TARGET%:*}" != "$REG_IP" ) ]] || die "$rc" "N3_TARGET이 승인 대상과 같음"
  is_port "$N2_PORT" && [[ "$N2_PORT" != "$DB_PORT" ]] || die "$rc" "N2_PORT 형식 오류 또는 승인 포트와 같음"
  is_target "$N4_TARGET" || die "$rc" "N4_TARGET=<ip>:<port>"
  [[ "${WORKER_CIDR%/*}" =~ $IPV4_RE && "${WORKER_CIDR#*/}" =~ ^[0-9]{1,2}$ ]] && (( ${WORKER_CIDR#*/} <= 32 )) || die "$rc" "WORKER_CIDR 형식 오류"
  [[ "$R1_EXPECTED_CODES" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || die "$rc" "R1_EXPECTED_CODES 형식: 200 또는 200,403"
  [[ "$POD_MAX_AGE_MIN" =~ ^[0-9]+$ ]] && (( POD_MAX_AGE_MIN >= 1 && POD_MAX_AGE_MIN <= 55 )) || die "$rc" "POD_MAX_AGE_MIN 1~55"
}
INPUT_KEYS=(NS TEAM DB_IP DB_PORT REG_MODE REG_IP REG_PORT TEST_IMAGE HTTP_IMAGE N2_PORT N3_TARGET N4_TARGET WORKER_CIDR R1_EXPECTED_CODES POD_MAX_AGE_MIN)

# 단계별 기록 폴더. render~stage-a는 이미 있으면 거부, cleanup은 attempt 번호를 늘린다.
PD=""
open_phase() {
  if [[ "$PHASE" == cleanup ]]; then
    local i=1; while [[ -e "$RUN_DIR/cleanup-attempt-$i" ]]; do i=$((i+1)); done
    PD="$RUN_DIR/cleanup-attempt-$i"
  else
    PD="$RUN_DIR/$PHASE"
  fi
  mkdir -m 700 -- "$PD" 2>/dev/null || die 30 "$(basename "$PD") 기록 폴더가 이미 있음(같은 RUN에서 재실행 금지)"
  printf 'phase=%s\nstart_utc=%s\nstart_kst=%s\nkit_sha256=%s\n' "$PHASE" "$(now_utc)" "$(now_kst)" "$SELF_SHA" >"$PD/phase.txt"
  trap 'rc=$?; echo "end_utc=$(now_utc) rc=$rc" >>"$PD/phase.txt"; journal END "rc=$rc"; [[ $rc -ne 0 ]] && echo "RESULT_RC=$rc; 보존: $PD" >&2' EXIT
  journal START "$(basename "$PD")"
}

run() {
  local name="$1"; shift
  local start rc; start="$(now_utc)"
  set +e
  "$@" >"$PD/$name.out" 2>"$PD/$name.err"
  rc=$?
  set -e
  echo "$rc" >"$PD/$name.rc"
  # 비밀값은 argv에 넣지 않는다(kubeconfig context 이름·URL·자원 이름만).
  printf '%s\t%s\t%s\t%s\t%s\n' "$start" "$(now_utc)" "$rc" "$name" "$(printf '%q ' "$@")" >>"$PD/commands.tsv"
  return 0
}
rc_of() { cat "$PD/$1.rc"; }
out_of() { cat "$PD/$1.out"; }

# ======================================================================
if [[ "$PHASE" == render ]]; then
  NS="${NS:-}"; TEAM="${TEAM:-}"; DB_IP="${DB_IP:-}"; DB_PORT="${DB_PORT:-}"
  REG_MODE="${REG_MODE:-}"; REG_IP="${REG_IP:-}"; REG_PORT="${REG_PORT:-}"
  [[ "$REG_MODE" == none ]] && { REG_IP=""; REG_PORT=""; }
  TEST_IMAGE="${TEST_IMAGE:-}"; HTTP_IMAGE="${HTTP_IMAGE:-}"
  N2_PORT="${N2_PORT:-22}"; N3_TARGET="${N3_TARGET:-}"; N4_TARGET="${N4_TARGET:-1.1.1.1:443}"
  WORKER_CIDR="${WORKER_CIDR:-10.20.10.0/24}"; R1_EXPECTED_CODES="${R1_EXPECTED_CODES:-200}"
  POD_MAX_AGE_MIN="${POD_MAX_AGE_MIN:-50}"
  validate_inputs 2
  [[ ! -e "$RUN_DIR" ]] || die 2 "RUN_DIR이 이미 있음(덮어쓰지 않음)"
  mkdir -p -m 700 -- "$RUN_DIR"
  RUN_DIR="$(realpath "$RUN_DIR")"
  open_phase
  for k in "${INPUT_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done >"$RUN_DIR/approved-inputs.env"
  R="$RUN_DIR/manifests"; mkdir -m 700 "$R"
  : >"$PD/source-sha.tsv"
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
    printf '%s\t%s\n' "$n" "$(sha_of "$src")" >>"$PD/source-sha.tsv"
  done
  if grep -n '__[A-Z_]*__' "$R"/*.yaml >"$PD/placeholder-left.txt"; then die 21 "자리표시자 남음: $PD/placeholder-left.txt"; fi
  grep -q "cidr: $DB_IP/32" "$R/03.yaml" && grep -q "port: $DB_PORT }" "$R/03.yaml" || die 21 "03에 IF-18 규칙이 없음"
  if [[ "$REG_MODE" == none ]]; then
    [[ "$(grep -c 'ipBlock:' "$R/03.yaml")" == 1 ]] || die 21 "REG_MODE=none인데 03에 IF-18 외 ipBlock이 남음"
  else
    grep -q "cidr: $REG_IP/32" "$R/03.yaml" || die 21 "03에 IF-19 규칙이 없음"
  fi
  ( cd "$R" && sha256sum 00.yaml 01.yaml 02.yaml 03.yaml 10.yaml 11.yaml 12.yaml >SHA256SUMS )
  {
    echo "KIT_SHA256=$SELF_SHA"
    echo "SOURCE_GIT_HEAD=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    awk -F'\t' '{print "SOURCE_" $1 "_SHA256=" $2}' "$PD/source-sha.tsv"
    echo "MANIFEST_SUMS_SHA256=$(sha_of "$R/SHA256SUMS")"
    echo "INPUTS_SHA256=$(sha_of "$RUN_DIR/approved-inputs.env")"
  } >"$RUN_DIR/bundle.txt"
  chmod 400 "$RUN_DIR/approved-inputs.env" "$RUN_DIR/bundle.txt" "$R"/*
  BUNDLE_SHA="$(sha_of "$RUN_DIR/bundle.txt")"
  printf 'RENDERED_AT_KST=%s\nBUNDLE_SHA256=%s\n' "$(now_kst)" "$BUNDLE_SHA" >"$RUN_DIR/state.env"
  echo "RENDER_OK BUNDLE_SHA256=$BUNDLE_SHA"
  echo "리뷰 대상: bundle.txt(kit·source·manifest·승인 입력 해시), approved-inputs.env, manifests/"
  echo "다음: 승인값을 APPROVED_BUNDLE_SHA256로 precheck 실행"
  exit 0
fi

# ======================================================================
# 클러스터 단계 공통: bundle(=kit·manifest·승인 입력) 무결성 → 단계 순서 → 대상 고정
command -v oc >/dev/null || die 2 "명령 없음: oc"
[[ -d "$RUN_DIR" && -f "$RUN_DIR/bundle.txt" && -f "$RUN_DIR/approved-inputs.env" ]] || die 30 "RUN_DIR에 render 결과가 없음(render 먼저)"
RUN_DIR="$(realpath "$RUN_DIR")"
APPROVED_BUNDLE_SHA256="${APPROVED_BUNDLE_SHA256:-}"
[[ "$APPROVED_BUNDLE_SHA256" =~ $SHA_RE ]] || die 2 "APPROVED_BUNDLE_SHA256 필요(64hex)"
R="$RUN_DIR/manifests"
BUNDLE_SHA="$(sha_of "$RUN_DIR/bundle.txt")"
[[ "$BUNDLE_SHA" == "$APPROVED_BUNDLE_SHA256" ]] || die 21 "bundle.txt 해시가 승인값과 다름"
[[ "$(kv "$RUN_DIR/bundle.txt" KIT_SHA256)" == "$SELF_SHA" ]] || die 21 "실행기(kit)가 승인 bundle과 다름 — 새 RUN·재리뷰 필요"
[[ "$(kv "$RUN_DIR/bundle.txt" INPUTS_SHA256)" == "$(sha_of "$RUN_DIR/approved-inputs.env")" ]] || die 21 "approved-inputs.env가 승인 bundle과 다름"
[[ "$(kv "$RUN_DIR/bundle.txt" MANIFEST_SUMS_SHA256)" == "$(sha_of "$R/SHA256SUMS")" ]] || die 21 "manifests/SHA256SUMS가 승인 bundle과 다름"
( cd "$R" && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 || die 21 "렌더 파일이 SHA256SUMS와 다름"
for k in "${INPUT_KEYS[@]}"; do
  [[ "$(grep -c "^$k=" "$RUN_DIR/approved-inputs.env")" == 1 ]] || die 21 "approved-inputs.env의 $k가 정확히 1줄이 아님"
  printf -v "$k" '%s' "$(ai "$k")"
done
validate_inputs 21

MARK="BUNDLE=$BUNDLE_SHA"
case "$PHASE" in
  precheck) : ;;
  stage-b) [[ -f "$RUN_DIR/precheck.ok" ]] || die 30 "precheck PASS 기록 없음" ;;
  stage-a) [[ -f "$RUN_DIR/stage-b.ok" ]] || die 30 "stage-b PASS 기록 없음(B 기준 없이 정책 적용 금지)" ;;
  cleanup)
    [[ -f "$RUN_DIR/stage-b/created.tsv" ]] || die 30 "이 RUN의 stage-b 기록 없음(정리할 것 없음)"
    [[ ! -f "$RUN_DIR/cleanup.done" ]] || die 30 "이 RUN의 cleanup은 이미 완료됨: $(cat "$RUN_DIR/cleanup.done")" ;;
esac

if [[ "$PHASE" == precheck ]]; then
  CTX="${CTX:-}"; API="${API:-}"; EXPECTED_CLUSTER_ID="${EXPECTED_CLUSTER_ID:-}"; EXPECTED_NS_UID="${EXPECTED_NS_UID:-}"
  [[ -n "$CTX" && "$CTX" != *$'\n'* && "$CTX" != *=* ]] || die 2 "CTX 필요"
  [[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die 2 "API는 https://host[:port]"
  [[ "$EXPECTED_CLUSTER_ID" =~ $UUID_RE && "$EXPECTED_NS_UID" =~ $UUID_RE ]] || die 2 "EXPECTED_CLUSTER_ID/EXPECTED_NS_UID는 승인 inventory의 UUID"
else
  [[ -f "$RUN_DIR/target.env" ]] || die 30 "target.env 없음(precheck 먼저)"
  # 환경변수로 들어온 기대값은 target.env 값으로 덮기 전에 대조한다(다르면 STOP).
  for pair in "CTX:CTX" "API:API" "EXPECTED_CLUSTER_ID:CLUSTER_ID" "EXPECTED_NS_UID:NS_UID"; do
    ev="${pair%%:*}"; tk="${pair#*:}"
    if [[ -n "${!ev:-}" && "${!ev}" != "$(kv "$RUN_DIR/target.env" "$tk")" ]]; then die 10 "$ev가 precheck에서 고정한 대상과 다름"; fi
  done
  CTX="$(kv "$RUN_DIR/target.env" CTX)"; API="$(kv "$RUN_DIR/target.env" API)"
  EXPECTED_CLUSTER_ID="$(kv "$RUN_DIR/target.env" CLUSTER_ID)"; EXPECTED_NS_UID="$(kv "$RUN_DIR/target.env" NS_UID)"
  [[ "$(kv "$RUN_DIR/target.env" BUNDLE)" == "$BUNDLE_SHA" ]] || die 30 "target.env가 다른 bundle에서 만들어짐"
  MARK="BUNDLE=$BUNDLE_SHA TARGET=$(sha_of "$RUN_DIR/target.env")"
  [[ "$(cat "$RUN_DIR/precheck.ok")" == "$MARK" ]] || die 30 "precheck.ok가 현재 bundle·대상과 다름"
  [[ "$PHASE" != stage-a ]] || [[ "$(cat "$RUN_DIR/stage-b.ok")" == "$MARK" ]] || die 30 "stage-b.ok가 현재 bundle·대상과 다름"
fi

if [[ "$PHASE" == stage-b ]]; then
  STAGE_C_REF="${STAGE_C_REF:-}"; T3_REF="${T3_REF:-}"; DB_WINDOW_REF="${DB_WINDOW_REF:-}"
  for v in STAGE_C_REF T3_REF DB_WINDOW_REF; do [[ "${!v}" =~ $REF_RE ]] || die 30 "$v 필요(#37 단계 C·D 기록 댓글 URL) — 없으면 시작하지 않음"; done
fi

open_phase

run ctx-server oc config view --minify --context="$CTX" -o 'jsonpath={.clusters[0].cluster.server}'
[[ "$(rc_of ctx-server)" == 0 && "$(out_of ctx-server)" == "$API" ]] || die 10 "CTX의 서버가 API와 다름(첫 API 요청 전 중단)"
OC=(oc --request-timeout="${EXEC_TIMEOUT_S}s" --context="$CTX" --server="$API" --insecure-skip-tls-verify=false)
run cluster-id "${OC[@]}" get clusterversion version -o 'jsonpath={.spec.clusterID}'
[[ "$(rc_of cluster-id)" == 0 && "$(out_of cluster-id)" == "$EXPECTED_CLUSTER_ID" ]] || die 10 "Cluster ID가 승인 inventory와 다르거나 조회 불가"
run ns-uid "${OC[@]}" get namespace "$NS" -o 'jsonpath={.metadata.uid}'
[[ "$(rc_of ns-uid)" == 0 && "$(out_of ns-uid)" == "$EXPECTED_NS_UID" ]] || die 10 "Namespace UID가 승인 inventory와 다르거나 조회 불가"
run whoami "${OC[@]}" whoami
run oc-client oc version --client
{
  echo "ENV=ROSA"; echo "PHASE=$PHASE"; echo "KST=$(now_kst)"; echo "CTX=$CTX"; echo "API=$API"
  echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID"; echo "NS=$NS"; echo "NAMESPACE_UID=$EXPECTED_NS_UID"
  echo "BUNDLE_SHA256=$BUNDLE_SHA"; echo "KIT_SHA256=$SELF_SHA"
  echo "WHOAMI_RC=$(rc_of whoami) WHOAMI=$(out_of whoami)"
  echo "OC_CLIENT=$(head -n 1 "$PD/oc-client.out" 2>/dev/null)"; echo "BASH=$BASH_VERSION"
} >"$PD/context.txt"

# ---- 시험 함수 ----
# Pod 안 TCP 시도는 5초 상한, 결과 코드는 Pod 안에서 NETPOL_RC=로 찍는다.
# 바깥 oc exec가 시간 초과·실패하면 NETPOL_RC가 없으므로 원격 TCP TIMEOUT(정상 차단)과 섞이지 않는다.
probe() { # stage id pod ip port
  local stage="$1" id="$2" pod="$3" ip="$4" port="$5" t0 rc v code f="$PD/probe-$2"
  t0="$(now_utc)"
  set +e
  timeout "$EXEC_TIMEOUT_S" "${OC[@]}" -n "$NS" exec "$pod" -c probe -- \
    bash -c 'timeout 5 bash -c "</dev/tcp/$0/$1"; echo "NETPOL_RC=$?"' "$ip" "$port" >"$f.out" 2>"$f.err"
  rc=$?
  set -e
  code="$(sed -n 's/^NETPOL_RC=\([0-9]*\)$/\1/p' "$f.out" | tail -n 1)"
  if [[ -z "$code" ]]; then
    if (( rc == 124 )); then v=EXEC_TIMEOUT; else v=TOOL_ERROR; fi
  elif (( code == 0 )); then v=CONNECTED
  elif (( code == 124 )); then v=TIMEOUT
  elif grep -qi 'connection refused' "$f.err"; then v=REFUSED
  elif grep -qi 'no route to host' "$f.err"; then v=UNREACHABLE
  else v=TOOL_ERROR; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s:%s\t%s\t%s\n' "$stage" "$id" "$t0" "$(now_utc)" "$pod" "$ip" "$port" "exec=$rc,tcp=${code:-none}" "$v" >>"$PD/results.tsv"
}
dns_probe() { # stage
  local t0 rc; t0="$(now_utc)"
  set +e
  timeout "$EXEC_TIMEOUT_S" "${OC[@]}" -n "$NS" exec tcp-allowed -c probe -- getent hosts kubernetes.default.svc.cluster.local >"$PD/probe-P3.out" 2>"$PD/probe-P3.err"
  rc=$?
  set -e
  printf '%s\tP3\t%s\t%s\ttcp-allowed\tdns:kubernetes.default\texec=%s\t%s\n' "$1" "$t0" "$(now_utc)" "$rc" "$([[ $rc == 0 ]] && echo OK || echo FAIL)" >>"$PD/results.tsv"
}
route_check() { # stage — R1(실행 위치=클러스터 밖, TLS 검증 필수) / R2(Admitted, rc0 필수)
  local s="$1" host code=000 tls=NOT_RUN
  run "route-host-$s" "${OC[@]}" -n "$NS" get route route-probe -o 'jsonpath={.spec.host}'
  host="$(out_of "route-host-$s")"
  if [[ "$(rc_of "route-host-$s")" == 0 && "$host" =~ ^[A-Za-z0-9.-]+$ ]] && command -v curl >/dev/null; then
    run "r1-$s" curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$host/"
    if [[ "$(rc_of "r1-$s")" == 0 ]]; then code="$(out_of "r1-$s")"; tls=VERIFIED; else tls="FAILED(curl rc=$(rc_of "r1-$s"))"; fi
  fi
  printf '%s\tR1\t%s\t%s\trunner\thttps://%s/\t%s\t%s\n' "$s" "$(now_utc)" "$(now_utc)" "$host" "$tls" "$code" >>"$PD/results.tsv"
  run "r2-$s" "${OC[@]}" -n "$NS" get route route-probe -o 'jsonpath={.status.ingress[0].conditions[?(@.type=="Admitted")].status}'
  printf '%s\tR2\t%s\t%s\t-\troute/route-probe\trc=%s\t%s\n' "$s" "$(now_utc)" "$(now_utc)" "$(rc_of "r2-$s")" "$([[ "$(rc_of "r2-$s")" == 0 ]] && out_of "r2-$s" || echo QUERY_FAILED)" >>"$PD/results.tsv"
}
verdict() { awk -F'\t' -v id="$1" '$2==id {v=$8} END {print v}' "$PD/results.tsv"; }
bverdict() { awk -F'\t' -v id="$1" '$2==id {v=$8} END {print v}' "$RUN_DIR/stage-b/results.tsv"; }
r1_tls() { awk -F'\t' '$2=="R1" {v=$7} END {print v}' "$PD/results.tsv"; }

FAILS=(); INCONCL=()
expect() { # id expected
  local got; got="$(verdict "$1")"
  [[ "$got" == "$2" ]] && return 0
  if [[ "$2" == TIMEOUT && "$got" != CONNECTED ]]; then INCONCL+=("$1:$got"); else FAILS+=("$1:$got(기대 $2)"); fi
}

measure() { # stage
  local s="$1" pod_ip
  probe "$s" P1 tcp-allowed "$DB_IP" "$DB_PORT"
  [[ "$REG_MODE" == include ]] && probe "$s" P2 tcp-allowed "$REG_IP" "$REG_PORT"
  dns_probe "$s"
  probe "$s" N1 tcp-control "$DB_IP" "$DB_PORT"
  probe "$s" N2 tcp-allowed "$DB_IP" "$N2_PORT"
  probe "$s" N3 tcp-allowed "${N3_TARGET%:*}" "${N3_TARGET##*:}"
  probe "$s" N4 tcp-allowed "${N4_TARGET%:*}" "${N4_TARGET##*:}"
  pod_ip="$(cat "$RUN_DIR/stage-b/route-probe-ip.txt")"
  probe "$s" N5 ingress-probe "$pod_ip" 8080
  route_check "$s"
}

# apply 출력(-o name)의 "kind.group/name"을 "kind/name"으로
norm_res() { local k="${1%%/*}"; printf '%s/%s' "${k%%.*}" "${1#*/}"; }
expected_objects() { # file-no
  case "$1" in
    10) echo pod/tcp-allowed pod/tcp-control ;;
    11) echo pod/route-probe service/route-probe route/route-probe ;;
    12) echo pod/ingress-probe networkpolicy/probe-egress-to-route ;;
    00) echo networkpolicy/fds-platform-default-deny ;;
    01) echo networkpolicy/allow-egress-dns ;;
    02) echo networkpolicy/allow-ingress-from-router ;;
    03) echo networkpolicy/allow-egress-onprem-approved ;;
  esac
}
# 한 파일을 적용하고 그 파일의 기대 객체마다 결과를 즉시 기록한다.
#   OWNED       apply 출력에 있고 UID 확인됨 → cleanup이 UID 대조 후 삭제 가능
#   UNCONFIRMED 존재하지만 apply 출력에 없거나 UID 확인 실패 → 삭제하지 않고 복구 절차(HOLD)
apply_and_record() { # file-no journal-file ; returns 0 only if apply rc0 and all objects OWNED
  local n="$1" jf="$2" r k ok=0
  journal INTENT "apply $n.yaml"
  run "apply-$n" "${OC[@]}" apply -f "$R/$n.yaml" -o name
  journal APPLIED "$n.yaml rc=$(rc_of "apply-$n")"
  [[ "$(rc_of "apply-$n")" == 0 ]] || ok=1
  for r in $(expected_objects "$n"); do
    k="${r//\//-}"
    run "uid-$k" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
    local listed=no uid; uid="$(out_of "uid-$k")"
    while read -r line; do [[ -n "$line" && "$(norm_res "$line")" == "$r" ]] && listed=yes; done <"$PD/apply-$n.out"
    if [[ "$(rc_of "uid-$k")" == 0 && "$uid" =~ $UUID_RE ]]; then
      if [[ $listed == yes ]]; then printf '%s\t%s\tOWNED\t%s\n' "$r" "$uid" "$n" >>"$jf"
      else printf '%s\t%s\tUNCONFIRMED\t%s(apply 출력에 없음)\n' "$r" "$uid" "$n" >>"$jf"; ok=1; fi
    elif grep -q NotFound "$PD/uid-$k.err"; then
      [[ $listed == no ]] || { printf '%s\t-\tUNCONFIRMED\t%s(적용 출력에 있으나 NotFound)\n' "$r" "$n" >>"$jf"; }
      ok=1
    else
      printf '%s\t-\tUNCONFIRMED\t%s(UID 조회 실패)\n' "$r" "$n" >>"$jf"; ok=1
    fi
  done
  return $ok
}

# ======================================================================
if [[ "$PHASE" == precheck ]]; then
  F=()
  # C1 — Worker InternalIP 전부 WORKER_CIDR 안(Pod egress는 Worker IP로 SNAT, db01 사전 창은 이 대역만 허용)
  run nodes "${OC[@]}" get nodes -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}{"\n"}{end}'
  [[ "$(rc_of nodes)" == 0 ]] || die 11 "nodes 조회 실패"
  worker_count=0
  while IFS=$'\t' read -r name ips; do
    [[ -n "$name" ]] || continue
    ips="${ips% }"; worker_count=$((worker_count+1))
    [[ "$ips" =~ $IPV4_RE ]] || { F+=("C1:$name InternalIP 1개 IPv4 아님($ips)"); continue; }
    in_cidr "$ips" "$WORKER_CIDR" || F+=("C1:$name $ips ∉ $WORKER_CIDR")
    printf '%s\t%s\n' "$name" "$ips" >>"$PD/worker-ips.tsv"
  done <"$PD/nodes.out"
  (( worker_count > 0 )) || F+=("C1:노드 0개")
  run network "${OC[@]}" get network.config cluster -o 'jsonpath={.status.networkType}'
  [[ "$(rc_of network)" == 0 ]] || die 11 "network.config 조회 실패"
  [[ "$(out_of network)" == OVNKubernetes ]] || F+=("C3:networkType=$(out_of network)")
  run ingress-ns "${OC[@]}" get namespace -l policy-group.network.openshift.io/ingress -o name
  [[ "$(rc_of ingress-ns)" == 0 ]] || die 11 "ingress namespace 조회 실패"
  grep -qx 'namespace/openshift-ingress' "$PD/ingress-ns.out" || F+=("C4:openshift-ingress에 policy-group 라벨 없음")
  run dns-ports "${OC[@]}" -n openshift-dns get pods -o 'jsonpath={..containerPort}'
  [[ "$(rc_of dns-ports)" == 0 ]] || die 11 "openshift-dns 조회 실패"
  grep -qw 5353 "$PD/dns-ports.out" || F+=("C5:DNS Pod 포트에 5353 없음")
  run ns-inventory "${OC[@]}" -n "$NS" get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name
  [[ "$(rc_of ns-inventory)" == 0 ]] || die 11 "Namespace inventory 조회 실패"
  [[ ! -s "$PD/ns-inventory.out" ]] || F+=("NS:대상 Namespace가 비어 있지 않음($(tr '\n' ' ' <"$PD/ns-inventory.out"))")
  for n in 00 01 02 03 10 11 12; do
    run "dryrun-$n" "${OC[@]}" apply --dry-run=server -f "$R/$n.yaml" -o name
    [[ "$(rc_of "dryrun-$n")" == 0 ]] || F+=("DRYRUN:$n.yaml rc=$(rc_of "dryrun-$n")")
  done
  printf 'WORKER_CIDR=%s\nWORKER_COUNT=%s\n' "$WORKER_CIDR" "$worker_count" >>"$PD/context.txt"
  if (( ${#F[@]} )); then printf '%s\n' "${F[@]}" >"$PD/stop.txt"; die 20 "precheck 조건 불충족: $(tr '\n' ';' <"$PD/stop.txt")"; fi
  printf 'CTX=%s\nAPI=%s\nCLUSTER_ID=%s\nNS=%s\nNS_UID=%s\nBUNDLE=%s\nWORKER_COUNT=%s\n' \
    "$CTX" "$API" "$EXPECTED_CLUSTER_ID" "$NS" "$EXPECTED_NS_UID" "$BUNDLE_SHA" "$worker_count" >"$RUN_DIR/target.env"
  chmod 400 "$RUN_DIR/target.env"
  st_add C1 PASS
  printf 'BUNDLE=%s TARGET=%s' "$BUNDLE_SHA" "$(sha_of "$RUN_DIR/target.env")" >"$RUN_DIR/precheck.ok"
  echo "PRECHECK_OK workers=$worker_count cidr=$WORKER_CIDR (클러스터 변경 없음). 창 시작 출발지 목록: $PD/worker-ips.tsv"
  exit 0
fi

# ======================================================================
if [[ "$PHASE" == stage-b ]]; then
  { echo "STAGE_C_REF=$STAGE_C_REF"; echo "T3_REF=$T3_REF"; echo "DB_WINDOW_REF=$DB_WINDOW_REF"; } >>"$RUN_DIR/state.env"
  CREATED="$PD/created.tsv"; : >"$CREATED"
  run ns-inventory "${OC[@]}" -n "$NS" get networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route -o name
  [[ "$(rc_of ns-inventory)" == 0 ]] || die 11 "Namespace inventory 조회 실패"
  [[ ! -s "$PD/ns-inventory.out" ]] || die 20 "precheck 이후 대상 Namespace에 자원이 생김 — 변경 없이 STOP"
  echo "#7 stage-b 시작 $(now_kst) — 재환 님께 카운터 기록 시작 요청 시각" | tee "$PD/notice.txt"
  for n in 10 11 12; do
    apply_and_record "$n" "$CREATED" || die 41 "$n.yaml 적용·기록 불완전(created.tsv 확인). 자동 원복 없음 — cleanup은 OWNED만 정리, UNCONFIRMED는 복구 절차"
  done
  run wait "${OC[@]}" -n "$NS" wait --for=condition=Ready pod/tcp-allowed pod/tcp-control pod/route-probe pod/ingress-probe --timeout=180s
  [[ "$(rc_of wait)" == 0 ]] || die 41 "시험 Pod Ready 실패(180초)"
  run route-probe-ip "${OC[@]}" -n "$NS" get pod route-probe -o 'jsonpath={.status.podIP}'
  [[ "$(rc_of route-probe-ip)" == 0 && "$(out_of route-probe-ip)" =~ $IPV4_RE ]] || die 11 "route-probe Pod IP 조회 실패"
  out_of route-probe-ip >"$PD/route-probe-ip.txt"
  measure B
  for id in P1 N1 N5; do [[ "$(verdict "$id")" == CONNECTED ]] || FAILS+=("$id:$(verdict "$id")(기대 CONNECTED)"); done
  [[ "$REG_MODE" != include || "$(verdict P2)" == CONNECTED ]] || FAILS+=("P2:$(verdict P2)(기대 CONNECTED)")
  [[ "$(verdict P3)" == OK ]] || FAILS+=("P3:DNS FAIL")
  echo "#7 stage-b 측정 끝 $(now_kst)" | tee -a "$PD/notice.txt"
  if (( ${#FAILS[@]} )); then
    printf '%s\n' "${FAILS[@]}" >"$PD/stop.txt"
    die 40 "B 기준 불성립 — 정책 시험으로 넘어가지 않음: $(tr '\n' ';' <"$PD/stop.txt") (경로·#37 T3 상태 확인, cleanup으로 시험 자원 정리)"
  fi
  printf '%s' "$MARK" >"$RUN_DIR/stage-b.ok"
  echo "STAGE_B_OK — 이어서 stage-a (시험 Pod 수명 안에)"
  exit 0
fi

# ======================================================================
if [[ "$PHASE" == stage-a ]]; then
  for p in tcp-allowed tcp-control ingress-probe; do
    run "age-$p" "${OC[@]}" -n "$NS" get pod "$p" -o 'jsonpath={.metadata.uid} {.metadata.creationTimestamp}'
    [[ "$(rc_of "age-$p")" == 0 ]] || die 11 "$p 조회 실패"
    read -r uid ts <"$PD/age-$p.out" || true
    grep -q "^pod/$p"$'\t'"$uid"$'\tOWNED' "$RUN_DIR/stage-b/created.tsv" || die 30 "$p UID가 stage-b OWNED 기록과 다름(재생성 혼입)"
    age=$(( ( $(date -u +%s) - $(date -u -d "$ts" +%s) ) / 60 ))
    (( age < POD_MAX_AGE_MIN )) || die 30 "$p 생성 후 ${age}분 — 수명 한도 ${POD_MAX_AGE_MIN}분 이상(새 RUN으로 다시)"
  done
  echo "#7 stage-a 정책 적용 시작 $(now_kst) — 00 적용~03 적용 사이 DB 경로가 잠깐 막힘(의도)" | tee "$PD/notice.txt"
  NPJ="$PD/np-applied.tsv"; : >"$NPJ"
  set_policy() { printf 'POLICY_SET=%s %s\n' "$1" "$(now_utc)" >"$RUN_DIR/policy-set.txt"; journal POLICY_SET "$1"; }
  set_policy NONE
  applied=0
  for n in 00 01 02 03; do
    if apply_and_record "$n" "$PD/np-objects.tsv"; then
      np="$(expected_objects "$n")"; np="${np#networkpolicy/}"
      run "np-$np" "${OC[@]}" -n "$NS" get networkpolicy "$np" -o 'jsonpath={.metadata.uid}{"\n"}{.spec}'
      [[ "$(rc_of "np-$np")" == 0 ]] || { set_policy PARTIAL; die 11 "$np 조회 실패(EVIDENCE_INCOMPLETE, POLICY_SET=PARTIAL)"; }
      printf '%s\t%s\t%s\tAPPLIED\n' "$np" "$(head -n 1 "$PD/np-$np.out")" "$(tail -n +2 "$PD/np-$np.out" | sha256sum | cut -d' ' -f1)" >>"$NPJ"
      applied=$((applied+1)); set_policy PARTIAL
    else
      (( applied == 0 )) && ! grep -q . "$PD/np-objects.tsv" 2>/dev/null && set_policy NONE || set_policy PARTIAL
      die 41 "$n.yaml 적용·기록 불완전 — $(cat "$RUN_DIR/policy-set.txt" | cut -d' ' -f1). 앱 배포·Handoff READY 금지, 자동 원복 없음"
    fi
  done
  set_policy FULL
  run np-list "${OC[@]}" -n "$NS" get networkpolicy -o name
  [[ "$(rc_of np-list)" == 0 ]] || die 11 "NetworkPolicy 목록 조회 실패"
  printf '%s\n' networkpolicy.networking.k8s.io/{allow-egress-dns,allow-egress-onprem-approved,allow-ingress-from-router,fds-platform-default-deny,probe-egress-to-route} >"$PD/np-expected.txt"
  sort "$PD/np-list.out" >"$PD/np-list.sorted"
  cmp -s "$PD/np-list.sorted" "$PD/np-expected.txt" || die 42 "NetworkPolicy 집합이 계약 5개와 다름(np-list.sorted)"
  run np00-spec "${OC[@]}" -n "$NS" get networkpolicy fds-platform-default-deny -o 'jsonpath={.spec.podSelector}|{.spec.policyTypes}|{.spec.ingress}|{.spec.egress}'
  [[ "$(rc_of np00-spec)" == 0 && "$(out_of np00-spec)" == '{}|["Ingress","Egress"]||' ]] || die 42 "00 spec이 기본 차단 계약과 다름: $(out_of np00-spec)"
  run np-yaml "${OC[@]}" -n "$NS" get networkpolicy -o yaml
  [[ "$(rc_of np-yaml)" == 0 && -s "$PD/np-yaml.out" ]] || die 11 "NetworkPolicy 원본 증적 수집 실패(EVIDENCE_INCOMPLETE)"
  measure A
  echo "#7 stage-a 측정 끝 $(now_kst) — 재환 님께 #7 종료 통보 후 T6 진행" | tee -a "$PD/notice.txt"

  expect P1 CONNECTED
  [[ "$REG_MODE" == include ]] && expect P2 CONNECTED
  [[ "$(verdict P3)" == OK ]] || FAILS+=("P3:DNS FAIL")
  # NetworkPolicy 효과는 B CONNECTED → A TIMEOUT일 때만 주장한다.
  # N2~N4는 B에서 이미 막힐 수 있다(예: Relay SG가 worker 서브넷에서 5432만 허용 — #37 6205733242 Q3).
  # 그때 A TIMEOUT은 "승인 밖은 열려 있지 않음" 기록일 뿐 정책 차단 증거가 아니다(NO_CLAIM_UPSTREAM).
  : >"$PD/np-effect.tsv"
  for id in N1 N2 N3 N4 N5; do
    b="$(bverdict "$id")"; a="$(verdict "$id")"
    if [[ "$a" == CONNECTED ]]; then claim=FAIL_OPEN; FAILS+=("$id:CONNECTED(정책 후 열림)")
    elif [[ "$b" == CONNECTED ]]; then
      if [[ "$a" == TIMEOUT ]]; then claim=NP_EFFECT; else claim=INCONCLUSIVE; INCONCL+=("$id:$a"); fi
    else claim=NO_CLAIM_UPSTREAM; fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$b" "$a" "$claim" >>"$PD/np-effect.tsv"
  done
  r1_code="$(verdict R1)"; r1t="$(r1_tls)"
  r1_ok=NO; [[ "$r1t" == VERIFIED && ",$R1_EXPECTED_CODES," == *",$r1_code,"* ]] && r1_ok=YES
  r2_ok=NO; [[ "$(verdict R2)" == True ]] && r2_ok=YES
  [[ $r1_ok == YES ]] || FAILS+=("R1:TLS=$r1t code=$r1_code(기대 VERIFIED·$R1_EXPECTED_CODES)")
  [[ $r2_ok == YES ]] || FAILS+=("R2:$(verdict R2)(기대 True)")

  # Handoff 8·9 (#4). 실패가 하나라도 있으면 READY를 내지 않는다.
  route_ready=NO; [[ $r1_ok == YES && $r2_ok == YES ]] && route_ready=YES
  hybrid=BLOCKED
  if [[ "$(st C1)" == PASS && "$(verdict P1)" == CONNECTED && "$(bverdict N1)" == CONNECTED && "$(verdict N1)" == TIMEOUT ]] \
     && (( ${#FAILS[@]} == 0 && ${#INCONCL[@]} == 0 )); then hybrid=READY; fi
  {
    echo "ROUTE_READY=$route_ready  # R1(A)=$r1_code TLS=$r1t, R2(A)=$(verdict R2); R1(B)=$(bverdict R1)"
    echo "HYBRID_ROUTE=$hybrid  # C1=$(st C1) P1(A)=$(verdict P1) N1(B→A)=$(bverdict N1)→$(verdict N1)"
    echo "POLICY_SET=FULL"
    echo "NP_EFFECT=$(awk -F'\t' '$4=="NP_EFFECT" {printf "%s%s", s, $1; s=","}' "$PD/np-effect.tsv")  # B CONNECTED→A TIMEOUT만"
    echo "NO_CLAIM_UPSTREAM=$(awk -F'\t' '$4=="NO_CLAIM_UPSTREAM" {printf "%s%s", s, $1; s=","}' "$PD/np-effect.tsv")  # B부터 막힘(SG 등) — 정책 효과 미주장"
    echo "TLS_SERVICE_CHECK=NOT_IMPLEMENTED  # TEST-PLAN §4는 이 실행기 범위 밖(별도 증적 소비)"
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
  policy_set="$( [[ -f "$RUN_DIR/policy-set.txt" ]] && cut -d' ' -f1 "$RUN_DIR/policy-set.txt" | sed 's/^POLICY_SET=//' || echo NONE)"
  # 시험 자원(10·11·12): OWNED만 UID 대조 후 삭제, UNCONFIRMED는 지우지 않는다.
  while IFS=$'\t' read -r r uid status note; do
    [[ -n "$r" ]] || continue
    k="${r//\//-}"
    if [[ "$status" != OWNED ]]; then HOLD+=("$r:UNCONFIRMED($note)"); echo "$r HOLD(미확인 — RUN manifest·실제 UID·작업 주체 대조 복구 절차)" >>"$PD/cleanup.txt"; continue; fi
    run "cur-$k" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
    if [[ "$(rc_of "cur-$k")" != 0 ]]; then
      if grep -q NotFound "$PD/cur-$k.err"; then echo "$r ALREADY_ABSENT $uid" >>"$PD/cleanup.txt"; else HOLD+=("$r:조회 오류"); echo "$r HOLD(조회 오류)" >>"$PD/cleanup.txt"; fi
      continue
    fi
    if [[ "$(out_of "cur-$k")" != "$uid" ]]; then HOLD+=("$r:UID 불일치"); echo "$r HOLD(UID 불일치 $(out_of "cur-$k"))" >>"$PD/cleanup.txt"; continue; fi
    run "del-$k" "${OC[@]}" -n "$NS" delete "$r" --wait=true
    if [[ "$(rc_of "del-$k")" == 0 ]]; then echo "$r DELETED $uid" >>"$PD/cleanup.txt"; else HOLD+=("$r:삭제 실패"); echo "$r HOLD(삭제 실패)" >>"$PD/cleanup.txt"; fi
  done <"$RUN_DIR/stage-b/created.tsv"
  # 플랫폼 정책: 지우지 않는다. 적용 기록(APPLIED)과 UID·spec이 같은지, 미확인 정책이 있는지 본다.
  expected_left="$PD/expected-left.txt"; : >"$expected_left"
  if [[ -f "$RUN_DIR/stage-a/np-applied.tsv" ]]; then
    while IFS=$'\t' read -r np uid sha _; do
      [[ -n "$np" ]] || continue
      echo "networkpolicy.networking.k8s.io/$np" >>"$expected_left"
      run "keep-$np" "${OC[@]}" -n "$NS" get networkpolicy "$np" -o 'jsonpath={.metadata.uid}{"\n"}{.spec}'
      if [[ "$(rc_of "keep-$np")" != 0 ]]; then HOLD+=("$np:조회 실패"); continue; fi
      [[ "$(head -n 1 "$PD/keep-$np.out")" == "$uid" && "$(tail -n +2 "$PD/keep-$np.out" | sha256sum | cut -d' ' -f1)" == "$sha" ]] \
        || HOLD+=("$np:UID/spec 변화")
    done <"$RUN_DIR/stage-a/np-applied.tsv"
  fi
  if [[ -f "$RUN_DIR/stage-a/np-objects.tsv" ]] && grep -q $'\tUNCONFIRMED\t' "$RUN_DIR/stage-a/np-objects.tsv"; then
    HOLD+=("platform-policy:UNCONFIRMED 기록 있음(stage-a/np-objects.tsv)")
  fi
  # 최종 목록: 조회 성공 + 남아야 할 것(적용된 플랫폼 정책)만 있어야 한다.
  run after "${OC[@]}" -n "$NS" get all,networkpolicy,route -o name
  if [[ "$(rc_of after)" != 0 ]]; then HOLD+=("final-inventory:조회 실패")
  else
    sort "$PD/after.out" >"$PD/after.sorted"; sort "$expected_left" -o "$expected_left"
    if (( ${#HOLD[@]} == 0 )) && ! cmp -s "$PD/after.sorted" "$expected_left"; then HOLD+=("final-inventory:예상 잔여와 다름(after.sorted vs expected-left.txt)"); fi
  fi
  echo "POLICY_SET=$policy_set" >>"$PD/cleanup.txt"
  cat "$PD/cleanup.txt"
  if (( ${#HOLD[@]} )); then printf '%s\n' "${HOLD[@]}" >"$PD/hold.txt"; die 60 "CLEANUP=HOLD: $(tr '\n' ';' <"$PD/hold.txt") — 원인 해소 뒤 같은 RUN으로 cleanup 재시도 가능"; fi
  printf '%s %s POLICY_SET=%s' "$(basename "$PD")" "$(now_utc)" "$policy_set" >"$RUN_DIR/cleanup.done"
  if [[ "$policy_set" == PARTIAL ]]; then
    echo "CLEANUP_OK_POLICY_PARTIAL — 시험 자원 정리 완료, 플랫폼 정책 부분 적용 상태: 앱 배포·Handoff READY 금지" >&2
    exit 61
  fi
  echo "CLEANUP_OK — 시험 자원 정리 완료, POLICY_SET=$policy_set"
  exit 0
fi
