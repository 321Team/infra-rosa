# infra-rosa#7 — NetworkPolicy·Egress·Hybrid Route TCP Test 계획 (초안)

- 작성: 이하영, 2026-10-10. **미리뷰·미적용.** 리뷰는 이권욱 님 우선(README 변경 절차: manifest는 코드 변경이라 독립 리뷰 후 적용)
- 대상 티켓: [infra-rosa#7](https://github.com/321Team/infra-rosa/issues/7) → 원티켓 [baseline#38](https://github.com/321Team/fds-project-baseline/issues/38) AC-3(NetworkPolicy/Egress), AC-4(On-Prem TCP)
- 이 문서의 체크는 원티켓 AC 체크를 대신하지 않는다.

## 0. 실행 전 채워야 할 값 (지금은 전부 미확정)

| 자리표시자 | 출처 | 현재(2026-10-10) |
|---|---|---|
| `__NS__`, `__TEAM__` | #5 / baseline#38 "Target Namespace/Team Code" | PENDING. 규칙상 `j1-<purpose>` 형식(예: `j1-fds-app`) |
| `__APPROVED_DB_IP__`, `__APPROVED_DB_PORT__` | baseline#37 handoff + Register IF-18 승인 | 후보 `10.1.93.55` / `5432`, **PROVISIONAL — D21 PENDING** |
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

1. `10-test-pods.yaml`, `11-route-probe.yaml` 먼저 적용 → **정책 없는 상태 기준값(B 단계)** 측정
2. `00` → `01` → `02` → `03` 순서로 적용 → **정책 적용 후(A 단계)** 측정
3. 정책 적용 직후 `oc get networkpolicy -n __NS__ -o yaml` 원본 보존

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
| N5 | tcp-allowed → route-probe Pod IP:8080 (같은 NS) | Pod 간 직접 | CONNECTED | **TIMEOUT** | Ingress 기본 차단(router 외 진입 불가) |
| R1 | 클러스터 밖 | `https://<route host>/` | 200 | **200** | Handoff 8 Route 생성·노출 가능 |
| R2 | — | `oc get route route-probe -o jsonpath='{.status.ingress[0].conditions}'` | — | `Admitted=True` | Handoff 8 |

N2~N4의 B 단계는 On-Prem 방화벽이나 NAT 여부에 따라 원래 막혀 있을 수 있다. 그래서 "정책 효과"의 주 증거는 **N1**(B CONNECTED → A TIMEOUT)이다. N2~N4는 "승인 밖은 열려 있지 않다"는 결과 기록으로 쓴다.

## 4. Trust bundle (On-Prem TLS) — TLS 서비스가 승인 목록에 있을 때만

- 대상: IF-19 harbor01:443이 D22에서 선택된 경우. DB 5432는 TLS 사용 여부가 승인값에 있을 때만 추가한다.
- 확인 방법: ROSA additional trust bundle(#4/#12 Registry trust 소관)이 들어간 뒤 `config.openshift.io/inject-trusted-cabundle=true` ConfigMap을 Pod에 마운트한다. 그다음 `openssl s_client -connect <IP>:443 -CAfile <mounted>/ca-bundle.crt -verify_return_error`의 `Verify return code: 0` 확인
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

- 시험 자원 삭제: `oc delete -f 10-test-pods.yaml -f 11-route-probe.yaml`
- NetworkPolicy `00~03`은 **남긴다**(AC-3 상태 유지). 삭제 전후 `oc get all,networkpolicy,route -n __NS__` 목록 보존

## 8. 비용

- 추가 AWS 리소스 없음: Route는 기존 기본 router를 쓰고, LoadBalancer를 새로 만들지 않음. Pod 3개는 기존 Worker 위의 소형 자원
- 클러스터 가동 시간 자체의 비용은 이 시험과 별개 → 이권욱 판정 대상

## 9. 열린 질문 (리뷰 때 확인)

1. On-Prem 쪽 db01 ACL이 Worker 서브넷 전체(`10.20.0.0/16`)를 허용하는지, Worker 서브넷만 허용하는지 (#37/IF-18 Source 조건)
2. Egress 통제를 NetworkPolicy만으로 할지, Namespace 단위 `EgressFirewall`(OVN)을 추가할지. 초안은 NetworkPolicy만 사용(범위 최소)
3. N3에 쓸 "비승인 On-Prem IP"를 어떤 주소로 할지(승인 목록 밖이면서 존재하는 호스트 권장)
