# infra-rosa#7 — 창 한정 읽기 권한 붙이기/떼기 단계 파일 (bootstrap-session.sh 가 source 함)
#
# 쓰는 법(CloudShell, rosa·oc·jq 준비, WORKDIR=~/rosa-netpol-reader):
#   READER_MODE=on  CLUSTER_ID=<id> API_URL=<url> DEADLINE_EPOCH=$(date -d '+20 min' +%s) \
#     bash ../../rbac/bootstrap/bootstrap-session.sh steps-reader.sh
#   READER_MODE=off ... (같은 형식, 창 끝 P8·P9 전)
#   래퍼가 grant → run_steps → 항상 cluster-admin revoke → 회수 확인을 한다. 끝나면 reader-check.sh <on|off>.
#   ⚠ 래퍼는 cluster-admin만 자동 회수한다. reader binding은 off 단계로 따로 떼야 한다(실행 카드에 담당·시각).
#
# 하는 일
#   on : 두 객체가 없을 때만 oc create. **create 응답에 나온 UID(ACK)**를 기록하고, 이어서 GET한 UID가 ACK와 같을 때만
#        자기 소유로 채택($WORKDIR/netpol-reader-current.env). 다르면 교체로 보고 채택하지 않고 STOP(PR53 R1).
#   off: 기록 UID와 현재 UID 확인 → **삭제 요청 자체에 UID 조건(DeleteOptions.preconditions.uid)**을 넣어
#        Binding → Role 순서로 삭제 → NotFound. 서버가 UID 불일치를 409로 거부하면 지우지 않고 STOP(PR53 R1).
#   모든 oc 호출은 요청 상한(--request-timeout)과 프로세스 상한(timeout -k)을 둔다. 시간 초과·응답 불명은
#   UNKNOWN으로 멈추고 래퍼의 revoke로 넘어간다(PR53 R2). 자동 재시도 없음.
# 래퍼의 #5 receipt(EV)와 섞지 않으려고 증적 폴더 변수는 RD를 쓴다(EV 미설정 → #5 receipt 미발행이 정상).
# token·비밀번호 원문은 남기지 않는다(로그인 비밀번호는 프롬프트에 본인 입력).

READER_YAML_NAME="reader.yaml"
CR_NAME="fds-netpol-window-reader"
CRB_NAME="fds-netpol-window-reader-hayeoung"
READER_REQ_S="${READER_REQ_S:-30}"      # API 요청 상한(초)
READER_CALL_S="${READER_CALL_S:-60}"    # 프로세스 상한(초), 넘으면 TERM, 10초 뒤 KILL
READER_LOGIN_S="${READER_LOGIN_S:-180}" # 비밀번호 입력 포함 로그인 상한

_oc() { timeout -k 10 "$READER_CALL_S" oc --request-timeout="${READER_REQ_S}s" "$@"; }
_rd_run() { # name cmd... → $RD/<name>.{out,err,rc}, rc 그대로(124·137 = 상한 초과)
  local n=$1 rc=0; shift
  "$@" >"$RD/$n.out" 2>"$RD/$n.err" || rc=$?
  echo "$rc" >"$RD/$n.rc"
  return "$rc"
}
_notfound() { grep -q '(NotFound)' "$RD/$1.err"; }
_timed_out() { [[ "$(<"$RD/$1.rc")" == 124 || "$(<"$RD/$1.rc")" == 137 ]]; }
_api_path() { # clusterrole/x | clusterrolebinding/x → 고정 API 경로
  case "$1" in
    "clusterrole/$CR_NAME") echo "/apis/rbac.authorization.k8s.io/v1/clusterroles/$CR_NAME";;
    "clusterrolebinding/$CRB_NAME") echo "/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/$CRB_NAME";;
    *) return 1;;
  esac
}
_key() { [[ $1 == clusterrole/* ]] && echo CR || echo CRB; }

run_steps() {
  local mode="${READER_MODE:-}" kit="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}" w rc rc2 out k uid now want ack path
  [[ "$mode" == on || "$mode" == off ]] || { log "STOP: READER_MODE=on|off 필요"; return 1; }
  RD="$WORKDIR/netpol-reader-$mode-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$RD"
  [[ "$KUBECONFIG" == "$WORKDIR/kubeconfig" ]] || { log "STOP: 전용 KUBECONFIG 아님"; return 1; }
  ( cd "$kit" && sha256sum "$READER_YAML_NAME" steps-reader.sh ) >"$RD/00-kit-sha256.txt" || { log "STOP: 키트 해시 실패"; return 1; }
  printf 'MODE=%s\nCLUSTER_ID=%s\nAPI_URL=%s\nUSER=%s\nSTARTED_AT=%s\n' "$mode" "$CLUSTER_ID" "$API_URL" "$U" "$(date '+%FT%T%z')" >"$RD/00-target.env"

  # 로그인 + 대상 결속(Cluster ID↔API는 래퍼가 grant 전에 확인). 비밀번호 입력이 있어 --foreground.
  timeout --foreground -k 10 "$READER_LOGIN_S" oc login "$API_URL" -u "$U" --request-timeout="${READER_REQ_S}s" || { log "STOP: oc login 실패·상한 초과"; return 1; }
  _rd_run whoami _oc whoami || { log "STOP: whoami 실패·상한 초과"; return 1; }
  [[ "$(<"$RD/whoami.out")" == "$U" ]] || { log "STOP: whoami 불일치"; return 1; }
  _rd_run server _oc whoami --show-server || { log "STOP: server 조회 실패·상한 초과"; return 1; }
  [[ "$(<"$RD/server.out")" == "$API_URL" ]] || { log "STOP: server 불일치"; return 1; }
  # grant 반영 대기(#5 steps.sh와 같은 판정: yes+rc0만 통과, 정상 no만 제한 대기, 그 밖·상한 초과는 STOP)
  for ((w = 1; w <= ${GRANT_WAIT_TRIES:-30}; w++)); do
    rc=0; _rd_run "03-grant-wait.$w" _oc auth can-i '*' '*' --all-namespaces || rc=$?
    out=$(<"$RD/03-grant-wait.$w.out")
    printf '%s try=%s rc=%s %s\n' "$(date '+%FT%T%z')" "$w" "$rc" "${out:-EMPTY}" >>"$RD/03-grant-wait.txt"
    [[ $rc == 0 && "$out" == yes ]] && break
    [[ $rc == 1 && "$out" == no && ! -s "$RD/03-grant-wait.$w.err" ]] || { log "STOP: grant 반영 조회 오류·상한 초과 rc=$rc"; return 1; }
    sleep "${GRANT_WAIT_INTERVAL:-10}"
  done
  [[ $rc == 0 && "$out" == yes ]] || { log "STOP: grant 반영 대기 시간 초과"; return 1; }
  log "GRANT_EFFECTIVE try=$w"

  if [[ "$mode" == on ]]; then
    for k in "clusterrole/$CR_NAME" "clusterrolebinding/$CRB_NAME"; do
      rc=0; _rd_run "pre-${k%%/*}" _oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      [[ $rc != 0 ]] && _notfound "pre-${k%%/*}" || { log "STOP: $k 가 이미 있거나 조회 오류·상한 초과(소유 불명 — 만들지 않음)"; return 1; }
    done
    # create 응답(ACK)에서 객체별 kind·이름·UID를 받는다(별도 GET UID를 소유 근거로 쓰지 않음)
    rc=0; _rd_run create _oc create -f "$kit/$READER_YAML_NAME" -o 'jsonpath={.kind}{"\t"}{.metadata.name}{"\t"}{.metadata.uid}{"\n"}' || rc=$?
    : >"$RD/created.env"
    for k in "clusterrole/$CR_NAME" "clusterrolebinding/$CRB_NAME"; do
      ack=$(awk -F'\t' -v kind="$([[ $k == clusterrole/* ]] && echo ClusterRole || echo ClusterRoleBinding)" -v n="${k#*/}" '$1==kind && $2==n {print $3}' "$RD/create.out")
      if [[ $rc != 0 || ! "$ack" =~ ^[0-9a-f-]{36}$ ]]; then
        printf '%s_ACK=%s\n' "$(_key "$k")" "${ack:-NONE}" >>"$RD/created.env"
        log "STOP: $k 생성 응답에 UID 없음(rc=$rc) — UNKNOWN, 떼기 전에 사람 확인(자동 채택·삭제 없음)"; return 1
      fi
      rc2=0; _rd_run "uid-${k%%/*}" _oc get "$k" -o 'jsonpath={.metadata.uid}' || rc2=$?
      now=$(<"$RD/uid-${k%%/*}.out")
      if [[ $rc2 != 0 || "$now" != "$ack" ]]; then
        printf '%s_ACK=%s\n' "$(_key "$k")" "$ack" >>"$RD/created.env"
        log "STOP: $k 생성 직후 UID가 응답과 다름 또는 조회 실패(응답 $ack / 현재 ${now:-?}) — 교체 가능성, 채택하지 않음"; return 1
      fi
      printf '%s_UID=%s\n' "$(_key "$k")" "$ack" >>"$RD/created.env"
    done
    _rd_run crb-subjects _oc get "clusterrolebinding/$CRB_NAME" -o 'jsonpath={.roleRef.name}|{range .subjects[*]}{.kind}:{.name},{end}' || { log "STOP: binding 조회 실패·상한 초과"; return 1; }
    [[ "$(<"$RD/crb-subjects.out")" == "$CR_NAME|User:$U," ]] || { log "STOP: binding 대상이 예상과 다름"; return 1; }
    cp -p "$RD/created.env" "$WORKDIR/netpol-reader-current.env" || { log "STOP: UID 기록 복사 실패"; return 1; }
    log "READER_ON $(tr '\n' ' ' <"$RD/created.env")"
  else
    [[ -s "$WORKDIR/netpol-reader-current.env" ]] || { log "STOP: 붙이기 기록(netpol-reader-current.env) 없음 — 지우지 않음"; return 1; }
    cp -p "$WORKDIR/netpol-reader-current.env" "$RD/created.env"
    # Binding 먼저 떼어 권한을 끊고, Role은 그 뒤
    for k in "clusterrolebinding/$CRB_NAME" "clusterrole/$CR_NAME"; do
      want=$(sed -n "s/^$(_key "$k")_UID=//p" "$RD/created.env")
      [[ "$want" =~ ^[0-9a-f-]{36}$ ]] || { log "STOP: $k 기록 UID 없음 — 지우지 않음"; return 1; }
      rc=0; _rd_run "uid-${k%%/*}" _oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      if [[ $rc != 0 ]]; then
        _notfound "uid-${k%%/*}" && { echo "$k ALREADY_ABSENT" >>"$RD/cleanup.txt"; continue; }
        log "STOP: $k UID 조회 오류·상한 초과 — 지우지 않음"; return 1
      fi
      now=$(<"$RD/uid-${k%%/*}.out")
      [[ "$now" == "$want" ]] || { log "STOP: $k UID 불일치(기록 $want / 현재 $now) — 지우지 않음"; return 1; }
      # 삭제 요청에 UID 조건: 그 사이 교체됐으면 서버가 409로 거부한다
      path=$(_api_path "$k") || { log "STOP: $k API 경로 없음"; return 1; }
      printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}' "$want" >"$RD/delete-${k%%/*}.body.json"
      rc=0; _rd_run "delete-${k%%/*}" _oc delete --raw "$path" -f "$RD/delete-${k%%/*}.body.json" || rc=$?
      if [[ $rc != 0 ]]; then
        if grep -qiE 'conflict|precondition|409' "$RD/delete-${k%%/*}.err"; then log "STOP: $k 삭제 거부(UID 조건 불일치 409) — 교체된 객체, 지우지 않음"
        elif _timed_out "delete-${k%%/*}"; then log "STOP: $k 삭제 응답 상한 초과 — UNKNOWN(삭제 여부 사람 확인)"
        else log "STOP: $k 삭제 실패 rc=$rc — UNKNOWN"; fi
        return 1
      fi
      rc=0; _rd_run "gone-${k%%/*}" _oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      if [[ $rc != 0 ]] && _notfound "gone-${k%%/*}"; then echo "$k DELETED uid=$want" >>"$RD/cleanup.txt"
      else log "STOP: $k 삭제 뒤에도 조회됨(현재 $(<"$RD/gone-${k%%/*}.out")) 또는 조회 오류"; return 1; fi
    done
    mv -f "$WORKDIR/netpol-reader-current.env" "$RD/created.env.done" || { log "STOP: 기록 정리 실패"; return 1; }
    log "READER_OFF $(tr '\n' ' ' <"$RD/cleanup.txt")"
  fi
  ( cd "$RD" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS ) || { log "STOP: manifest 실패"; return 1; }
  log "STEPS_RD $RD"
}
