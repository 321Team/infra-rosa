#!/usr/bin/env bash
# infra-rosa#5 — 회수 뒤 D-11 판정 (첫 설정 순서 v2 §4 + v3 §2, 순서 ⑫)
#
# bootstrap-session.sh 가 rc=0(완료) 또는 rc=3(회수 완료·기본 binding 정책 승인 대기)으로 끝난 뒤, 같은 WORKDIR 로 실행한다.
# rc=3 이면 policy 가 PR 리뷰로 승인된 뒤에 실행한다(저장된 ⑩-b 증적을 같은 규칙으로 오프라인 재판정).
# 래퍼가 그 밖의 rc 로 끝났으면 이 스크립트가 아니라 CLEANUP_REQUIRED 절차(v2 §3)로 간다.
# 판정 전에 래퍼 완료 receipt(99-receipt.env)와 해시·대상·회수 전 세션 지문을 대조하고, 하나라도 다르면 STOP 한다(PR#40 리뷰 R3).
#
# 순서(리뷰 6163744385: 회수 전 세션 시험을 마친 뒤에 그 kubeconfig 를 정리)
#   D-11b 회수 전 세션 그대로 → D-11a 새 로그인 → D-11c(관리면 + SSAR + ⑩-b 경로 검토) → 하영 MON 확인 → 회수 전 세션 정리
# D-11d(권욱·재환 본인 세션 접근 유지)는 각자 README 의 명령으로 확인해 #5 에 붙인다.
#
# 쓰는 법:
#   CLUSTER_ID=<id> API_URL=<url> ./post-revoke-check.sh <bootstrap 증적 디렉터리(EVIDENCE_DIR)>
set -Eeuo pipefail
: "${CLUSTER_ID:?}"; : "${API_URL:?}"
U="${U:-hayeoung}"
WORKDIR="${WORKDIR:-$HOME/rosa-idp}"
ROSA_USERS_HEADER_RE="${ROSA_USERS_HEADER_RE:-^ID[[:space:]]+GROUPS[[:space:]]*$}"   # [AFTER-CREATE] 실제 머리글로 확정
ROSA_USERS_ROW_RE="${ROSA_USERS_ROW_RE:-^[a-z0-9][a-z0-9._@-]*[[:space:]]+(cluster-admins|dedicated-admins)(,(cluster-admins|dedicated-admins))*[[:space:]]*$}"
# 빈 목록 출력(#5 A단계 실측, 2026-10-18) — bootstrap-session.sh 와 같은 규칙. rc0 + stderr 없음 + 정확히 이 1줄일 때만 부재.
ROSA_USERS_EMPTY_LINE="INFO: There are no users configured for cluster '$CLUSTER_ID'"
users_list_empty() { # out err
  [[ ! -s "$2" && "$(wc -l <"$1")" -eq 1 && "$(<"$1")" == "$ROSA_USERS_EMPTY_LINE" ]]
}
KIT_DIR="${KIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
POLICY_FILE="${POLICY_FILE:-$KIT_DIR/../policy/platform-defaults.approved.tsv}"
BOOT_EV="${1:?usage: post-revoke-check.sh <bootstrap EVIDENCE_DIR>}"
OLD="$WORKDIR/kubeconfig"          # 회수 전 세션(래퍼가 남겨 둔 것)
NEW="$WORKDIR/kubeconfig-d11"      # D-11a 새 세션 전용
umask 077
EV="$WORKDIR/d11-$(date +%Y%m%dT%H%M%S)"; mkdir -p "$EV"
printf 'id\tcheck\texpect\tobserved\trc\n' >"$EV/results.tsv"
fail=0
log() { printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >&2; }
rec() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$EV/results.tsv"; [[ "$3" == "$4" ]] || { log "FAIL $1 expect=$3 got=$4"; fail=1; }; }

# 새 로그인 세션 kubeconfig 는 결과와 관계없이 항상 logout·삭제(PR#40 보완 1).
# 회수 전 세션(OLD)은 정상 경로 끝에서 지우고, CLEANUP_REQUIRED 로 멈춘 경우에만 조사용으로 남긴다(README 실행 카드).
cleanup_new() {
  if [[ -f "$NEW" ]]; then KUBECONFIG="$NEW" oc logout >/dev/null 2>&1 || true; fi
  rm -f -- "$NEW"
  [[ ! -e "$NEW" ]] || log "CLEANUP_REQUIRED: 새 세션 kubeconfig 삭제 실패($NEW)"
}
trap cleanup_new EXIT

# 요청 분류: ALLOW / DENY(RBAC 403) / UNAUTH(401) / OTHER
# DENY 는 "(Forbidden)" 만으로 인정하지 않고 RBAC 거부 문장(User "<U>" cannot <verb> resource "...")일 때만(PR#40 보완 5).
cls() {
  local rc=$1 errf=$2
  if [[ $rc -eq 0 ]]; then echo ALLOW
  elif grep -q '(Forbidden)' "$errf" && grep -qF "User \"$U\" cannot " "$errf" \
       && grep -qE 'cannot [a-z]+ resource "' "$errf"; then echo DENY
  elif grep -Eq 'Unauthorized|must be logged in' "$errf"; then echo UNAUTH
  else echo OTHER; fi
}
LAST=""   # run 의 관측값(서브셸 없이 전달 — fail 플래그를 잃지 않도록 $(...) 로 부르지 않는다)
run() { # id kubeconfig expect_set(예: DENY|UNAUTH) -- cmd...
  local id=$1 kc=$2 want=$3; shift 4
  local rc=0 got
  KUBECONFIG="$kc" "$@" >"$EV/$id.out" 2>"$EV/$id.err" || rc=$?
  got=$(cls "$rc" "$EV/$id.err")
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$*" "$want" "$got" "$rc" >>"$EV/results.tsv"
  [[ "|$want|" == *"|$got|"* ]] || { log "FAIL $id expect=$want got=$got"; fail=1; }
  LAST=$got
}
cani() { # id kubeconfig -- can-i args (정확한 no 만 PASS)
  cani_want no "$@"
}
cani_want() { # want(yes|no) id kubeconfig -- can-i args — 정확한 yes/no 와 rc 가 기대와 같아야 PASS
  local want=$1 id=$2 kc=$3; shift 4
  local rc=0 got=OTHER
  KUBECONFIG="$kc" oc auth can-i "$@" >"$EV/$id.out" 2>"$EV/$id.err" || rc=$?
  [[ $rc -eq 1 && "$(<"$EV/$id.out")" == no && ! -s "$EV/$id.err" ]] && got=no
  [[ $rc -eq 0 && "$(<"$EV/$id.out")" == yes ]] && got=yes
  rec "$id" "can-i $*" "$want" "$got" "$rc"
}

[[ -f "$OLD" ]] || { log "STOP: 회수 전 세션 kubeconfig 없음($OLD) — D-11b 판정 불가"; exit 1; }

# 대상 대조(PR#40 보완 3): 이 판정이 bootstrap 회차와 같은 클러스터·API·사용자에 대한 것인지 먼저 확인한다.
printf 'CLUSTER_ID=%s\nAPI_URL=%s\nUSER=%s\nBOOT_EV=%s\nCHECKED_AT=%s\n' \
  "$CLUSTER_ID" "$API_URL" "$U" "$BOOT_EV" "$(date '+%FT%T%z')" >"$EV/00-target.env"
tgt="$BOOT_EV/00-target.env"
[[ -f "$tgt" ]] || { log "STOP: bootstrap 대상 기록 없음($tgt)"; exit 1; }
for kv in "CLUSTER_ID=$CLUSTER_ID" "API_URL=$API_URL" "USER=$U"; do
  grep -qxF "$kv" "$tgt" || { log "STOP: bootstrap 회차와 대상 불일치(${kv%%=*}) — $tgt"; exit 1; }
done
srv=$(cat "$BOOT_EV/10b-inventory/server.txt" 2>/dev/null || true)
[[ "$srv" == "$API_URL" ]] || { log "STOP: ⑩-b 수집 server($srv) ≠ API_URL"; exit 1; }
api=$(rosa describe cluster -c "$CLUSTER_ID" -o json | jq -er '.api.url') \
  || { log "STOP: CLUSTER_ID 조회 실패"; exit 1; }
[[ "$api" == "$API_URL" ]] || { log "STOP: CLUSTER_ID 의 API URL($api) ≠ API_URL"; exit 1; }
rec TARGET "bootstrap 대상·⑩-b server·describe api.url 일치" match match -

# 완료 receipt 대조(PR#40 리뷰 R3) — 회수 확인 뒤에만 발행된 receipt 가 있고, 지금 파일들이 그때와 같아야 한다.
rcpt="$BOOT_EV/99-receipt.env"
[[ -s "$rcpt" ]] || { log "STOP: 완료 receipt 없음($rcpt) — 회수 확인이 끝난 회차가 아님"; exit 1; }
rv() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; f = 1 } END { exit !f }' "$rcpt"; }
# 해시는 rc·형식을 검사한 뒤에만 낸다(리뷰 5530751510 R3). 실패를 빈 값으로 넘기지 않는다.
sha_of() {
  local out
  out=$(sha256sum -- "$1") || return 1
  out=${out%% *}
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}
for kv in "RECEIPT_VERSION=1" "CLUSTER_ID=$CLUSTER_ID" "API_URL=$API_URL" "USER=$U"; do
  grep -qxF "$kv" "$rcpt" || { log "STOP: receipt 불일치(${kv%%=*})"; exit 1; }
done
st=$(rv STATUS || true); frc=$(rv FINAL_RC || true)
[[ ( "$st" == COMPLETE && "$frc" == 0 ) || ( "$st" == POLICY_PENDING && "$frc" == 3 ) ]] \
  || { log "STOP: receipt 상태 이상(STATUS=$st FINAL_RC=$frc)"; exit 1; }
chk() { # 이름 파일 receipt-키 — 계산 실패·receipt 값 누락·형식 오류·불일치 모두 STOP(빈 값끼리 같다고 보지 않음)
  local got want
  [[ -s "$2" ]] || { log "STOP: $1 파일 없음/빈 파일($2)"; exit 1; }
  got=$(sha_of "$2") || { log "STOP: $1 해시 계산 실패"; exit 1; }
  want=$(rv "$3")    || { log "STOP: receipt 에 $3 없음"; exit 1; }
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { log "STOP: receipt $3 형식 오류"; exit 1; }
  [[ "$got" == "$want" ]] || { log "STOP: $1 해시가 receipt 와 다름(변조·다른 회차)"; exit 1; }
}
chk "회수 전 세션 kubeconfig" "$OLD" OLD_KUBECONFIG_SHA256
chk "대상 기록" "$BOOT_EV/00-target.env" TARGET_SHA256
chk "namespace UID 기록(⑤)" "$BOOT_EV/05-ns-uid.txt" NS_UID_SHA256   # UID 대조(D-11a 뒤)보다 먼저 원본을 검산
chk "인벤토리 SHA256SUMS" "$BOOT_EV/10b-inventory/SHA256SUMS" INVENTORY_SUMS_SHA256
chk "경로 검토" "$BOOT_EV/10b-path-review.tsv" PATH_REVIEW_SHA256
( cd "$BOOT_EV/10b-inventory" && sha256sum -c --quiet SHA256SUMS ) >"$EV/inventory-sumcheck.txt" 2>&1 \
  || { log "STOP: 인벤토리 파일이 SHA256SUMS 와 다름"; exit 1; }
# 회수 전 세션이 같은 API 를 가리키는지(다른 클러스터 세션으로 D-11b 를 판정하지 않음)
osrv=$(KUBECONFIG="$OLD" oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
[[ "$osrv" == "$API_URL" ]] || { log "STOP: 회수 전 세션 server($osrv) ≠ API_URL"; exit 1; }
rec RECEIPT "receipt·해시·회수 전 세션 server 일치" match match -

# 판정 입력 기록(리뷰 5530751510 비차단): 같은 판정을 나중에 재현할 수 있게 policy·분류기·키트 버전을 남긴다.
{
  printf 'POLICY_FILE=%s\n' "$POLICY_FILE"
  if [[ -f "$POLICY_FILE" ]]; then
    p=$(sha_of "$POLICY_FILE") || { log "STOP: policy 해시 계산 실패"; exit 1; }
    printf 'POLICY_SHA256=%s\n' "$p"
  else
    printf 'POLICY_SHA256=ABSENT\n'
  fi
  c=$(sha_of "$KIT_DIR/classify-access-paths.sh") || { log "STOP: 분류기 해시 계산 실패"; exit 1; }
  printf 'CLASSIFIER_SHA256=%s\n' "$c"
  printf 'KIT_GIT_SHA=%s\n' "$(git -C "$KIT_DIR" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
} >"$EV/00-judgement-inputs.env"

# ⑩-b 저장 증적을 같은 규칙으로 오프라인 재판정(승인된 policy 필요). 0 이 아니면 판정 전에 STOP.
crc=0
bash "$KIT_DIR/classify-access-paths.sh" "$BOOT_EV/10b-inventory" "$U" "$POLICY_FILE" "$EV/10b-path-review.recheck.tsv" \
  2>"$EV/10b-recheck.err" || crc=$?
case "$crc" in
  0) rec D-11c-paths "⑩-b 오프라인 재판정(policy $POLICY_FILE)" OK OK - ;;
  3) log "STOP: 기본 binding policy 가 아직 승인되지 않음 — policy PR 리뷰·병합 뒤 다시 실행"; exit 1 ;;
  *) log "STOP: ⑩-b 재판정에서 승인 외 경로 또는 입력 누락 — $EV/10b-path-review.recheck.tsv"; exit 1 ;;
esac

# D-11b — 회수 전 세션으로 비파괴 관리자 요청. 2xx 면 즉시 CLEANUP_REQUIRED.
run D-11b "$OLD" 'DENY|UNAUTH' -- oc get nodes
if [[ "$LAST" == ALLOW ]]; then log "CLEANUP_REQUIRED: 회수 전 세션이 아직 관리자 권한을 가짐"; exit 1; fi

# D-11a — 새 로그인(비밀번호는 본인 입력). 로그인 성공·정확한 identity·nodes 403·namespace 허용. 401 은 PASS 아님.
KUBECONFIG="$NEW" oc login "$API_URL" -u "$U"
w=$(KUBECONFIG="$NEW" oc whoami); s=$(KUBECONFIG="$NEW" oc whoami --show-server)
rec D-11a-who whoami "$U" "$w" 0
rec D-11a-server server "$API_URL" "$s" 0
run D-11a-nodes "$NEW" DENY  -- oc get nodes
run D-11a-ns    "$NEW" ALLOW -- oc get pods -n fds-app

# 대상 대조 2(보완 3): 새 세션에서 보이는 3개 project UID = bootstrap ⑤에서 기록한 namespace UID
# (project UID 는 namespace UID 와 같다. [AFTER-CREATE] ROSA 에서 project get 이 namespace admin 에게 허용되는지 첫 실행에서 확인)
for ns in fds-app monitoring-api ci-cd; do
  want=$(awk -v n="$ns" '$1 == n { print $2 }' "$BOOT_EV/05-ns-uid.txt" 2>/dev/null || true)
  rc=0; got=$(KUBECONFIG="$NEW" oc get project "$ns" -o jsonpath='{.metadata.uid}' 2>"$EV/uid-$ns.err") || rc=$?
  [[ $rc -eq 0 && -n "$want" ]] || got="UNKNOWN(rc=$rc)"
  rec "TARGET-uid-$ns" "project uid = bootstrap ⑤" "${want:-missing}" "$got" "$rc"
done

# D-11c ② — 새 세션 SSAR(그룹 포함 실제 권한 평가)
cani D-11c-all  "$NEW" -- '*' '*' --all-namespaces
cani D-11c-crb  "$NEW" -- create clusterrolebindings.rbac.authorization.k8s.io
cani D-11c-node "$NEW" -- list nodes
# 하영 clusterversion/version get 최소 권한(#5 6258874244) — 회수 뒤 본인 세션에서 get 만 yes, 나머지 no
cani_want yes D-11a-cv-get  "$NEW" -- get clusterversions.config.openshift.io/version
cani_want no  D-11a-cv-list "$NEW" -- list clusterversions.config.openshift.io
cani_want no  D-11a-cv-upd  "$NEW" -- update clusterversions.config.openshift.io/version

# D-11c ① — 관리면 grant 기록. 실측 빈 목록 1줄이면 부재, 그 밖에는 머리글·본문 형식이 맞을 때만 판정.
rc=0; rosa list users -c "$CLUSTER_ID" >"$EV/D-11c-mgmt.out" 2>"$EV/D-11c-mgmt.err" || rc=$?
m=UNKNOWN
# 머리글 + 본문 전 행 형식이 맞을 때만 판정(R5). 깨진 본문·그룹 없는 행은 UNKNOWN.
if [[ $rc -eq 0 ]] && users_list_empty "$EV/D-11c-mgmt.out" "$EV/D-11c-mgmt.err"; then
  m=ABSENT
elif [[ $rc -eq 0 ]] && head -n 1 "$EV/D-11c-mgmt.out" | grep -Eq "$ROSA_USERS_HEADER_RE" \
   && tail -n +2 "$EV/D-11c-mgmt.out" | awk -v re="$ROSA_USERS_ROW_RE" 'NF == 0 { next } $0 !~ re { bad = 1 } END { exit bad }'; then
  if tail -n +2 "$EV/D-11c-mgmt.out" | awk -v u="$U" '$1 == u { n = split($2, g, ","); for (i = 1; i <= n; i++) if (g[i] == "cluster-admins") f = 1 } END { exit !f }'; then
    m=PRESENT
  else
    m=ABSENT
  fi
fi
rec D-11c-mgmt "rosa list users" ABSENT "$m" "$rc"
# D-11c ③ (⑩-b 경로)은 위 receipt 대조 직후 오프라인 재판정으로 이미 기록했다.

# MON-A-09 / MON-D-13 — 하영 회수 뒤 세션(조건부 ⑮ 판단 자료. 결과만 기록, 실패로 세지 않음)
for spec in "MON-A-09 fds-app" "MON-D-13a monitoring-api" "MON-D-13b ci-cd"; do
  set -- $spec
  rc=0; KUBECONFIG="$NEW" oc auth can-i create servicemonitors.monitoring.coreos.com -n "$2" >"$EV/$1.out" 2>"$EV/$1.err" || rc=$?
  printf '%s\tservicemonitors create -n %s\t(기록)\t%s\t%s\n' "$1" "$2" "$(<"$EV/$1.out")" "$rc" >>"$EV/results.tsv"
done

# 정리 — 모든 판정이 PASS 일 때만 회수 전 세션 로그아웃·파일 삭제(R3). FAIL 이면 조사용으로 남기고 CLEANUP_REQUIRED 판단.
if [[ $fail -eq 0 ]]; then
  KUBECONFIG="$OLD" oc logout >/dev/null 2>&1 || true
  rm -f -- "$OLD"
  log "OLD_SESSION_CLEANED"
else
  log "OLD_SESSION_KEPT(판정 FAIL — 조사 후 수동 정리): $OLD"
fi

( cd "$EV" && sha256sum -- * >SHA256SUMS )
column -t -s $'\t' "$EV/results.tsv" >&2 || cat "$EV/results.tsv" >&2
if [[ $fail -ne 0 ]]; then log "D-11 RESULT: FAIL (CLEANUP_REQUIRED 판단 필요) — $EV"; exit 1; fi
log "D-11 RESULT: PASS — $EV  (D-11d 는 권욱·재환 본인 세션 결과를 붙여 완료)"
