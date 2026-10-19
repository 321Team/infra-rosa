# infra-rosa#5 — bootstrap 회차 단계 파일 (bootstrap-session.sh 가 source 함)
# 첫 설정 순서 v2/v3 ③~⑩-b. 실패하면 set -e 로 즉시 cleanup(회수)으로 가고 다음 단계는 실행되지 않는다.
#
# 입력(env): MANIFEST_DIR(기본 ../manifests), KIT_DIR(이 디렉터리),
#            ROUTE_HOST(선택: 승인 Route host. 없으면 A-09 는 NOT_RUN 기록 — #4 Handoff 2 후 확정)
# [AFTER-CREATE] 표시는 실제 클러스터가 생긴 뒤에만 확인할 수 있는 항목이다(가정하지 않음).
#
# token 취급: 원문을 명령 인자·로그·증적에 넣지 않는다. 파일(umask 077, 700 디렉터리)과
#             bash 내장(printf, $(<file))로만 다루고, 배포 SA 시험은 SA 전용 kubeconfig 로 한다.

SA_IDENT="system:serviceaccount:ci-cd:fds-deployer"

# 실제 요청 결과 분류: ALLOW(rc0) / DENY(RBAC 거부) / OTHER(그 밖의 오류 — 판정 불가로 STOP)
# DENY 는 "(Forbidden)" 만으로 인정하지 않는다(PR#40 보완 5). quota·admission webhook 거부도 403 Forbidden 이라
# 권한이 있는데 다른 이유로 막힌 것을 '정상 거부'로 오판할 수 있다. RBAC 거부 문장
#   User "<identity>" cannot <verb> resource "<resource>"
# 이 정확한 주체로 있을 때만 DENY. [AFTER-CREATE] 실제 ROSA 4.22 거부 메시지 형식을 첫 실행 증적으로 확인.
_classify() {
  local rc=$1 errf=$2 ident=$3
  if [[ $rc -eq 0 ]]; then echo ALLOW
  elif grep -q '(Forbidden)' "$errf" && grep -qF "User \"$ident\" cannot " "$errf" \
       && grep -qE 'cannot [a-z]+ resource "' "$errf"; then echo DENY
  else echo OTHER; fi
}

# expect <id> <ALLOW|DENY> <identity> -- <command...>
#   기대와 다르면 STOP(return 1 → 회수). 결과는 $EV/results.tsv, 원본은 $EV/req/<id>.{out,err}.
expect() {
  local id=$1 want=$2 subj=$3; shift 4
  local out="$EV/req/$id.out" err="$EV/req/$id.err" rc=0 got
  "$@" >"$out" 2>"$err" || rc=$?
  got=$(_classify "$rc" "$err" "$subj")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$subj" "$*" "$want" "$got" "$rc" >>"$EV/results.tsv"
  [[ "$got" == "$want" ]] || { log "STOP: $id expect=$want got=$got rc=$rc"; return 1; }
}

# expect_cani <id> <yes|no> <subject> -- <oc auth can-i args...>  (SSAR/SAR: 정확한 yes/no 만 인정)
expect_cani() {
  local id=$1 want=$2 subj=$3; shift 4
  local out="$EV/req/$id.out" err="$EV/req/$id.err" rc=0 got
  "$@" >"$out" 2>"$err" || rc=$?
  got=OTHER
  [[ $rc -eq 0 && "$(<"$out")" == yes ]] && got=yes
  [[ $rc -eq 1 && "$(<"$out")" == no && ! -s "$err" ]] && got=no
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$subj" "$*" "$want" "$got" "$rc" >>"$EV/results.tsv"
  [[ "$got" == "$want" ]] || { log "STOP: $id expect=$want got=$got rc=$rc"; return 1; }
}

_sa()  { oc --kubeconfig="$WORKDIR/sa.kubeconfig" "$@"; }
# 쓰기 시험은 모두 --dry-run=server: 인가(authz)는 실제로 거치고 저장은 하지 않는다.
_np_probe() {
  _sa apply --dry-run=server -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: d12b-probe, namespace: fds-app}
spec: {podSelector: {}, policyTypes: [Ingress]}
YAML
}
_token_probe() { _sa create token fds-deployer -n ci-cd --duration=600s >/dev/null; }  # 허용되면 token 이 stdout 에 → 버림

run_steps() {
  local ns sa uid sa_names u ca
  EV="$WORKDIR/evidence-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$EV/req"
  : "${MANIFEST_DIR:=${KIT_DIR:?}/../manifests}"
  printf 'id\tsubject\trequest\texpect\tobserved\trc\n' >"$EV/results.tsv"

  # ③ 로그인(비밀번호는 프롬프트에 본인 입력) + 대상 결속. Cluster ID↔API 는 래퍼가 grant 전에 확인했다(F1).
  [[ "$KUBECONFIG" == "$WORKDIR/kubeconfig" ]] || { log "STOP: 전용 KUBECONFIG 아님"; return 1; }
  oc login "$API_URL" -u "$U"
  [[ "$(oc whoami)" == "$U" ]] || { log "STOP: whoami 불일치"; return 1; }
  [[ "$(oc whoami --show-server)" == "$API_URL" ]] || { log "STOP: server 불일치"; return 1; }
  # grant 반영 대기(#5 2회차 6262238397): 로그인 자체는 권한 없이도 되므로, 첫 단계 전에 이 세션의 SSAR 이
  # 정확히 yes 가 될 때까지 래퍼 안에서 기다린다. 다른 탭·Ctrl+C 가 필요 없게 한다. 시간 초과면 STOP(→ 회수).
  local w gw_out
  for ((w = 1; w <= ${GRANT_WAIT_TRIES:-30}; w++)); do
    gw_out=$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null) || true
    printf '%s try=%s %s\n' "$(date '+%FT%T%z')" "$w" "${gw_out:-ERR}" >>"$EV/03-grant-wait.txt"
    [[ "$gw_out" == yes ]] && break
    ((w < ${GRANT_WAIT_TRIES:-30})) && sleep "${GRANT_WAIT_INTERVAL:-10}"
  done
  [[ "$gw_out" == yes ]] || { log "STOP: grant 반영 대기 시간 초과"; return 1; }
  log "GRANT_EFFECTIVE try=$w"
  ( cd "$MANIFEST_DIR" && sha256sum namespaces.yaml rbac.yaml human-bindings.yaml ) >"$EV/00-manifest-sha256.txt"
  # 대상 기록(PR#40 보완 3): post-revoke-check.sh 가 이 회차의 클러스터·API·사용자와 같은지 대조한다.
  printf 'CLUSTER_ID=%s\nAPI_URL=%s\nUSER=%s\nSTARTED_AT=%s\n' \
    "$CLUSTER_ID" "$API_URL" "$U" "$(date '+%FT%T%z')" >"$EV/00-target.env"
  # grant 상태의 `rosa list users` 원문(기록만, 판정·중단 없음). [AFTER-CREATE] 머리글·본문 행 형식을 실측으로 확정하기 위한 증적.
  local r
  r=0; rosa list users -c "$CLUSTER_ID" >"$EV/03-granted-users.out" 2>"$EV/03-granted-users.err" || r=$?
  printf 'granted-users rc=%s\n' "$r" >"$EV/03-granted-users.rc"

  # ④ 기본 상태 읽기(쓰기 없음). [AFTER-CREATE] dedicated-admins·cluster-admins 그룹 실제 이름, UWM 활성 여부
  # 없을 수 있는 두 항목은 실패해도 멈추지 않되, 실패 사실과 rc 를 반드시 기록한다(PR#40 보완 4 — 조용히 넘기지 않음).
  oc get groups -o yaml >"$EV/04-groups.yaml"
  # #4 Handoff(#38 인계표) 1번 OpenShift cluster UUID·3번 노드 Ready. 회수 뒤 namespace admin 으로는 읽을 수 없으므로
  # cluster-admin 이 있는 지금 읽는다. 읽기 실패·값 없음이면 STOP(→ 회수). 판정(3/3 Ready 등)은 증적 리뷰에서 한다.
  oc get clusterversion version -o json >"$EV/04-clusterversion.json" || { log "STOP: clusterversion 조회 실패"; return 1; }
  oc get nodes -o json >"$EV/04-nodes.json" || { log "STOP: nodes 조회 실패"; return 1; }
  oc get nodes -o wide >"$EV/04-nodes-wide.txt" || { log "STOP: nodes(wide) 조회 실패"; return 1; }
  # 값은 변수에 먼저 받는다 — printf 인자 안의 $(...) 실패는 set -e 로 멈추지 않기 때문.
  local cv_uuid cv_ver n_count n_rows
  cv_uuid=$(jq -er '.spec.clusterID | select(type == "string" and length > 0)' "$EV/04-clusterversion.json") \
    || { log "STOP: cluster UUID 없음/판독 실패"; return 1; }
  cv_ver=$(jq -er '.status.desired.version | select(type == "string" and length > 0)' "$EV/04-clusterversion.json") \
    || { log "STOP: cluster version 없음/판독 실패"; return 1; }
  n_count=$(jq -er '.items | length | select(. > 0)' "$EV/04-nodes.json") \
    || { log "STOP: 노드 0개/판독 실패"; return 1; }
  n_rows=$(jq -er '.items[] | "NODE\t\(.metadata.name)\tReady=\([.status.conditions[]? | select(.type == "Ready") | .status][0] // "UNKNOWN")"' "$EV/04-nodes.json") \
    || { log "STOP: 노드 행 판독 실패"; return 1; }
  printf 'OPENSHIFT_CLUSTER_UUID=%s\nCLUSTER_VERSION=%s\nNODE_COUNT=%s\n%s\n' \
    "$cv_uuid" "$cv_ver" "$n_count" "$n_rows" >"$EV/04-handoff-1-3.txt"
  r=0; oc get clusterrolebinding self-provisioners -o yaml >"$EV/04-self-provisioners.yaml" 2>&1 || r=$?
  printf 'self-provisioners rc=%s\n' "$r" >>"$EV/04-read-rc.txt"
  r=0; oc get pods -n openshift-user-workload-monitoring -o wide >"$EV/04-uwm-pods.txt" 2>&1 || r=$?
  printf 'uwm-pods rc=%s\n' "$r" >>"$EV/04-read-rc.txt"

  # ⑤ Namespace + UID
  oc apply -f "$MANIFEST_DIR/namespaces.yaml"
  for ns in fds-app monitoring-api ci-cd; do
    uid=$(oc get ns "$ns" -o jsonpath='{.metadata.uid}') \
      || { log "STOP: Namespace UID 조회 실패 ($ns)"; return 1; }
    [[ -n "$uid" ]] || { log "STOP: Namespace UID 비어 있음 ($ns)"; return 1; }
    printf '%s %s\n' "$ns" "$uid" >>"$EV/05-ns-uid.txt"
  done

  # ⑥ 자동 생성 SA·RoleBinding 기록(삭제하지 않음, C1·C2)
  for ns in fds-app monitoring-api ci-cd; do
    oc get sa,rolebinding -n "$ns" -o yaml >"$EV/06-defaults-$ns.yaml"
  done

  # ⑦ 배포 SA·앱 SA·Role/RoleBinding
  oc apply -f "$MANIFEST_DIR/rbac.yaml"
  # ⑦-a #7 NetworkPolicy, #43/#12 Secret 은 각 소유자 절차(여기서 호출하지 않음)

  # ⑧ 사람 binding(하영 admin·권욱 view·재환 view+fds-app monitoring-edit) + ClusterRole 규칙 기록
  oc apply -f "$MANIFEST_DIR/human-bindings.yaml"
  oc get clusterrole admin view monitoring-edit -o yaml >"$EV/08-clusterroles.yaml"

  # ⑨ 권한 판정(관리자 창 안에서만). --as 는 보조 자료 — SA 는 ⑩ 실제 token, 사람은 회수 뒤 본인 세션으로 재확인.
  for ns in fds-app monitoring-api ci-cd; do
    sa_names=$(oc get sa -n "$ns" -o jsonpath='{.items[*].metadata.name}') \
      || { log "STOP: SA 목록 조회 실패 ($ns)"; return 1; }
    [[ -n "$sa_names" ]] || { log "STOP: SA 목록 비어 있음 ($ns)"; return 1; }
    for sa in $sa_names; do
      oc auth can-i --list -n "$ns" --as="system:serviceaccount:$ns:$sa" >"$EV/09-cani-$ns-$sa.txt"
    done
    for u in hayeoung gwonuk jaehwan; do
      oc auth can-i --list -n "$ns" --as="$u" \
        --as-group=system:authenticated --as-group=system:authenticated:oauth >"$EV/09-cani-$ns-user-$u.txt"
    done
  done
  # 이재환 J-1~J-8 (6162956338). 사람 그룹(system:authenticated·:oauth)을 함께 지정.
  local G=(--as-group=system:authenticated --as-group=system:authenticated:oauth)
  expect_cani J-1 yes jaehwan -- oc auth can-i create servicemonitors.monitoring.coreos.com -n fds-app --as=jaehwan "${G[@]}"
  expect_cani J-2 yes jaehwan -- oc auth can-i create prometheusrules.monitoring.coreos.com -n fds-app --as=jaehwan "${G[@]}"
  for ns in fds-app monitoring-api ci-cd; do
    expect_cani "J-3-$ns" yes jaehwan -- oc auth can-i get pods -n "$ns" --as=jaehwan "${G[@]}"
  done
  expect_cani J-4 no jaehwan -- oc auth can-i create deployments.apps -n fds-app --as=jaehwan "${G[@]}"
  expect_cani J-5 no jaehwan -- oc auth can-i create servicemonitors.monitoring.coreos.com -n monitoring-api --as=jaehwan "${G[@]}"
  expect_cani J-6 no jaehwan -- oc auth can-i create rolebindings.rbac.authorization.k8s.io -n fds-app --as=jaehwan "${G[@]}"
  expect_cani J-7 no jaehwan -- oc auth can-i list nodes --as=jaehwan "${G[@]}"
  expect_cani J-8 no jaehwan -- oc auth can-i get secrets -n fds-app --as=jaehwan "${G[@]}"
  # 하영 clusterversion/version get 최소 권한(#5 6258874244). --as 그룹에 cluster-admins 를 넣지 않으므로
  # 임시 cluster-admin 이 아니라 이 바인딩만으로 판정된다. 회수 뒤에는 post-revoke-check.sh 가 본인 세션으로 다시 확인.
  expect_cani H-1 yes "$U" -- oc auth can-i get clusterversions.config.openshift.io/version --as="$U" "${G[@]}"
  expect_cani H-2 no  "$U" -- oc auth can-i list clusterversions.config.openshift.io --as="$U" "${G[@]}"
  expect_cani H-3 no  "$U" -- oc auth can-i update clusterversions.config.openshift.io/version --as="$U" "${G[@]}"

  # ⑩ 배포 SA 실제 token 시험(900초 요청, 원문 미출력)
  oc create token fds-deployer -n ci-cd --duration=900s >"$WORKDIR/t"
  [[ -s "$WORKDIR/t" ]] || { log "STOP: token 발급 실패"; return 1; }
  local p; p=$(cut -d. -f2 "$WORKDIR/t" | tr '_-' '/+')
  while (( ${#p} % 4 )); do p+='='; done
  # claim: exp/iat 숫자, 0 < exp-iat <= 900, 미만료, sub 정확, aud 비어 있지 않음.
  # [AFTER-CREATE] aud 실제 값 기록 → #46 소비 계약 확정 후 정확 일치로 바꾼다.
  printf '%s' "$p" | base64 -d | jq -e --argjson now "$(date +%s)" \
      --arg sub "system:serviceaccount:ci-cd:fds-deployer" '
    select((.exp | type) == "number" and (.iat | type) == "number")
    | select((.exp - .iat) > 0 and (.exp - .iat) <= 900)
    | select(.exp > $now)
    | select(.sub == $sub)
    | select((.aud // []) | length > 0)
    | {exp, iat, life: (.exp - .iat), aud, sub}' \
    >"$EV/10-token-claims.json" \
    || { log "STOP: token claim 검사 실패(만료 확인 불가·900초 초과·sub/aud 불일치)"; return 1; }

  # SA 전용 kubeconfig: token 은 bash 내장으로만 파일에 쓴다(프로세스 인자에 안 나타남).
  # CA 는 하영 세션 kubeconfig 의 값을 그대로 쓴다. 비어 있으면 시스템 신뢰 저장소 — TLS 검증 해제는 하지 않는다.
  ca=$(oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  {
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: rosa\n  cluster:\n    server: %s\n' "$API_URL"
    [[ -n "$ca" ]] && printf '    certificate-authority-data: %s\n' "$ca"
    printf 'users:\n- name: fds-deployer\n  user:\n    token: %s\n' "$(<"$WORKDIR/t")"
    printf 'contexts:\n- name: sa\n  context: {cluster: rosa, user: fds-deployer, namespace: fds-app}\n'
    printf 'current-context: sa\n'
  } >"$WORKDIR/sa.kubeconfig"
  [[ "$(_sa whoami)" == "$SA_IDENT" ]] || { log "STOP: SA 세션 identity 불일치"; return 1; }

  # 허용(A)·거부(D) — 실제 SA token 요청. 쓰기는 --dry-run=server. DENY 는 이 SA 주체의 RBAC 거부 문장일 때만 인정.
  local S="$SA_IDENT"
  expect A-01 ALLOW "$S" -- _sa create deployment a01-probe --image=registry.invalid/probe:0 -n fds-app --dry-run=server
  expect A-03 ALLOW "$S" -- _sa get pods -n fds-app
  expect A-04 ALLOW "$S" -- _sa create route edge a04-probe --service=none -n fds-app --dry-run=server
  if [[ -n "${ROUTE_HOST:-}" ]]; then
    expect A-09 ALLOW "$S" -- _sa create route edge a09-probe --service=none --hostname="$ROUTE_HOST" -n fds-app --dry-run=server
  else
    printf 'A-09\t%s\troute custom-host create\tALLOW\tNOT_RUN(승인 host PENDING)\t-\n' "$S" >>"$EV/results.tsv"
  fi
  expect D-01   DENY "$S" -- _sa create deployment d01-probe --image=registry.invalid/probe:0 -n monitoring-api --dry-run=server
  expect D-02a  DENY "$S" -- _sa get pods -n openshift-monitoring
  expect D-03a  DENY "$S" -- _sa get secrets -n fds-app
  expect D-04   DENY "$S" -- _sa delete deployment d04-probe -n fds-app --dry-run=server
  expect_cani D-05 no "$S" -- _sa auth can-i create pods/exec -n fds-app
  expect D-06a  DENY "$S" -- _sa create rolebinding d06-probe --clusterrole=view --user=nobody -n fds-app --dry-run=server
  expect D-06d  DENY "$S" -- _token_probe
  expect D-07a  DENY "$S" -- _sa get nodes
  expect D-07b  DENY "$S" -- _sa create namespace d07-probe --dry-run=server
  expect D-07c  DENY "$S" -- _sa get securitycontextconstraints restricted-v2
  expect D-12a  DENY "$S" -- _sa create serviceaccount d12-probe -n fds-app --dry-run=server
  expect D-12b  DENY "$S" -- _np_probe
  expect D-13c  DENY "$S" -- _sa create route edge d13-probe --service=none --hostname=probe.invalid -n monitoring-api --dry-run=server
  expect_cani MON-D-14 no "$S" -- _sa auth can-i create servicemonitors.monitoring.coreos.com -n fds-app
  rm -f -- "$WORKDIR/sa.kubeconfig"   # 정상 경로 정리. 실패로 중간에 끝나도 래퍼 cleanup 이 t·sa.kubeconfig 를 지운다(보완 1)
  # D-10(실제 만료 후 401)은 15분 대기가 필요해 bootstrap 창 밖, post-revoke-check.sh 이후 별도 기록.

  # ⑩-b 권한 목록 저장(R2) — 회수 전에 반드시. 승인 경로 외가 있으면 회수 전에 STOP.
  bash "$KIT_DIR/collect-access-inventory.sh" "$EV/10b-inventory"
  # 분류는 classify-access-paths.sh(오프라인 공용 규칙, PR#40 리뷰 5530426592 R1): 정확한 3개 namespace,
  # roleRef·주체 정확 일치, 플랫폼 기본 binding 은 리뷰된 policy 의 실제 규칙 sha256 까지 대조.
  # [AFTER-CREATE] policy(../policy/platform-defaults.approved.tsv)는 첫 실행 증적을 보고 PR 리뷰로 만든다.
  #   없으면 기본 binding 은 PENDING_POLICY → 회수는 정상으로 하고 래퍼 rc=3(정책 승인 대기)으로 끝낸다.
  #   승인 뒤 post-revoke-check.sh 가 저장된 증적을 같은 규칙으로 오프라인 재판정한다(마스터키 재발급 불필요).
  local crc=0
  bash "$KIT_DIR/classify-access-paths.sh" "$EV/10b-inventory" "$U" "${POLICY_FILE:-$KIT_DIR/../policy/platform-defaults.approved.tsv}" \
    "$EV/10b-path-review.tsv" || crc=$?
  case "$crc" in
    0) ;;
    3) log "POLICY_PENDING: 기본 binding 승인 목록 없음 — 회수 후 rc=3 으로 종료($EV/10b-path-review.tsv)"
       POLICY_PENDING=1 ;;
    *) log "STOP: 승인 경로 외 권한 경로 또는 수집 누락 — $EV/10b-path-review.tsv 검토(회수 전)"; return 1 ;;
  esac
  log "EVIDENCE_DIR $EV"
  [[ "${POLICY_PENDING:-0}" == 1 ]] && return 3
  return 0
}
