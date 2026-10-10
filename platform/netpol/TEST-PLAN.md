# infra-rosa#7 — NetworkPolicy·Egress·Hybrid Route TCP Test 계획 (초안)

- 작성: 이하영, 2026-10-10. **미리뷰·미적용.** 리뷰는 이권욱 님 우선(README 변경 절차: manifest는 코드 변경이라 독립 리뷰 후 적용)
- 대상 티켓: [infra-rosa#7](https://github.com/321Team/infra-rosa/issues/7) → 원티켓 [baseline#38](https://github.com/321Team/fds-project-baseline/issues/38) AC-3(NetworkPolicy/Egress), AC-4(On-Prem TCP)
- 이 문서의 체크는 원티켓 AC 체크를 대신하지 않는다.

## 0. 실행 전 채워야 할 값 (지금은 전부 미확정)

| 자리표시자 | 출처 | 현재(2026-10-10) |
|---|---|---|
| `__NS__`, `__TEAM__` | #5 최신 결정 6096648289 / #3 수용 6054292320 | ROSA는 승인된 대상 Namespace(`fds-app` 등), team=`321team`. `jX-<purpose>`는 SHARED_OCP_LAB에만 적용 |
| `__APPROVED_DB_IP__`, `__APPROVED_DB_PORT__` | baseline#37 handoff + Register IF-18 승인 | 후보 `10.1.93.55` / `5432`, **IF-18 실행 입력 미수용 — D21 transport 결정과 구분** |
| `__APPROVED_REG_IP__`, `__APPROVED_REG_PORT__` | Register IF-19, DEC-P2-REG-01(D22) | 후보 `10.1.93.54` / `443`, **D22 PENDING**. 선택 안 되면 03의 해당 블록 삭제 |
| `__TEST_IMAGE__`, `__HTTP_IMAGE__` | 실행 직전 digest 고정 | ubi9/ubi-minimal, ubi9/httpd-24 후보 |
| Cluster ID·Version, Worker 서브넷 | #4 Cluster Inventory | 클러스터 미생성 |

PROPOSED/PENDING 값은 수용 기록 전에 넣지 않는다. 자리표시자가 하나라도 남으면 적용하지 않는다.

## 1. 사전 확인 (클러스터 변경 없음)

| # | 확인 | 명령 예 | 기대 |
|---|---|---|---|
| C1 | Worker 노드 IP가 VPN selector `10.20.0.0/16` 안에 있음 | `oc get nodes -o wide` | 전부 10.20.x.x. 아니면 On-Prem 복귀 경로(`10.20.0.0/16 via 10.1.93.51`) 밖이라 중단·보고 |
| C2 | VPC route `10.1.93.0/24 → Relay ENI`가 Worker 서브넷 route table에 있음 | #37 handoff 증적 참조(AWS 콘솔/CLI 조회는 읽기 전용) | 있음 |
| C3 | Network plugin = OVNKubernetes | `oc get network.config cluster -o jsonpath='{.status.networkType}'` | `OVNKubernetes` |
| C4 | 기본 router Namespace 라벨 | `oc get ns openshift-ingress --show-labels` | `policy-group.network.openshift.io/ingress` 포함 |
| C5 | DNS Pod 포트 | `oc -n openshift-dns get pods -o jsonpath='{..containerPort}'` | 5353 포함 |

Pod에서 클러스터 밖으로 나가는 트래픽은 기본적으로 **Worker 노드 IP로 SNAT**된다. 그래서 On-Prem 쪽(db01 ACL 등)이 보는 Source는 Pod IP가 아니라 Worker IP다. C1이 중요한 이유다.

## 2. 적용 순서

1. 승인된 시험창·Namespace UID와 기존 자원/NetworkPolicy inventory를 확인한다. 동명 자원/기존 workload가 있으면 중단하고 격리 시험 범위를 정한다. 기존 정책을 삭제해서 B 단계를 만들지 않는다.
   - 사전 snapshot: `oc get networkpolicy,deploy,pod,svc,route -n __NS__ -o yaml` 원본과 각 NetworkPolicy의 이름·UID·`spec` SHA-256, Namespace UID를 저장한다.
   - **NetworkPolicy가 1개라도 있으면 B 단계는 성립하지 않는다.** 허용 규칙은 합산되므로 기존 allow 정책이 있으면 00~03만 보고 안전하다고 판단할 수 없다. 이 경우 변경 없이 STOP하고 격리 시험 namespace를 승인받는다.
   - 이 시험이 만드는 자원(`10`·`11`·`12`의 Pod·Service·Route·`probe-egress-to-route`)과 같은 이름이 이미 있으면 첫 변경 전에 STOP한다.
2. `10-test-pods.yaml`, `11-route-probe.yaml`, `12-ingress-isolation-probe.yaml`을 적용 → **정책 없는 상태 기준값(B 단계)** 측정
3. `00` → `01` → `02` → `03` 순서로 적용 → **정책 적용 후(A 단계)** 측정
4. 정책 적용 직후 `oc get networkpolicy -n __NS__ -o yaml` 원본 보존
5. A 단계 직후 NetworkPolicy 목록을 사전 snapshot과 대조한다. 이 시험이 만든 5개(`fds-platform-default-deny`, `allow-*` 3개, `probe-egress-to-route`) 외의 정책이 생겼으면 STOP하고 기록한다(다른 실행자의 allow 정책 혼입 탐지).

B 단계를 두는 이유: "막혔다"가 정책 때문인지, 원래 경로가 없어서인지 구분하려고. B에서 연결되던 것이 A에서 끊겨야 정책 효과로 인정한다.

## 3. 시험 케이스

판정 기준(Pod 안에서 `timeout 5 bash -c '</dev/tcp/<IP>/<PORT>'`):
- `CONNECTED` = RC 0
- `REFUSED` = 즉시 실패(상대가 RST). 경로는 열려 있다는 뜻이라 **정책 차단 증거가 아님**
- `TIMEOUT` = RC 124. NetworkPolicy 차단은 이 형태로 나온다

| ID | Pod | 목적지 | B(정책 전) 기대 | A(정책 후) 기대 | 증명하는 것 |
|---|---|---|---|---|---|
| P1 | tcp-allowed | 승인 DB IP:Port (IF-18) | CONNECTED | **CONNECTED** | AC-4 승인 경로 성공 |
| P2 | tcp-allowed | 승인 Registry IP:443 (IF-19, D22 선택 시만) | CONNECTED | **CONNECTED** | 선택 시에만. 아니면 `N/A(D22)` |
| P3 | tcp-allowed | DNS: `getent hosts kubernetes.default.svc.cluster.local` | 성공 | **성공** | 기본 차단 후에도 DNS 동작 |
| N1 | tcp-control | P1과 같은 목적지 | CONNECTED | **TIMEOUT** | 라벨 없는 Pod는 같은 Namespace여도 차단 (정책 효과 직접 증거) |
| N2 | tcp-allowed | 승인 DB IP의 비승인 포트(예: 22) | 기록만 | **TIMEOUT** | 승인 포트 외 차단 |
| N3 | tcp-allowed | 비승인 On-Prem IP(예: `10.1.93.50:443`, 승인 목록 밖) | 기록만 | **TIMEOUT** | 승인 IP 외 차단 |
| N4 | tcp-allowed | 인터넷(예: `1.1.1.1:443`) | 기록만 | **TIMEOUT** | 기본 Egress 차단 |
| N5 | ingress-probe → route-probe Pod IP:8080 (같은 NS) | Pod 간 직접 | CONNECTED | **TIMEOUT** | Ingress 기본 차단(router 외 진입 불가) |
| R1 | 클러스터 밖 | `https://<route host>/` | 200 | **200** | Handoff 8 Route 생성·노출 가능 |
| R2 | — | `oc get route route-probe -o jsonpath='{.status.ingress[0].conditions}'` | — | `Admitted=True` | Handoff 8 |

N5는 `12`의 정확한 송신 허용 정책을 B/A 모두 유지하여 수신 정책만 평가한다. 송신 차단만으로 TIMEOUT이 나면 Ingress 증적으로 인정하지 않는다.

N5 검출력 확인(음성 대조, 격리 LAB-PRECHECK에서만, 선택): 승인된 격리 namespace에서 route-probe에 대한 의도적 allow-all Ingress를 추가하면 N5가 `CONNECTED`로 바뀌어야 한다. 바뀌지 않으면 N5 설계가 수신 차단을 검출하지 못하는 것이므로 N5 결과를 증적으로 쓰지 않는다. 운영·대상 namespace에서는 하지 않는다.

N2~N4의 B 단계는 On-Prem 방화벽이나 NAT 여부에 따라 원래 막혀 있을 수 있다. 그래서 "정책 효과"의 주 증거는 **N1**(B CONNECTED → A TIMEOUT)이다. N2~N4는 "승인 밖은 열려 있지 않다"는 결과 기록으로 쓴다.

## 4. Trust bundle (On-Prem TLS) — TLS 서비스가 승인 목록에 있을 때만

- 대상: IF-19 harbor01:443이 D22에서 선택된 경우. DB 5432는 TLS 사용 여부가 승인값에 있을 때만 추가한다.
- 확인 방법: ROSA additional trust bundle(#4/#12 Registry trust 소관)이 들어간 뒤 `config.openshift.io/inject-trusted-cabundle=true` ConfigMap을 Pod에 마운트한다. 그다음 `openssl s_client -connect <approved-IP>:443 -servername <approved-TLS-DNS-name> -verify_hostname <approved-TLS-DNS-name> -CAfile <mounted>/ca-bundle.crt -verify_return_error </dev/null` (IP SAN 계약이면 `-verify_ip <approved-IP>` 사용)의 종료 코드 0과 `Verify return code: 0`을 함께 확인한다. 같은 CA가 서명했으나 SAN이 다른 시험 인증서는 실패해야 한다. 인증서/호스트의 승인값이 없으면 HOLD한다
- 대상이 없으면 `N/A(승인 TLS 경로 없음)`으로 기록한다

## 5. Evidence 필드 (케이스마다)

`ENV=ROSA`, Cluster ID, OCP Version, Namespace, Pod 이름·라벨, 목적지 IP:Port, 단계(B/A), 실행시각(KST), 명령, RC, 판정(CONNECTED/REFUSED/TIMEOUT), manifest SHA256, 원본 로그.
- 위치: `fds-project-evidence/evidence/P2-ROSA-01/` (증적 PR 독립 리뷰)
- kubeconfig·토큰·Pull Secret 원문은 저장하지 않는다
- Shared OCP에서 미리 돌린 결과는 `ENV=SHARED_OCP_LAB`, `LAB-PRECHECK`로만 기록한다. 이 경우 On-Prem 경로가 없으니 N1·N5·R1·R2만 의미가 있다

## 6. Handoff 출력 (→ #4)

| 항목 | 값 | 판정 근거 |
|---|---|---|
| 8. Route 생성 가능 상태 | `ROUTE_READY=YES\|NO` | R1, R2 |
| 9. baseline#37 Hybrid route prerequisite | `HYBRID_ROUTE=READY\|PENDING\|BLOCKED` + #37 handoff 링크 | C1, C2, P1, N1 |

## 7. 정리(teardown)

- 시험 자원 삭제: 이번 실행이 생성 직후 기록한 **이름·UID가 일치하는 자원만** 하나씩 삭제한다(`10`·`11`의 Pod·Service·Route, `12`의 Pod·`probe-egress-to-route`). UID가 다르거나 조회가 NotFound 외 오류면 삭제하지 않고 CLEANUP=HOLD로 기록한다.
- 정리 후 확인: 남긴 NetworkPolicy 4개(`00~03`)의 UID·`spec` SHA-256이 A 단계 기록과 같고, 사전 snapshot에 있던 자원이 그대로인지 대조한다.
- 디렉터리 전체 `oc delete -f platform/netpol/`은 복구 절차로 사용하지 않는다. 기준 정책을 되돌릴 필요가 있으면 사전 snapshot과 소유자 승인을 기준으로 복구한다.
- NetworkPolicy `00~03`은 **남긴다**(AC-3 상태 유지). 삭제 전후 `oc get all,networkpolicy,route -n __NS__` 목록 보존

## 8. 비용

- 추가 AWS 리소스 없음: Route는 기존 기본 router를 쓰고, LoadBalancer를 새로 만들지 않음. Pod 3개는 기존 Worker 위의 소형 자원
- 클러스터 가동 시간 자체의 비용은 이 시험과 별개 → 이권욱 판정 대상

## 9. 열린 질문 (리뷰 때 확인)

1. On-Prem 쪽 db01 ACL이 Worker 서브넷 전체(`10.20.0.0/16`)를 허용하는지, Worker 서브넷만 허용하는지 (#37/IF-18 Source 조건)
2. Egress 통제를 NetworkPolicy만으로 할지, Namespace 단위 `EgressFirewall`(OVN)을 추가할지. 초안은 NetworkPolicy만 사용(범위 최소)
3. N3에 쓸 "비승인 On-Prem IP"를 어떤 주소로 할지(승인 목록 밖이면서 존재하는 호스트 권장)

## 시험 경계 보완

- P2(Registry TCP)는 Pod의 TCP 경로만 검증한다. kubelet/CRI node image pull·CA trust·인증·cold-pull은 #12/#42 증적을 소비한다.
- 기존 NetworkPolicy는 허용 규칙이 합산되므로 전체 inventory를 대조한다(§2). 플랫폼 기본 차단은 `fds-platform-default-deny`(#7 소유)로 이름을 분리했다. fds-msa `deploy/base`의 `default-deny-all`·앱 허용 정책은 #43 소유이며, 적용 주체는 [#5 정의서 v2 §3-4](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6096968877)의 생산·소비 계약을 따른다.
- PR36의 PG03은 v2에서 admission 조회 전용(쓰기 0건)으로 바뀌었다. 이후 Runtime 시험도 자기가 생성한 이름·UID만 정리하며 이 시험이 남기는 정책을 삭제하지 않는다.
- IPv4/IPv6, DNS UDP/TCP, router 실제 source 경로는 실제 환경에서 확인한다. EgressFirewall 추가는 새 필수조건으로 만들지 않는다.
- ROSA용 시험을 위해 Phase 1 Harbor/DB ACL, CA, 운영 namespace 또는 정책을 변경하지 않는다.
