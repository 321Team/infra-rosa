# infra-rosa#7 — 창 한정 읽기 권한 붙이기/떼기 단계 파일 (bootstrap-session.sh 가 source 함)
#
# 쓰는 법(CloudShell, rosa·oc 로그인 상태):
#   READER_MODE=on  CLUSTER_ID=<id> API_URL=<url> DEADLINE_EPOCH=$(date -d '+20 min' +%s) \
#     bash ../../rbac/bootstrap/bootstrap-session.sh steps-reader.sh
#   READER_MODE=off ... (같은 형식, 창 끝 P8·P9 전)
#   래퍼가 grant → run_steps → 항상 revoke → 회수 확인을 한다. 끝나면 reader-check.sh <on|off> 로 일반 권한 확인·반출.
#
# 하는 일
#   on : reader.yaml 의 ClusterRole·ClusterRoleBinding 2개가 없는지 확인 → oc create(덮어쓰기 없음) → UID 기록
#        ($WORKDIR/netpol-reader-current.env). 이미 있으면 만들지 않고 STOP(소유 불명).
#   off: 기록한 UID와 현재 UID가 같을 때만 Binding → Role 순서로 삭제 → NotFound 확인. UID가 다르면 지우지 않고 STOP.
# 래퍼의 #5 receipt(EV)와 섞지 않으려고 증적 폴더 변수는 RD를 쓴다(EV 미설정 → #5 receipt 미발행이 정상).
# token·비밀번호 원문은 남기지 않는다(로그인 비밀번호는 프롬프트에 본인 입력).

READER_YAML_NAME="reader.yaml"
CR_NAME="fds-netpol-window-reader"
CRB_NAME="fds-netpol-window-reader-hayeoung"

_rd_run() { # name cmd... → $RD/<name>.{out,err,rc}, rc 그대로
  local n=$1 rc=0; shift
  "$@" >"$RD/$n.out" 2>"$RD/$n.err" || rc=$?
  echo "$rc" >"$RD/$n.rc"
  return "$rc"
}
_notfound() { grep -q '(NotFound)' "$RD/$1.err"; }

run_steps() {
  local mode="${READER_MODE:-}" kit="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}" w rc out k uid now want
  [[ "$mode" == on || "$mode" == off ]] || { log "STOP: READER_MODE=on|off 필요"; return 1; }
  RD="$WORKDIR/netpol-reader-$mode-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$RD"
  [[ "$KUBECONFIG" == "$WORKDIR/kubeconfig" ]] || { log "STOP: 전용 KUBECONFIG 아님"; return 1; }
  ( cd "$kit" && sha256sum "$READER_YAML_NAME" steps-reader.sh ) >"$RD/00-kit-sha256.txt" || { log "STOP: 키트 해시 실패"; return 1; }
  printf 'MODE=%s\nCLUSTER_ID=%s\nAPI_URL=%s\nUSER=%s\nSTARTED_AT=%s\n' "$mode" "$CLUSTER_ID" "$API_URL" "$U" "$(date '+%FT%T%z')" >"$RD/00-target.env"

  # 로그인 + 대상 결속(Cluster ID↔API는 래퍼가 grant 전에 확인)
  oc login "$API_URL" -u "$U"
  [[ "$(oc whoami)" == "$U" ]] || { log "STOP: whoami 불일치"; return 1; }
  [[ "$(oc whoami --show-server)" == "$API_URL" ]] || { log "STOP: server 불일치"; return 1; }
  # grant 반영 대기(#5 steps.sh와 같은 판정: yes+rc0만 통과, 정상 no만 제한 대기, 그 밖은 STOP)
  for ((w = 1; w <= ${GRANT_WAIT_TRIES:-30}; w++)); do
    rc=0; out=$(oc auth can-i '*' '*' --all-namespaces 2>"$RD/03-grant-wait.$w.err") || rc=$?
    printf '%s try=%s rc=%s %s\n' "$(date '+%FT%T%z')" "$w" "$rc" "${out:-EMPTY}" >>"$RD/03-grant-wait.txt"
    [[ $rc == 0 && "$out" == yes ]] && break
    [[ $rc == 1 && "$out" == no && ! -s "$RD/03-grant-wait.$w.err" ]] || { log "STOP: grant 반영 조회 오류 rc=$rc"; return 1; }
    sleep "${GRANT_WAIT_INTERVAL:-10}"
  done
  [[ $rc == 0 && "$out" == yes ]] || { log "STOP: grant 반영 대기 시간 초과"; return 1; }
  log "GRANT_EFFECTIVE try=$w"

  if [[ "$mode" == on ]]; then
    for k in "clusterrole/$CR_NAME" "clusterrolebinding/$CRB_NAME"; do
      rc=0; _rd_run "pre-${k%%/*}" oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      [[ $rc != 0 ]] && _notfound "pre-${k%%/*}" || { log "STOP: $k 가 이미 있거나 조회 오류(소유 불명 — 만들지 않음)"; return 1; }
    done
    rc=0; _rd_run create oc create -f "$kit/$READER_YAML_NAME" -o name || rc=$?
    : >"$RD/created.env"
    for k in "clusterrole/$CR_NAME" "clusterrolebinding/$CRB_NAME"; do
      rc=0; _rd_run "uid-${k%%/*}" oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      uid=$(<"$RD/uid-${k%%/*}.out")
      if [[ $rc == 0 && "$uid" =~ ^[0-9a-f-]{36}$ ]] && grep -qx "${k/\//.rbac.authorization.k8s.io/}" "$RD/create.out"; then
        printf '%s_UID=%s\n' "$([[ $k == clusterrole/* ]] && echo CR || echo CRB)" "$uid" >>"$RD/created.env"
      else
        log "STOP: $k 생성 확인 실패(create 출력에 없음 또는 UID 조회 실패) — UNKNOWN, 떼기 단계에서 사람 확인"
        cp -p "$RD/created.env" "$WORKDIR/netpol-reader-current.env" 2>/dev/null || true
        return 1
      fi
    done
    _rd_run crb-subjects oc get "clusterrolebinding/$CRB_NAME" -o 'jsonpath={.roleRef.name}|{range .subjects[*]}{.kind}:{.name},{end}' || { log "STOP: binding 조회 실패"; return 1; }
    [[ "$(<"$RD/crb-subjects.out")" == "$CR_NAME|User:$U," ]] || { log "STOP: binding 대상이 예상과 다름"; return 1; }
    cp -p "$RD/created.env" "$WORKDIR/netpol-reader-current.env" || { log "STOP: UID 기록 복사 실패"; return 1; }
    log "READER_ON $(tr '\n' ' ' <"$RD/created.env")"
  else
    [[ -s "$WORKDIR/netpol-reader-current.env" ]] || { log "STOP: 붙이기 기록(netpol-reader-current.env) 없음 — 지우지 않음"; return 1; }
    cp -p "$WORKDIR/netpol-reader-current.env" "$RD/created.env"
    # Binding 먼저 떼어 권한을 끊고, Role은 그 뒤
    for k in "clusterrolebinding/$CRB_NAME" "clusterrole/$CR_NAME"; do
      want=$(sed -n "s/^$([[ $k == clusterrole/* ]] && echo CR || echo CRB)_UID=//p" "$RD/created.env")
      rc=0; _rd_run "uid-${k%%/*}" oc get "$k" -o 'jsonpath={.metadata.uid}' || rc=$?
      if [[ $rc != 0 ]]; then
        _notfound "uid-${k%%/*}" && { echo "$k ALREADY_ABSENT" >>"$RD/cleanup.txt"; continue; }
        log "STOP: $k UID 조회 오류 — 지우지 않음"; return 1
      fi
      now=$(<"$RD/uid-${k%%/*}.out")
      [[ -n "$want" && "$now" == "$want" ]] || { log "STOP: $k UID 불일치(기록 ${want:-없음} / 현재 $now) — 지우지 않음"; return 1; }
      _rd_run "delete-${k%%/*}" oc delete "$k" --wait=true || { log "STOP: $k 삭제 실패"; return 1; }
      rc=0; _rd_run "gone-${k%%/*}" oc get "$k" -o name || rc=$?
      [[ $rc != 0 ]] && _notfound "gone-${k%%/*}" || { log "STOP: $k 삭제 뒤에도 조회됨"; return 1; }
      echo "$k DELETED uid=$now" >>"$RD/cleanup.txt"
    done
    mv -f "$WORKDIR/netpol-reader-current.env" "$RD/created.env.done" || { log "STOP: 기록 정리 실패"; return 1; }
    log "READER_OFF $(tr '\n' ' ' <"$RD/cleanup.txt")"
  fi
  ( cd "$RD" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS ) || { log "STOP: manifest 실패"; return 1; }
  log "STEPS_RD $RD"
}
