# infra-rosa#5 — bootstrap 회차 단계 파일 템플릿 (bootstrap-session.sh 가 source 함)
# 첫 설정 순서 v3 ③~⑩-b. manifest 경로·값은 실행 승인본으로 채운 뒤 SHA 를 기록한다.
# 어느 명령이든 실패하면 set -e 로 즉시 cleanup(회수)으로 간다. 다음 단계는 실행되지 않는다.
run_steps() {
  local ns sa uid sa_names
  local ev="$WORKDIR/evidence-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$ev"

  # ③ 로그인(비밀번호는 프롬프트에 본인 입력) + 대상 결속. 쓰기 전에 전용 kubeconfig·ID·API·사용자를 확인한다.
  [[ "$KUBECONFIG" == "$WORKDIR/kubeconfig" ]] || { log "STOP: 전용 KUBECONFIG 아님"; return 1; }
  [[ "$(rosa describe cluster -c "$CLUSTER_ID" -o json | jq -r .api.url)" == "$API_URL" ]] \
    || { log "STOP: CLUSTER_ID 의 API URL 불일치"; return 1; }
  oc login "$API_URL" -u "$U"
  [[ "$(oc whoami)" == "$U" ]] || { log "STOP: whoami 불일치"; return 1; }
  [[ "$(oc whoami --show-server)" == "$API_URL" ]] || { log "STOP: server 불일치"; return 1; }

  # ④ 기본 상태 읽기(쓰기 없음)
  oc get groups -o yaml >"$ev/04-groups.yaml"
  oc get clusterrolebinding self-provisioners -o yaml >"$ev/04-self-provisioners.yaml"
  oc get pods -n openshift-user-workload-monitoring -o wide >"$ev/04-uwm-pods.txt" 2>&1 || true  # 없으면 그 사실 기록

  # ⑤ Namespace + UID
  oc apply -f "${MANIFEST_DIR:?}/namespaces.yaml"
  for ns in fds-app monitoring-api ci-cd; do
    uid=$(oc get ns "$ns" -o jsonpath='{.metadata.uid}') \
      || { log "STOP: Namespace UID 조회 실패 ($ns)"; return 1; }
    [[ -n "$uid" ]] || { log "STOP: Namespace UID 비어 있음 ($ns)"; return 1; }
    printf '%s %s\n' "$ns" "$uid" >>"$ev/05-ns-uid.txt"
  done

  # ⑥ 자동 생성 SA·RoleBinding 기록(삭제하지 않음)
  for ns in fds-app monitoring-api ci-cd; do
    oc get sa,rolebinding -n "$ns" -o yaml >"$ev/06-defaults-$ns.yaml"
  done

  # ⑦ 배포 SA·앱 SA·Role/RoleBinding
  oc apply -f "$MANIFEST_DIR/rbac.yaml"

  # ⑦-a #7 NetworkPolicy, #43/#12 Secret 은 각 소유자 절차(여기서 호출하지 않음)

  # ⑧ 사람 binding(하영 monitoring-edit 제외) + ClusterRole 규칙 기록
  oc apply -f "$MANIFEST_DIR/human-bindings.yaml"
  oc get clusterrole admin view monitoring-edit -o yaml >"$ev/08-clusterroles.yaml"

  # ⑨ 권한 판정(--as 는 보조. 실제 세션 시험은 ⑩·⑬)
  for ns in fds-app monitoring-api ci-cd; do
    sa_names=$(oc get sa -n "$ns" -o jsonpath='{.items[*].metadata.name}') \
      || { log "STOP: SA 목록 조회 실패 ($ns)"; return 1; }
    [[ -n "$sa_names" ]] || { log "STOP: SA 목록 비어 있음 ($ns)"; return 1; }
    for sa in $sa_names; do
      oc auth can-i --list -n "$ns" --as="system:serviceaccount:$ns:$sa" \
        >"$ev/09-cani-$ns-$sa.txt"
    done
  done

  # ⑩ 배포 SA 실제 token 시험(원문 미출력, 900초 요청)
  oc create token fds-deployer -n ci-cd --duration=900s >"$WORKDIR/t"
  [[ -s "$WORKDIR/t" ]] || { log "STOP: token 발급 실패"; return 1; }
  local p; p=$(cut -d. -f2 "$WORKDIR/t" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p+='='; done
  # claim 검사(리뷰 6164637613): exp/iat 숫자, 0 < exp-iat <= 900, 현재 시각 기준 미만료, sub 정확 일치, aud 비어 있지 않음.
  # aud 기대값은 #46 소비 계약으로 고정 전까지 기록만(실행본에서 정확 일치로 바꿈). 어느 하나라도 아니면 jq -e 실패 → STOP.
  printf '%s' "$p" | base64 -d | jq -e --argjson now "$(date +%s)" \
      --arg sub "system:serviceaccount:ci-cd:fds-deployer" '
    select((.exp | type) == "number" and (.iat | type) == "number")
    | select((.exp - .iat) > 0 and (.exp - .iat) <= 900)
    | select(.exp > $now)
    | select(.sub == $sub)
    | select((.aud // []) | length > 0)
    | {exp, iat, life: (.exp - .iat), aud, sub}' \
    >"$ev/10-token-claims.json" \
    || { log "STOP: token claim 검사 실패(만료 확인 불가·900초 초과·sub/aud 불일치)"; return 1; }
  # A/D 시험: oc --token="$(cat "$WORKDIR/t")" 형태는 인자 노출 → KUBECONFIG 임시 파일로 수행(실행본에서 확정)

  # ⑩-b 권한 목록 저장(R2) — 회수 전에 반드시
  bash "${KIT_DIR:?}/collect-access-inventory.sh" "$ev/10b-inventory"
  log "EVIDENCE_DIR $ev"
}
