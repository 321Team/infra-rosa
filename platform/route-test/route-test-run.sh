#!/usr/bin/env bash
# baseline#38 8행 "Route 생성 가능 상태" — 승인 host 시험 Route 실행기 (infra-rosa#4 Handoff 2 host)
# 계획 baseline#38 6285881794 · 권욱 검토 6286641386 보완 반영. 실행 순서: #7 B/A·정리 뒤, #43 앱 배포 전.
#
# 사용: route-test-run.sh <render|precheck|run|cleanup>   (RUN_DIR 하나에 단계를 차례로)
#   render    로컬만(oc 호출 없음). 승인 입력을 approved-inputs.env로 고정하고 route-host-probe.yaml을 렌더한다.
#             kit·manifest source·#7 02 정책 source·입력 해시를 bundle.txt로 묶는다(BUNDLE_SHA256 = 리뷰 승인값).
#   precheck  읽기 + server dry-run만(클러스터 변경 없음). 대상(API·Cluster ID·NS UID)·본인 일반 계정·권한·
#             fds-app 목록(#7 뒤 남는 정책 4개만)·02 정책(route-exposed=true, TCP 8080)을 확인하고 target.env로 고정.
#   run       시험 자원 3개(Pod·Service·Route) 생성 → Ready → R-1 Admitted·host → R-2 DNS → R-3 HTTPS(TLS 검증)
#             → R-4 HTTP→HTTPS 302 → 진단(실패 시) → R-5 정리(OWNED만 UID 대조 삭제·NotFound·목록 복원).
#             성공·실패와 관계없이 이 RUN이 만든 OWNED 자원은 정리한다(권욱 6286641386 정리 정정).
#   cleanup   run의 정리가 HOLD로 끝났을 때만 같은 RUN에서 다시 시도(cleanup-attempt-N).
#
# 하지 않는 것: DNS·LB·IngressController·인증서·NetworkPolicy 변경, 클러스터 관리자 권한 사용, 다른 namespace,
#   cross-namespace 음성 시험, A-09 재실행, 앱 배포, 이름만 같은 객체·소유 미확정 객체 삭제, 자동 재시도(같은 GO).
#
# 입력
#   공통: RUN_DIR (render는 없어야 함)
#   render: NS(fds-app) TEAM ROUTE_HOST HTTP_IMAGE(<repo>@sha256:<64hex>)
#     선택: EXPECT_HTTPS_CODE(403) EXPECT_HTTP_CODE(302)
#   클러스터 단계: APPROVED_BUNDLE_SHA256
#     precheck만: CTX API(https://host[:port]) EXPECTED_CLUSTER_ID EXPECTED_NS_UID — 이후 단계는 target.env 사용
#   run: GO_REF(실행 GO 기록 댓글 URL) SEVEN_DONE_REF(#7 A·정리 완료 기록 댓글 URL)
#     선택 시간 상한(초): READY_TIMEOUT_S(300) ADMIT_TIMEOUT_S(120) DNS_TIMEOUT_S(300) HTTP_TIMEOUT_S(180)
#
# 종료 코드
#   0 단계 성공(run은 R-1~R-5 모두 PASS)   2 입력 오류(oc 호출 전)   10 대상 불일치(서버·Cluster ID·NS UID·target)
#   11 조회 오류   20 precheck 조건 불충족(관리자 권한·권한 부족·예상 밖 객체·02 정책 불일치·dry-run 실패)
#   21 bundle 불일치   30 단계 순서·조건 위반(이전 단계 없음·이미 실행·목록 변화·REF 없음)
#   41 생성·Ready 실패(정리는 수행·결과 기록)   50 R-1~R-4 중 FAIL(정리는 수행·결과 기록)
#   60 정리 HOLD(UID 불일치·UID precondition 409·미확인·조회 오류·삭제 실패·목록 불일치·정책 변화) — 같은 RUN cleanup 재시도
#
# PR50 리뷰(권욱) 반영: R1 DELETE에 UID precondition, R2 명령별 바깥 실행 상한(rc 124/137 기록),
#   R3 custom-host는 --subresource로 권한 질의, R4 run·cleanup은 precheck와 같은 사용자만
#   (cleanup은 RECOVERY_USER·RECOVERY_REF로 명시한 복구 인수 주체만 예외).
set -euo pipefail
umask 077

die() { local rc="$1"; shift; echo "STOP: $*" >&2; exit "$rc"; }

PHASE="${1:-}"
case "$PHASE" in render|precheck|run|cleanup) ;; *) die 2 "사용: $0 <render|precheck|run|cleanup>";; esac
for c in sha256sum date awk sed grep sort cmp realpath mkdir timeout; do command -v "$c" >/dev/null || die 2 "명령 없음: $c"; done

SELF="$(realpath "${BASH_SOURCE[0]}")"
SRC_DIR="$(dirname "$SELF")"
SRC_ROOT="$(realpath "$SRC_DIR/../..")"
MANIFEST_SRC="$SRC_DIR/route-host-probe.yaml"
NP02_SRC="$SRC_ROOT/platform/netpol/02-allow-ingress-router.yaml"
SELF_SHA="$(sha256sum "$SELF" | cut -d' ' -f1)"
RUN_DIR="${RUN_DIR:-}"
[[ -n "$RUN_DIR" && "$RUN_DIR" != *$'\n'* ]] || die 2 "RUN_DIR 필요"
EXEC_TIMEOUT_S="${ROUTE_EXEC_TIMEOUT_S:-60}"
[[ "$EXEC_TIMEOUT_S" =~ ^[0-9]+$ ]] && (( EXEC_TIMEOUT_S >= 1 && EXEC_TIMEOUT_S <= 300 )) || die 2 "ROUTE_EXEC_TIMEOUT_S 1~300"
POLL_S="${ROUTE_POLL_S:-10}"
CERT_TIMEOUT_S="${ROUTE_CERT_TIMEOUT_S:-15}"
[[ "$CERT_TIMEOUT_S" =~ ^[0-9]+$ ]] && (( CERT_TIMEOUT_S >= 1 && CERT_TIMEOUT_S <= 60 )) || die 2 "ROUTE_CERT_TIMEOUT_S 1~60"
left() { local l=$(( $1 - $(date +%s) )); (( l >= 1 )) && echo "$l" || echo 1; }   # deadline까지 남은 초(최소 1)
[[ "$POLL_S" =~ ^[0-9]+$ ]] && (( POLL_S <= 60 )) || die 2 "ROUTE_POLL_S 0~60"

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
IMG_RE='^[A-Za-z0-9][A-Za-z0-9./:_-]*@sha256:[0-9a-f]{64}$'
HOST_RE='^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
REF_RE='^https://github\.com/321Team/[A-Za-z0-9._-]+/(issues|pull)/[0-9]+#issuecomment-[0-9]+$'
SHA_RE='^[0-9a-f]{64}$'
OBJS=(pod/route-host-probe service/route-host-probe route/route-host-probe)
# #7 뒤 fds-app에 남는 플랫폼 정책 4개(infra-rosa#7 00~03). 시작 목록은 이것만이어야 한다.
KEEP_NPS=(fds-platform-default-deny allow-egress-dns allow-ingress-from-router allow-egress-onprem-approved)

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_kst() { TZ=KST-9 date +%Y-%m-%dT%H:%M:%S%z; }
kv() { awk -F= -v k="$2" '$1==k {n++; sub(/^[^=]*=/, ""); v=$0} END {if (n==1) print v}' "$1"; }
ai() { kv "$RUN_DIR/approved-inputs.env" "$1"; }
journal() { printf '%s\t%s\t%s\t%s\n' "$(now_utc)" "$PHASE" "$1" "${2:-}" >>"$RUN_DIR/journal.tsv"; }

validate_inputs() { # rc
  local rc="$1"
  (( ${#NS} <= 63 )) && [[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$rc" "NS는 DNS-1123 label"
  [[ ! "$NS" =~ ^(openshift|kube)(-|$) && "$NS" != default ]] || die "$rc" "System namespace는 대상 아님"
  [[ "$TEAM" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$rc" "TEAM 형식 오류"
  (( ${#ROUTE_HOST} <= 253 )) && [[ "$ROUTE_HOST" =~ $HOST_RE ]] || die "$rc" "ROUTE_HOST는 소문자 FQDN(승인 host 1개)"
  [[ "$ROUTE_HOST" != \*.* ]] || die "$rc" "wildcard host 금지"
  [[ "$HTTP_IMAGE" =~ $IMG_RE ]] || die "$rc" "HTTP_IMAGE는 @sha256:<64hex> 고정"
  [[ "$EXPECT_HTTPS_CODE" =~ ^[1-5][0-9]{2}$ && "$EXPECT_HTTP_CODE" =~ ^3[0-9]{2}$ ]] || die "$rc" "EXPECT_HTTPS_CODE(3자리)·EXPECT_HTTP_CODE(3xx) 형식 오류"
}
INPUT_KEYS=(NS TEAM ROUTE_HOST HTTP_IMAGE EXPECT_HTTPS_CODE EXPECT_HTTP_CODE)

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

# 모든 명령에 바깥 실행 상한을 건다(PR50 R2). RUN_LIMIT(초)를 호출 앞에 주면 그 값, 없으면 EXEC_TIMEOUT_S+15.
# 상한 초과는 rc 124(TERM) / 137(KILL, TERM 뒤 5초)로 기록된다. oc --request-timeout은 oc 요청에만 적용된다.
run() {
  local name="$1"; shift
  local start rc lim="${RUN_LIMIT:-$(( EXEC_TIMEOUT_S + 15 ))}"; start="$(now_utc)"
  (( lim >= 1 )) || lim=1
  set +e
  timeout --signal=TERM --kill-after=5s "${lim}s" "$@" >"$PD/$name.out" 2>"$PD/$name.err"
  rc=$?
  set -e
  echo "$rc" >"$PD/$name.rc"
  # 토큰·kubeconfig 내용은 argv에 넣지 않는다(context 이름·URL·자원 이름만).
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$start" "$(now_utc)" "$rc" "$name" "limit=${lim}s" "$(printf '%q ' "$@")" >>"$PD/commands.tsv"
  return 0
}
rc_of() { cat "$PD/$1.rc"; }
out_of() { cat "$PD/$1.out"; }

# ======================================================================
if [[ "$PHASE" == render ]]; then
  NS="${NS:-}"; TEAM="${TEAM:-}"; ROUTE_HOST="${ROUTE_HOST:-}"; HTTP_IMAGE="${HTTP_IMAGE:-}"
  EXPECT_HTTPS_CODE="${EXPECT_HTTPS_CODE:-403}"; EXPECT_HTTP_CODE="${EXPECT_HTTP_CODE:-302}"
  validate_inputs 2
  [[ -f "$MANIFEST_SRC" && -f "$NP02_SRC" ]] || die 2 "source 없음: route-host-probe.yaml 또는 platform/netpol/02-allow-ingress-router.yaml"
  [[ ! -e "$RUN_DIR" ]] || die 2 "RUN_DIR이 이미 있음(덮어쓰지 않음)"
  mkdir -p -m 700 -- "$RUN_DIR"
  RUN_DIR="$(realpath "$RUN_DIR")"
  open_phase
  for k in "${INPUT_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done >"$RUN_DIR/approved-inputs.env"
  R="$RUN_DIR/manifests"; mkdir -m 700 "$R"
  sed -e "s|__NS__|$NS|g" -e "s|__TEAM__|$TEAM|g" -e "s|__ROUTE_HOST__|$ROUTE_HOST|g" -e "s|__HTTP_IMAGE__|$HTTP_IMAGE|g" \
    "$MANIFEST_SRC" >"$R/route-host-probe.yaml"
  if grep -n '__[A-Z_]*__' "$R/route-host-probe.yaml" >"$PD/placeholder-left.txt"; then die 21 "자리표시자 남음"; fi
  # #7 02 정책과의 결속: 02가 route-exposed=true·TCP 8080을 허용하고, 시험 Pod·Service가 같은 값을 쓰는지 정적으로 본다.
  grep -q 'route-exposed: "true"' "$NP02_SRC" && grep -q 'port: 8080' "$NP02_SRC" || die 21 "02 정책 source가 route-exposed=true·TCP 8080 계약과 다름"
  [[ "$(grep -c 'route-exposed: "true"' "$R/route-host-probe.yaml")" == 1 ]] || die 21 "시험 Pod label route-exposed=true가 정확히 1개가 아님"
  [[ "$(grep -c 'containerPort: 8080' "$R/route-host-probe.yaml")" == 1 && "$(grep -c 'targetPort: 8080' "$R/route-host-probe.yaml")" == 1 ]] || die 21 "컨테이너·Service targetPort 8080 고정이 아님"
  [[ "$(grep -c "host: $ROUTE_HOST\$" "$R/route-host-probe.yaml")" == 1 ]] || die 21 "Route host가 승인값 1개와 다름"
  if grep -nE '^\s*(certificate|key|caCertificate|destinationCACertificate|externalCertificate):' "$R/route-host-probe.yaml" >"$PD/tls-fields.txt"; then die 21 "Route에 인증서 필드가 있음(기본 apps 인증서만 사용)"; fi
  ( cd "$R" && sha256sum route-host-probe.yaml >SHA256SUMS )
  {
    echo "KIT_SHA256=$SELF_SHA"
    echo "SOURCE_GIT_HEAD=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "SOURCE_MANIFEST_SHA256=$(sha_of "$MANIFEST_SRC")"
    echo "SOURCE_NP02_SHA256=$(sha_of "$NP02_SRC")"
    echo "MANIFEST_SUMS_SHA256=$(sha_of "$R/SHA256SUMS")"
    echo "INPUTS_SHA256=$(sha_of "$RUN_DIR/approved-inputs.env")"
  } >"$RUN_DIR/bundle.txt"
  chmod 400 "$RUN_DIR/approved-inputs.env" "$RUN_DIR/bundle.txt" "$R"/*
  BUNDLE_SHA="$(sha_of "$RUN_DIR/bundle.txt")"
  printf 'RENDERED_AT_KST=%s\nBUNDLE_SHA256=%s\n' "$(now_kst)" "$BUNDLE_SHA" >"$RUN_DIR/state.env"
  echo "RENDER_OK BUNDLE_SHA256=$BUNDLE_SHA"
  echo "다음: 승인값을 APPROVED_BUNDLE_SHA256로 precheck 실행"
  exit 0
fi

# ======================================================================
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

case "$PHASE" in
  precheck) [[ ! -e "$RUN_DIR/precheck" ]] || die 30 "precheck는 RUN당 1회(이미 실행됨)" ;;
  run) [[ -f "$RUN_DIR/precheck.ok" ]] || die 30 "precheck PASS 기록 없음" ;;
  cleanup)
    [[ -f "$RUN_DIR/run/created.tsv" ]] || die 30 "이 RUN의 run 생성 기록 없음(정리할 것 없음)"
    [[ ! -f "$RUN_DIR/cleanup.done" ]] || die 30 "이 RUN의 정리는 이미 완료됨: $(cat "$RUN_DIR/cleanup.done")" ;;
esac

if [[ "$PHASE" == precheck ]]; then
  CTX="${CTX:-}"; API="${API:-}"; EXPECTED_CLUSTER_ID="${EXPECTED_CLUSTER_ID:-}"; EXPECTED_NS_UID="${EXPECTED_NS_UID:-}"
  [[ -n "$CTX" && "$CTX" != *$'\n'* && "$CTX" != *=* ]] || die 2 "CTX 필요"
  [[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die 2 "API는 https://host[:port]"
  [[ "$EXPECTED_CLUSTER_ID" =~ $UUID_RE && "$EXPECTED_NS_UID" =~ $UUID_RE ]] || die 2 "EXPECTED_CLUSTER_ID/EXPECTED_NS_UID는 승인 inventory의 UUID"
else
  [[ -f "$RUN_DIR/target.env" ]] || die 30 "target.env 없음(precheck 먼저)"
  for pair in "CTX:CTX" "API:API" "EXPECTED_CLUSTER_ID:CLUSTER_ID" "EXPECTED_NS_UID:NS_UID"; do
    ev="${pair%%:*}"; tk="${pair#*:}"
    if [[ -n "${!ev:-}" && "${!ev}" != "$(kv "$RUN_DIR/target.env" "$tk")" ]]; then die 10 "$ev가 precheck에서 고정한 대상과 다름"; fi
  done
  CTX="$(kv "$RUN_DIR/target.env" CTX)"; API="$(kv "$RUN_DIR/target.env" API)"
  EXPECTED_CLUSTER_ID="$(kv "$RUN_DIR/target.env" CLUSTER_ID)"; EXPECTED_NS_UID="$(kv "$RUN_DIR/target.env" NS_UID)"
  [[ "$(kv "$RUN_DIR/target.env" BUNDLE)" == "$BUNDLE_SHA" ]] || die 30 "target.env가 다른 bundle에서 만들어짐"
  [[ "$(cat "$RUN_DIR/precheck.ok")" == "BUNDLE=$BUNDLE_SHA TARGET=$(sha_of "$RUN_DIR/target.env")" ]] || die 30 "precheck.ok가 현재 bundle·대상과 다름"
fi

if [[ "$PHASE" == run ]]; then
  [[ ! -e "$RUN_DIR/run" ]] || die 30 "run은 RUN당 1회(이미 실행됨) — 정리만 남았으면 cleanup"
  GO_REF="${GO_REF:-}"; SEVEN_DONE_REF="${SEVEN_DONE_REF:-}"
  [[ "$GO_REF" =~ $REF_RE ]] || die 30 "GO_REF 필요(실행 GO 기록 댓글 URL) — 없으면 시작하지 않음"
  [[ "$SEVEN_DONE_REF" =~ $REF_RE ]] || die 30 "SEVEN_DONE_REF 필요(#7 A·정리 완료 기록 댓글 URL) — 없으면 시작하지 않음"
  READY_TIMEOUT_S="${READY_TIMEOUT_S:-300}"; ADMIT_TIMEOUT_S="${ADMIT_TIMEOUT_S:-120}"
  DNS_TIMEOUT_S="${DNS_TIMEOUT_S:-300}"; HTTP_TIMEOUT_S="${HTTP_TIMEOUT_S:-180}"
  for v in READY_TIMEOUT_S ADMIT_TIMEOUT_S DNS_TIMEOUT_S HTTP_TIMEOUT_S; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} >= 1 && ${!v} <= 900 )) || die 2 "$v 1~900"
  done
  for c in curl getent; do command -v "$c" >/dev/null || die 2 "명령 없음: $c(R-2·R-3·R-4)"; done
fi

open_phase

# ---- 대상 확인 (모든 클러스터 단계 공통, 첫 변경 전) ----
run ctx-server oc config view --minify --context="$CTX" -o 'jsonpath={.clusters[0].cluster.server}'
[[ "$(rc_of ctx-server)" == 0 && "$(out_of ctx-server)" == "$API" ]] || die 10 "CTX의 서버가 API와 다름(첫 API 요청 전 중단)"
OC=(oc --request-timeout="${EXEC_TIMEOUT_S}s" --context="$CTX" --server="$API" --insecure-skip-tls-verify=false)
run cluster-id "${OC[@]}" get clusterversion version -o 'jsonpath={.spec.clusterID}'
if [[ "$(rc_of cluster-id)" == 0 ]]; then
  [[ "$(out_of cluster-id)" == "$EXPECTED_CLUSTER_ID" ]] || die 10 "Cluster ID가 승인 inventory와 다름"
  CLUSTER_ID_CHECK=MATCH
elif grep -q 'Forbidden' "$PD/cluster-id.err"; then
  # 본인 일반 계정은 clusterversion 읽기 권한이 없을 수 있다. 새 clusterwide 읽기 권한을 요구하지 않고(6286641386)
  # API URL(CTX 서버 대조)과 NS UID로 대상을 고정하며, 이 사실을 그대로 기록한다.
  CLUSTER_ID_CHECK=UNREADABLE_FORBIDDEN
else
  die 11 "Cluster ID 조회 오류(Forbidden 아님)"
fi
run ns-uid "${OC[@]}" get project "$NS" -o 'jsonpath={.metadata.uid}'
[[ "$(rc_of ns-uid)" == 0 && "$(out_of ns-uid)" == "$EXPECTED_NS_UID" ]] || die 10 "Namespace(project) UID가 승인 inventory와 다르거나 조회 불가"
run whoami "${OC[@]}" whoami
[[ "$(rc_of whoami)" == 0 && -n "$(out_of whoami)" ]] || die 11 "whoami 조회 오류"
# precheck에서 확인한 일반 사용자와 같은 인증 주체만 생성·삭제한다(PR50 R4). 첫 변경 전에 확인.
if [[ "$PHASE" != precheck ]]; then
  if [[ "$(out_of whoami)" != "$(kv "$RUN_DIR/target.env" USER)" ]]; then
    # cleanup만, 명시된 복구 인수 주체(RECOVERY_USER = 현재 사용자, RECOVERY_REF = 인수 기록 댓글 URL)를 허용한다.
    if [[ "$PHASE" == cleanup && -n "${RECOVERY_USER:-}" && "${RECOVERY_USER}" == "$(out_of whoami)" && "${RECOVERY_REF:-}" =~ $REF_RE ]]; then
      printf 'RECOVERY_USER=%s\nRECOVERY_REF=%s\n' "$RECOVERY_USER" "$RECOVERY_REF" >"$PD/recovery-actor.txt"
    else
      die 10 "현재 사용자($(out_of whoami))가 precheck 사용자($(kv "$RUN_DIR/target.env" USER))와 다름 — 변경 전 중단"
    fi
  fi
fi
run oc-client oc version --client
{
  echo "ENV=ROSA"; echo "PHASE=$PHASE"; echo "KST=$(now_kst)"; echo "CTX=$CTX"; echo "API=$API"
  echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID CLUSTER_ID_CHECK=$CLUSTER_ID_CHECK"; echo "NS=$NS"; echo "NAMESPACE_UID=$EXPECTED_NS_UID"
  echo "USER=$(out_of whoami)"; echo "BUNDLE_SHA256=$BUNDLE_SHA"; echo "KIT_SHA256=$SELF_SHA"
  echo "OC_CLIENT=$(head -n 1 "$PD/oc-client.out" 2>/dev/null)"; echo "BASH=$BASH_VERSION"
} >"$PD/context.txt"

# fds-app 목록: 워크로드·서비스·Route·NetworkPolicy 이름(정렬). 시작 전·정리 후 같아야 한다.
INV_KINDS='networkpolicy,pod,deployment,statefulset,daemonset,replicaset,job,cronjob,service,route'
inventory() { # name -> $PD/name.sorted
  run "$1" "${OC[@]}" -n "$NS" get "$INV_KINDS" -o name
  [[ "$(rc_of "$1")" == 0 ]] || return 1
  sort "$PD/$1.out" >"$PD/$1.sorted"
}
np_snapshot() { # out
  local np
  : >"$1"
  for np in "${KEEP_NPS[@]}"; do
    run "np-$np" "${OC[@]}" -n "$NS" get networkpolicy "$np" -o 'jsonpath={.metadata.uid}{"\n"}{.spec}'
    [[ "$(rc_of "np-$np")" == 0 ]] || return 1
    printf '%s\t%s\t%s\n' "$np" "$(head -n 1 "$PD/np-$np.out")" "$(tail -n +2 "$PD/np-$np.out" | sha256sum | cut -d' ' -f1)" >>"$1"
  done
}

# ======================================================================
if [[ "$PHASE" == precheck ]]; then
  STOPS=()
  # 본인 일반 계정: 클러스터 관리자 권한으로 실행하지 않는다.
  run cani-admin "${OC[@]}" auth can-i '*' '*' --all-namespaces
  [[ "$(out_of cani-admin)" == no ]] || STOPS+=("클러스터 관리자 권한 계정(can-i * * = $(out_of cani-admin)) — 본인 일반 계정으로 실행")
  for res in pods services routes; do
    k="cani-$res"
    run "$k" "${OC[@]}" -n "$NS" auth can-i create "$res"
    [[ "$(out_of "$k")" == yes ]] || STOPS+=("$res create 권한 없음")
  done
  # routes/custom-host는 subresource로 묻는다(TYPE/NAME 형식은 이름 조회로 해석됨 — PR50 R3).
  run cani-routes-custom-host "${OC[@]}" -n "$NS" auth can-i create routes.route.openshift.io --subresource=custom-host
  [[ "$(rc_of cani-routes-custom-host)" == 0 && "$(out_of cani-routes-custom-host)" == yes ]] || STOPS+=("routes/custom-host create 권한 없음")
  for res in pods services routes; do
    k="cani-del-$res"
    run "$k" "${OC[@]}" -n "$NS" auth can-i delete "$res"
    [[ "$(out_of "$k")" == yes ]] || STOPS+=("$res delete 권한 없음(정리 불가)")
  done
  inventory inv-before || die 11 "fds-app 목록 조회 오류"
  printf 'networkpolicy.networking.k8s.io/%s\n' "${KEEP_NPS[@]}" | sort >"$PD/inv-expected.sorted"
  cmp -s "$PD/inv-before.sorted" "$PD/inv-expected.sorted" || STOPS+=("fds-app 목록이 '#7 뒤 정책 4개만'이 아님(diff: inv-before.sorted vs inv-expected.sorted) — #7 정리·앱 배포 상태 확인")
  # #7 02 정책 실측: route-exposed=true Pod에 router namespace TCP 8080
  run np02-live "${OC[@]}" -n "$NS" get networkpolicy allow-ingress-from-router \
    -o 'jsonpath={.spec.podSelector.matchLabels.route-exposed}|{.spec.ingress[*].ports[*].protocol}|{.spec.ingress[*].ports[*].port}'
  [[ "$(rc_of np02-live)" == 0 && "$(out_of np02-live)" == "true|TCP|8080" ]] || STOPS+=("02 정책 실측이 route-exposed=true·TCP 8080이 아님($(out_of np02-live))")
  np_snapshot "$PD/np-before.tsv" || STOPS+=("플랫폼 정책 4개 조회 오류")
  run dryrun "${OC[@]}" create --dry-run=server -f "$R/route-host-probe.yaml" -o name
  [[ "$(rc_of dryrun)" == 0 ]] || STOPS+=("server dry-run 실패: $(head -c 300 "$PD/dryrun.err" | tr '\n' ' ')")
  if (( ${#STOPS[@]} )); then printf '%s\n' "${STOPS[@]}" >"$PD/stop.txt"; die 20 "precheck 불충족: $(tr '\n' ';' <"$PD/stop.txt")"; fi
  {
    echo "CTX=$CTX"; echo "API=$API"; echo "CLUSTER_ID=$EXPECTED_CLUSTER_ID"; echo "CLUSTER_ID_CHECK=$CLUSTER_ID_CHECK"
    echo "NS_UID=$EXPECTED_NS_UID"; echo "USER=$(out_of whoami)"; echo "BUNDLE=$BUNDLE_SHA"
    echo "INV_BEFORE_SHA256=$(sha_of "$PD/inv-before.sorted")"; echo "NP_BEFORE_SHA256=$(sha_of "$PD/np-before.tsv")"
  } >"$RUN_DIR/target.env"
  chmod 400 "$RUN_DIR/target.env"
  printf 'BUNDLE=%s TARGET=%s' "$BUNDLE_SHA" "$(sha_of "$RUN_DIR/target.env")" >"$RUN_DIR/precheck.ok"
  echo "PRECHECK_PASS user=$(out_of whoami) cluster_id_check=$CLUSTER_ID_CHECK — 다음: GO_REF·SEVEN_DONE_REF로 run"
  exit 0
fi

# ======================================================================
# 정리: run이 OWNED로 기록한 자원만 UID 대조 후 삭제 → NotFound → 목록·정책 복원 확인. 소유 미확정은 지우지 않는다.
do_cleanup() { # sets CLEAN_RESULT=DONE|HOLD
  local r uid status note k i gone uri
  local HOLD=()
  : >"$PD/cleanup.txt"
  while IFS=$'\t' read -r r uid status note; do
    [[ -n "$r" ]] || continue
    k="${r//\//-}"
    if [[ "$status" != OWNED ]]; then HOLD+=("$r:소유 미확정($note)"); echo "$r HOLD(소유 미확정 — 지우지 않고 담당자 인계)" >>"$PD/cleanup.txt"; continue; fi
    run "cur-$k" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
    if [[ "$(rc_of "cur-$k")" != 0 ]]; then
      if grep -q NotFound "$PD/cur-$k.err"; then echo "$r ALREADY_ABSENT $uid" >>"$PD/cleanup.txt"; else HOLD+=("$r:조회 오류"); echo "$r HOLD(조회 오류)" >>"$PD/cleanup.txt"; fi
      continue
    fi
    if [[ "$(out_of "cur-$k")" != "$uid" ]]; then HOLD+=("$r:UID 불일치"); echo "$r HOLD(UID 불일치 $(out_of "cur-$k") — 이름만 같은 객체, 지우지 않음)" >>"$PD/cleanup.txt"; continue; fi
    # 조회와 삭제 사이에 같은 이름으로 재생성된 객체를 지우지 않도록, 서버 DELETE에 기록 UID를 precondition으로 건다
    # (PR50 R1). UID가 다르면 서버가 409로 거부한다 → HOLD.
    case "$r" in
      pod/*) uri="/api/v1/namespaces/$NS/pods/${r#*/}" ;;
      service/*) uri="/api/v1/namespaces/$NS/services/${r#*/}" ;;
      route/*) uri="/apis/route.openshift.io/v1/namespaces/$NS/routes/${r#*/}" ;;
      *) HOLD+=("$r:알 수 없는 종류"); echo "$r HOLD(알 수 없는 종류)" >>"$PD/cleanup.txt"; continue ;;
    esac
    printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}\n' "$uid" >"$PD/delete-options-$k.json"
    RUN_LIMIT=60 run "del-$k" "${OC[@]}" delete --raw="$uri" -f "$PD/delete-options-$k.json"
    if [[ "$(rc_of "del-$k")" != 0 ]]; then
      if grep -qiE 'Conflict|Precondition failed|409' "$PD/del-$k.err"; then HOLD+=("$r:UID precondition 거부(409)"); echo "$r HOLD(UID precondition 거부 — 다른 UID 객체, 지우지 않음)" >>"$PD/cleanup.txt"
      else HOLD+=("$r:삭제 실패"); echo "$r HOLD(삭제 실패 rc=$(rc_of "del-$k"))" >>"$PD/cleanup.txt"; fi
      continue
    fi
    gone=no
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do   # pod 종료 대기 포함(최대 약 12 × POLL_S)
      run "gone-$k-$i" "${OC[@]}" -n "$NS" get "$r" -o 'jsonpath={.metadata.uid}'
      if [[ "$(rc_of "gone-$k-$i")" != 0 ]] && grep -q NotFound "$PD/gone-$k-$i.err"; then gone=yes; break; fi
      if [[ "$(rc_of "gone-$k-$i")" == 0 && "$(out_of "gone-$k-$i")" != "$uid" ]]; then gone=other; break; fi
      sleep "$POLL_S"
    done
    case $gone in
      yes) echo "$r DELETED $uid NotFound" >>"$PD/cleanup.txt" ;;
      other) HOLD+=("$r:같은 이름의 다른 UID 객체 존재"); echo "$r HOLD(기록 UID는 사라졌으나 같은 이름의 다른 UID $(out_of "gone-$k-$i") 존재 — 지우지 않음)" >>"$PD/cleanup.txt" ;;
      *) HOLD+=("$r:삭제 후 NotFound 확인 안 됨"); echo "$r HOLD(NotFound 미확인)" >>"$PD/cleanup.txt" ;;
    esac
  done <"$RUN_DIR/run/created.tsv"
  if inventory inv-after; then
    if [[ "$(sha_of "$PD/inv-after.sorted")" == "$(kv "$RUN_DIR/target.env" INV_BEFORE_SHA256)" ]]; then echo "INVENTORY RESTORED" >>"$PD/cleanup.txt"
    else HOLD+=("fds-app 목록이 시작 전과 다름"); echo "INVENTORY DIFFERS (inv-after.sorted vs precheck/inv-before.sorted)" >>"$PD/cleanup.txt"; fi
  else HOLD+=("정리 후 목록 조회 오류"); fi
  if np_snapshot "$PD/np-after.tsv"; then
    if [[ "$(sha_of "$PD/np-after.tsv")" == "$(kv "$RUN_DIR/target.env" NP_BEFORE_SHA256)" ]]; then echo "PLATFORM_NP UNCHANGED" >>"$PD/cleanup.txt"
    else HOLD+=("플랫폼 정책 UID·spec 변화"); echo "PLATFORM_NP CHANGED" >>"$PD/cleanup.txt"; fi
  else HOLD+=("플랫폼 정책 조회 오류"); fi
  if (( ${#HOLD[@]} )); then
    printf '%s\n' "${HOLD[@]}" >"$PD/hold.txt"; CLEAN_RESULT=HOLD
  else
    printf '%s %s' "$(basename "$PD")" "$(now_utc)" >"$RUN_DIR/cleanup.done"; CLEAN_RESULT=DONE
  fi
}

if [[ "$PHASE" == cleanup ]]; then
  do_cleanup
  cat "$PD/cleanup.txt"
  [[ "$CLEAN_RESULT" == DONE ]] || die 60 "CLEANUP=HOLD: $(tr '\n' ';' <"$PD/hold.txt") — 원인 해소 뒤 같은 RUN으로 cleanup 재시도"
  echo "CLEANUP_DONE — 앱 배포 전 정리 완료"
  exit 0
fi

# ======================================================================
# run
printf 'GO_REF=%s\nSEVEN_DONE_REF=%s\nREADY_TIMEOUT_S=%s\nADMIT_TIMEOUT_S=%s\nDNS_TIMEOUT_S=%s\nHTTP_TIMEOUT_S=%s\n' \
  "$GO_REF" "$SEVEN_DONE_REF" "$READY_TIMEOUT_S" "$ADMIT_TIMEOUT_S" "$DNS_TIMEOUT_S" "$HTTP_TIMEOUT_S" >"$PD/run-inputs.txt"
inventory inv-start || die 11 "fds-app 목록 조회 오류(생성 전)"
[[ "$(sha_of "$PD/inv-start.sorted")" == "$(kv "$RUN_DIR/target.env" INV_BEFORE_SHA256)" ]] || die 30 "fds-app 목록이 precheck 뒤 바뀜 — 새 precheck(새 RUN) 필요"
np_snapshot "$PD/np-start.tsv" || die 11 "플랫폼 정책 조회 오류(생성 전)"
[[ "$(sha_of "$PD/np-start.tsv")" == "$(kv "$RUN_DIR/target.env" NP_BEFORE_SHA256)" ]] || die 30 "플랫폼 정책 4개가 precheck 뒤 바뀜"

: >"$PD/results.tsv"
res() { printf '%s\t%s\t%s\t%s\n' "$1" "$(now_utc)" "$2" "$3" >>"$PD/results.tsv"; }   # id verdict detail
CREATED="$PD/created.tsv"; : >"$CREATED"
FINAL_RC=0

# 1) 생성(oc create — 기존 객체를 덮어쓰지 않는다). 출력에 나온 이름 + UID 조회로 OWNED를 기록.
run create "${OC[@]}" create -f "$R/route-host-probe.yaml" -o name
for o in "${OBJS[@]}"; do
  k="uid-${o//\//-}"
  run "$k" "${OC[@]}" -n "$NS" get "$o" -o 'jsonpath={.metadata.uid}'
  listed=no
  case "$o" in route/*) grep -qx "route.route.openshift.io/${o#route/}" "$PD/create.out" && listed=yes;; *) grep -qx "$o" "$PD/create.out" && listed=yes;; esac
  if [[ "$(rc_of "$k")" == 0 && "$(out_of "$k")" =~ $UUID_RE ]]; then
    if [[ $listed == yes ]]; then printf '%s\t%s\tOWNED\tcreate\n' "$o" "$(out_of "$k")" >>"$CREATED"
    else printf '%s\t%s\tUNCONFIRMED\tcreate 출력에 없음\n' "$o" "$(out_of "$k")" >>"$CREATED"; fi
  elif ! grep -q NotFound "$PD/$k.err"; then
    printf '%s\t-\tUNCONFIRMED\tUID 조회 오류\n' "$o" >>"$CREATED"
  fi
done
journal CREATED "$(tr '\n' ';' <"$CREATED")"
diag() { # 실패 원본 보존(정리 전)
  run diag-describe "${OC[@]}" -n "$NS" describe pod/route-host-probe service/route-host-probe route/route-host-probe
  run diag-endpoints "${OC[@]}" -n "$NS" get endpoints route-host-probe -o yaml
  run diag-route "${OC[@]}" -n "$NS" get route route-host-probe -o yaml
  run diag-events "${OC[@]}" -n "$NS" get events --sort-by=.lastTimestamp
}

TESTS=yes
if [[ "$(rc_of create)" != 0 || "$(grep -c $'\tOWNED\t' "$CREATED")" != 3 ]]; then
  res CREATE FAIL "create rc=$(rc_of create), OWNED=$(grep -c $'\tOWNED\t' "$CREATED")/3"; TESTS=no; FINAL_RC=41
else
  res CREATE PASS "OWNED 3/3"
  # 2) image pull·Ready
  RUN_LIMIT=$(( READY_TIMEOUT_S + 30 )) run ready "${OC[@]}" -n "$NS" wait --for=condition=Ready pod/route-host-probe --timeout="${READY_TIMEOUT_S}s"
  run pod-image "${OC[@]}" -n "$NS" get pod route-host-probe -o 'jsonpath={.status.containerStatuses[0].imageID}{"\t"}{.spec.nodeName}'
  if [[ "$(rc_of ready)" != 0 ]]; then res READY FAIL "wait rc=$(rc_of ready)"; TESTS=no; FINAL_RC=41
  elif [[ "$(cut -f1 "$PD/pod-image.out")" != *"@${HTTP_IMAGE#*@}" ]]; then res READY FAIL "imageID가 승인 digest와 다름: $(cut -f1 "$PD/pod-image.out")"; TESTS=no; FINAL_RC=41
  else res READY PASS "node=$(cut -f2 "$PD/pod-image.out") digest=승인값"; fi
fi

if [[ $TESTS == yes ]]; then
  # R-1 Admitted·host(정확히 승인값), routerCanonicalHostname·reason 기록
  deadline=$(( $(date +%s) + ADMIT_TIMEOUT_S )); i=0; adm=""
  while :; do
    i=$((i+1))
    run "r1-$i" "${OC[@]}" -n "$NS" get route route-host-probe \
      -o 'jsonpath={.spec.host}|{.status.ingress[0].host}|{.status.ingress[0].routerName}|{.status.ingress[0].routerCanonicalHostname}|{.status.ingress[0].conditions[?(@.type=="Admitted")].status}|{.status.ingress[0].conditions[?(@.type=="Admitted")].reason}'
    IFS='|' read -r spec_host st_host router canon adm reason <"$PD/r1-$i.out" || true
    [[ "$(rc_of "r1-$i")" == 0 && -n "$adm" ]] && break
    (( $(date +%s) >= deadline )) && break
    sleep "$POLL_S"
  done
  if [[ "$(rc_of "r1-$i")" == 0 && "$adm" == True && "$spec_host" == "$ROUTE_HOST" && "$st_host" == "$ROUTE_HOST" ]]; then
    res R-1 PASS "Admitted=True host=$spec_host router=$router canonical=$canon"
  else
    res R-1 FAIL "rc=$(rc_of "r1-$i") Admitted=${adm:-none} reason=${reason:-none} spec.host=${spec_host:-} status.host=${st_host:-}"; FINAL_RC=50
  fi
  # R-2 DNS: 승인 host와 router canonical 이름이 같은 IPv4 집합으로 해석되는지(runner에서)
  if [[ -n "${canon:-}" && "$canon" =~ $HOST_RE ]]; then
    deadline=$(( $(date +%s) + DNS_TIMEOUT_S )); i=0
    while :; do
      i=$((i+1))
      RUN_LIMIT="$(left "$deadline")" run "r2-host-$i" getent ahostsv4 "$ROUTE_HOST"
      RUN_LIMIT="$(left "$deadline")" run "r2-canon-$i" getent ahostsv4 "$canon"
      hs="$(awk '{print $1}' "$PD/r2-host-$i.out" | sort -u | tr '\n' ' ')"; cs="$(awk '{print $1}' "$PD/r2-canon-$i.out" | sort -u | tr '\n' ' ')"
      [[ -n "$hs" && "$hs" == "$cs" ]] && break
      (( $(date +%s) >= deadline )) && break
      sleep "$POLL_S"
    done
    if [[ -n "$hs" && "$hs" == "$cs" ]]; then res R-2 PASS "host=$hs= canonical($canon)"
    else res R-2 FAIL "host=[${hs}] canonical($canon)=[${cs}]"; FINAL_RC=50; fi
  else
    res R-2 FAIL "routerCanonicalHostname 없음(R-1 확인)"; FINAL_RC=50
  fi
  # R-3 HTTPS: 인증서 검증 유지(-k 없음). TLS/검증 오류는 재시도 없이 FAIL, 503(backend 준비 중)만 상한 안에서 다시 본다.
  deadline=$(( $(date +%s) + HTTP_TIMEOUT_S )); i=0
  while :; do
    i=$((i+1))
    RUN_LIMIT=20 run "r3-$i" curl -sS --proto =https -o "$PD/r3-$i.body" -D "$PD/r3-$i.hdr" -w '%{http_code} %{ssl_verify_result}' --max-time 15 "https://$ROUTE_HOST/"
    read -r code3 verify3 <"$PD/r3-$i.out" || true
    [[ "$(rc_of "r3-$i")" == 0 && "${code3:-}" != 503 ]] && break
    [[ "$(rc_of "r3-$i")" != 0 && "$(rc_of "r3-$i")" != 7 && "$(rc_of "r3-$i")" != 28 && "$(rc_of "r3-$i")" != 124 ]] && break   # TLS·검증 오류(예: 60)는 즉시 판정
    (( $(date +%s) >= deadline )) && break
    sleep "$POLL_S"
  done
  if [[ "$(rc_of "r3-$i")" == 0 && "${verify3:-}" == 0 && "${code3:-}" == "$EXPECT_HTTPS_CODE" ]]; then
    res R-3 PASS "https $code3, TLS 검증 성공(ssl_verify_result=0)"
  else
    res R-3 FAIL "curl rc=$(rc_of "r3-$i") code=${code3:-none} ssl_verify_result=${verify3:-none} 기대=$EXPECT_HTTPS_CODE"; FINAL_RC=50
  fi
  if command -v openssl >/dev/null; then
    RUN_LIMIT="$CERT_TIMEOUT_S" run r3-cert bash -c 'openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName' _ "$ROUTE_HOST"
  fi
  # R-4 HTTP → HTTPS: 따라가지 않고 code·Location 정확 비교
  RUN_LIMIT=20 run r4 curl -sS --proto =http -o /dev/null -D "$PD/r4.hdr" -w '%{http_code}' --max-time 15 "http://$ROUTE_HOST/"
  loc="$(awk 'tolower($1)=="location:" {sub(/\r$/, "", $2); print $2}' "$PD/r4.hdr" | tail -n 1)"
  if [[ "$(rc_of r4)" == 0 && "$(out_of r4)" == "$EXPECT_HTTP_CODE" && "$loc" == "https://$ROUTE_HOST/" ]]; then
    res R-4 PASS "http $(out_of r4) Location=$loc"
  else
    res R-4 FAIL "curl rc=$(rc_of r4) code=$(out_of r4) Location=${loc:-none} 기대=$EXPECT_HTTP_CODE https://$ROUTE_HOST/"; FINAL_RC=50
  fi
fi

(( FINAL_RC == 0 )) || diag
# R-5 정리: 성공·실패와 관계없이 OWNED 정리(원본은 위에서 보존)
do_cleanup
if [[ "$CLEAN_RESULT" == DONE ]]; then res R-5 PASS "OWNED 정리·NotFound·목록 복원·정책 불변"
else res R-5 HOLD "$(tr '\n' ';' <"$PD/hold.txt")"; fi
cat "$PD/results.tsv"
{
  echo "RESULT_KST=$(now_kst)"
  for id in CREATE READY R-1 R-2 R-3 R-4 R-5; do echo "$id=$(awk -F'\t' -v id="$id" '$1==id {v=$3} END {print (v==""?"NOT_RUN":v)}' "$PD/results.tsv")"; done
} >"$PD/result.txt"
cat "$PD/result.txt"
[[ "$CLEAN_RESULT" == DONE ]] || die 60 "R-5 CLEANUP=HOLD: $(tr '\n' ';' <"$PD/hold.txt") — 같은 RUN으로 cleanup 재시도, 앱 배포 금지"
(( FINAL_RC == 0 )) || die "$FINAL_RC" "시험 FAIL(정리는 완료): $(awk -F'\t' '$3=="FAIL" {printf "%s;", $1}' "$PD/results.tsv")"
echo "ROUTE_TEST_PASS R-1~R-5 — 다음: RUN_DIR 반출·재해시, #38 8행 연결"
exit 0
