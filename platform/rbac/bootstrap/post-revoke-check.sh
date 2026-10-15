#!/usr/bin/env bash
# infra-rosa#5 — 회수 뒤 D-11 판정 (첫 설정 순서 v2 §4 + v3 §2, 순서 ⑫)
#
# bootstrap-session.sh 가 rc=0(REVOKE_VERIFIED)으로 끝난 **직후**, 같은 WORKDIR 로 실행한다.
# 래퍼가 rc≠0 이면 이 스크립트가 아니라 CLEANUP_REQUIRED 절차(v2 §3)로 간다.
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
BOOT_EV="${1:?usage: post-revoke-check.sh <bootstrap EVIDENCE_DIR>}"
OLD="$WORKDIR/kubeconfig"          # 회수 전 세션(래퍼가 남겨 둔 것)
NEW="$WORKDIR/kubeconfig-d11"      # D-11a 새 세션 전용
umask 077
EV="$WORKDIR/d11-$(date +%Y%m%dT%H%M%S)"; mkdir -p "$EV"
printf 'id\tcheck\texpect\tobserved\trc\n' >"$EV/results.tsv"
fail=0
log() { printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >&2; }
rec() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$EV/results.tsv"; [[ "$3" == "$4" ]] || { log "FAIL $1 expect=$3 got=$4"; fail=1; }; }

# 요청 분류: ALLOW / DENY(403) / UNAUTH(401) / OTHER
cls() {
  local rc=$1 errf=$2
  if [[ $rc -eq 0 ]]; then echo ALLOW
  elif grep -q '(Forbidden)' "$errf"; then echo DENY
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
  local id=$1 kc=$2; shift 3
  local rc=0 got=OTHER
  KUBECONFIG="$kc" oc auth can-i "$@" >"$EV/$id.out" 2>"$EV/$id.err" || rc=$?
  [[ $rc -eq 1 && "$(<"$EV/$id.out")" == no && ! -s "$EV/$id.err" ]] && got=no
  [[ $rc -eq 0 && "$(<"$EV/$id.out")" == yes ]] && got=yes
  rec "$id" "can-i $*" no "$got" "$rc"
}

[[ -f "$OLD" ]] || { log "STOP: 회수 전 세션 kubeconfig 없음($OLD) — D-11b 판정 불가"; exit 1; }

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

# D-11c ② — 새 세션 SSAR(그룹 포함 실제 권한 평가)
cani D-11c-all  "$NEW" -- '*' '*' --all-namespaces
cani D-11c-crb  "$NEW" -- create clusterrolebindings.rbac.authorization.k8s.io
cani D-11c-node "$NEW" -- list nodes

# D-11c ① — 관리면 grant 기록. [AFTER-CREATE] 머리글 형식 확정 전에는 UNKNOWN 으로 남는다.
rc=0; rosa list users -c "$CLUSTER_ID" >"$EV/D-11c-mgmt.out" 2>"$EV/D-11c-mgmt.err" || rc=$?
m=UNKNOWN
if [[ $rc -eq 0 ]] && head -n 1 "$EV/D-11c-mgmt.out" | grep -Eq "$ROSA_USERS_HEADER_RE"; then
  if tail -n +2 "$EV/D-11c-mgmt.out" | awk -v u="$U" '$1 == u' | grep -q 'cluster-admin'; then m=PRESENT; else m=ABSENT; fi
fi
rec D-11c-mgmt "rosa list users" ABSENT "$m" "$rc"

# D-11c ③ — ⑩-b 회수 전 구조 목록에서 UNEXPECTED 0
pr="$BOOT_EV/10b-path-review.tsv"
if [[ -f "$pr" ]]; then
  n=$(grep -c '^UNEXPECTED' "$pr" || true)
  rec D-11c-paths "10b UNEXPECTED count" 0 "$n" -
else
  rec D-11c-paths "10b path-review 파일" present missing -
fi

# MON-A-09 / MON-D-13 — 하영 회수 뒤 세션(조건부 ⑮ 판단 자료. 결과만 기록, 실패로 세지 않음)
for spec in "MON-A-09 fds-app" "MON-D-13a monitoring-api" "MON-D-13b ci-cd"; do
  set -- $spec
  rc=0; KUBECONFIG="$NEW" oc auth can-i create servicemonitors.monitoring.coreos.com -n "$2" >"$EV/$1.out" 2>"$EV/$1.err" || rc=$?
  printf '%s\tservicemonitors create -n %s\t(기록)\t%s\t%s\n' "$1" "$2" "$(<"$EV/$1.out")" "$rc" >>"$EV/results.tsv"
done

# 정리 — D-11b 판정이 끝났으므로 회수 전 세션 로그아웃·파일 삭제(다른 kubeconfig 는 건드리지 않음)
KUBECONFIG="$OLD" oc logout >/dev/null 2>&1 || true
rm -f -- "$OLD"
log "OLD_SESSION_CLEANED"

( cd "$EV" && sha256sum -- * >SHA256SUMS )
column -t -s $'\t' "$EV/results.tsv" >&2 || cat "$EV/results.tsv" >&2
if [[ $fail -ne 0 ]]; then log "D-11 RESULT: FAIL (CLEANUP_REQUIRED 판단 필요) — $EV"; exit 1; fi
log "D-11 RESULT: PASS — $EV  (D-11d 는 권욱·재환 본인 세션 결과를 붙여 완료)"
