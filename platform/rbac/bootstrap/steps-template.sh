# infra-rosa#5 — bootstrap 회차 단계 파일 템플릿 (bootstrap-session.sh 가 source 함)
# 첫 설정 순서 v3 ③~⑩-b. manifest 경로·값은 실행 승인본으로 채운 뒤 SHA 를 기록한다.
# 어느 명령이든 실패하면 set -e 로 즉시 cleanup(회수)으로 간다. 다음 단계는 실행되지 않는다.
run_steps() {
  local ev="$WORKDIR/evidence-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$ev"

  # ③ 로그인(비밀번호는 프롬프트에 본인 입력) + 대상 결속
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
    echo "$ns $(oc get ns "$ns" -o jsonpath='{.metadata.uid}')" >>"$ev/05-ns-uid.txt"
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
    for sa in $(oc get sa -n "$ns" -o jsonpath='{.items[*].metadata.name}'); do
      oc auth can-i --list -n "$ns" --as="system:serviceaccount:$ns:$sa" \
        >"$ev/09-cani-$ns-$sa.txt"
    done
  done

  # ⑩ 배포 SA 실제 token 시험(원문 미출력, 900초 요청)
  oc create token fds-deployer -n ci-cd --duration=900s >"$WORKDIR/t"
  [[ -s "$WORKDIR/t" ]] || { log "STOP: token 발급 실패"; return 1; }
  local p; p=$(cut -d. -f2 "$WORKDIR/t" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p+='='; done
  printf '%s' "$p" | base64 -d | jq -e '{exp, iat, aud, sub} | select(.exp != null)' \
    >"$ev/10-token-claims.json"   # 만료를 확인할 수 없으면 여기서 실패 → STOP
  local life=$(( $(jq .exp "$ev/10-token-claims.json") - $(jq .iat "$ev/10-token-claims.json") ))
  (( life <= 900 )) || { log "STOP: 실제 유효기간 ${life}s > 900s (#46 계약 확정 전 상한)"; return 1; }
  # A/D 시험: oc --token="$(cat "$WORKDIR/t")" 형태는 인자 노출 → KUBECONFIG 임시 파일로 수행(실행본에서 확정)

  # ⑩-b 권한 목록 저장(R2) — 회수 전에 반드시
  bash "${KIT_DIR:?}/collect-access-inventory.sh" "$ev/10b-inventory"
  log "EVIDENCE_DIR $ev"
}
