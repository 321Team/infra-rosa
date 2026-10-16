# infra-rosa#7 실행 키트 — NetworkPolicy·Egress·Hybrid Route TCP 시험 (ROSA 생성 후)

- 작성: 이하영, 2026-10-16 KST. **실행 GO 아님.** 클러스터 실행 0건, mock 시험만 수행
- 대상: [infra-rosa#7](https://github.com/321Team/infra-rosa/issues/7) → 원티켓 baseline#38 AC-3(NetworkPolicy/Egress), AC-4(On-Prem 선행 TCP)
- 시험 계획: [`TEST-PLAN.md`](TEST-PLAN.md) (PR #35, 이권욱 APPROVE). 이 키트는 그 계획을 실행 단계로 나누고 #37 단계 C·D 순서에 끼워 넣는다
- 실행기: [`netpol-run.sh`](netpol-run.sh) · MOCK: [`tests/netpol-run-mock.sh`](tests/netpol-run-mock.sh)
- 비용: 이 시험이 만드는 AWS 자원 없음(기존 router, 소형 Pod 4개). 클러스터·임시 인스턴스 가동 비용은 **이권욱 판정 대상**
- 이 문서의 체크는 원티켓 AC 체크를 대신하지 않는다

## 1. 왜 #37 단계 C·D와 순서를 맞추나

| # | 사실 | 출처 | #7 영향 |
|---|---|---|---|
| F1 | 단계 B(터널 수립, route OFF)는 10/15 RUN `20261015T1100`에서 시험 후 **양쪽 원복**, 터널 유지 안 함 | infra-terraform#11 6183080378, 리뷰 6183290093 | 단계 C에서 터널을 **상시 유지 + Route ON**으로 다시 세워야 #7 P1이 가능 |
| F2 | 단계 C의 db01 규칙은 **runtime**(`10.20.10.0/24 → 5432`, 복귀 `10.20.0.0/16 via 10.1.93.51`)이고 단계 D 정리에서 `pre-rollback` | infra-vpn `p2-vpn-01/README.md` 단계 C-3·D | #7 P1·N1은 db01 사전 창이 열려 있을 때만 판정 가능 |
| F3 | route는 `onprem_route_keys=["private_a"]`만, db01 허용 출발지도 private_a | 같은 README 단계 C-1 | Pod egress는 Worker IP로 SNAT → Worker가 private_a여야 함 |
| F4 | ROSA Worker는 `private_a`(10.20.10.0/24) 1AZ × 3대 | infra-terraform `terraform/rosa-runtime` | F3과 맞음. 실행기 precheck가 실제 노드 IP로 다시 확인(`WORKER_CIDR`) |

TEST-PLAN C1은 `10.20.0.0/16`을 기준으로 했지만, 이 키트는 단계 C 허용 범위에 맞춰 **`10.20.10.0/24`로 좁혀** 판정한다.

## 2. 합동 순서

`[재환]` #37 단계 C·D, `[하영]` 이 키트, `[권욱]` Gate·원복 담당.

| 순번 | 담당 | 내용 | 실행기 단계 | 넘어가는 조건 |
|---|---|---|---|---|
| 0 | 하영 | 승인 입력으로 렌더, 해시 리뷰 | `render` | `RENDER_SUMS_SHA256` 리뷰 승인 |
| 1 | 권욱 | #4 ROSA Create → Cluster Ready | — | Cluster ID·대상 NS UID inventory |
| 2 | 하영 | 읽기 확인 + server dry-run | `precheck` | `PRECHECK_OK` |
| 3 | 재환 | **단계 C**: 터널 상시 수립, `private_a → Relay ENI` **Route ON**, 임시 인스턴스, db01 `pre-apply` | — | 단계 C 기록 댓글(`STAGE_C_REF`, `DB_WINDOW_REF`) |
| 4 | 재환 | 단계 D **T3 첫 PASS** | — | T3 기록 댓글(`T3_REF`) |
| **5** | **하영** | **시험 자원 생성 → 정책 전(B) 측정** | `stage-b` | `STAGE_B_OK` |
| **6** | **하영** | **00→01→02→03 적용 → 정책 후(A) 측정 → Handoff 8·9** | `stage-a` | `STAGE_A_PASS`, 재환 님께 "#7 종료" 통보 |
| 7 | 재환 | T6 → T3(복구 후) → T7~T9·T11 | — | — |
| 8 | 하영 | 시험 자원 정리(00~03 유지) | `cleanup` | `CLEANUP_OK` |
| 9 | 재환·권욱 | T12, 임시 인스턴스 삭제, db01 `pre-rollback`·readback | — | #7 5~6번이 끝난 뒤에만 |

- 5~6번을 T3 직후에 두는 이유: T6(SA 내림)·T7(재시작)·T8(재부팅) 중에는 터널이 흔들려 #7 B/A 판정이 섞인다.
- 5~6번은 **한 번에 이어서** 한다. 시험 Pod는 `sleep 3600`·재시작 없음이라 `stage-a`는 Pod 생성 후 `POD_MAX_AGE_MIN`(기본 50분) 안에 시작해야 한다.
- 대안(재환 님 창 시간 부족): 5~6번을 T11 뒤·T12 전에 둔다. **9번(`pre-rollback`) 뒤로는 미루지 않는다** — 그때는 P1·N1을 `PENDING(#37 창 없음)`으로 두고 별도 창 승인을 받는다.
- 단계 C가 "상시 터널"이어도 db01 규칙은 위 F2대로 runtime 사전 창이다(영구 반영은 #47 A2). 단계 C 계획이 바뀌면 `STAGE_C_REF`·`DB_WINDOW_REF`가 가리키는 기록과 이 표를 다시 맞춘다.

## 3. 입력값과 출처

| 변수 | 단계 | 값/출처 | 확정 전이면 |
|---|---|---|---|
| `NS`, `TEAM` | render | #5 대상 Namespace, `321team`(#3 수용) | render 안 함 |
| `DB_IP`, `DB_PORT` | render | IF-18 실행 입력 수용(후보 `10.1.93.55`/`5432`) | render 안 함 |
| `REG_MODE`, `REG_IP`, `REG_PORT` | render | D22. 미선택 `none`(03의 IF-19 블록 제거), 선택 `include` | render 안 함 |
| `TEST_IMAGE`, `HTTP_IMAGE` | render | ubi9/ubi-minimal, ubi9/httpd-24 — 실행 직전 `@sha256:` 고정 | render 안 함 |
| `CTX`, `API`, `EXPECTED_CLUSTER_ID`, `EXPECTED_NS_UID` | 클러스터 단계 | #4 Cluster Inventory, #5 Namespace UID | 실행 안 함 |
| `APPROVED_RENDER_SUMS_SHA256` | 클러스터 단계 | 0번 리뷰 승인값 | 실행 안 함 |
| `WORKER_CIDR` | precheck | 기본 `10.20.10.0/24`(private_a) | — |
| `STAGE_C_REF`, `T3_REF`, `DB_WINDOW_REF` | stage-b | #37/#11의 재환 님 기록 댓글 URL | **stage-b 시작 거부(rc 30)** |
| `N3_TARGET` | stage-b | 승인 밖 On-Prem 대상 `<ip>:<port>`(후보 `10.1.93.50:443`, 질문 Q3) | 시작 거부(rc 2) |
| `N2_PORT`, `N4_TARGET` | stage-b | 기본 `22`, `1.1.1.1:443` | — |
| `R1_EXPECTED_CODES` | stage-a | 기본 `200`. httpd-24 기본 페이지 응답 코드는 실제 확인 필요(열린 항목 O2) | — |

## 4. 실행 (실행 위치: #5 bootstrap/관리자 접속 경로, `oc` 로그인 상태)

각 단계는 `RUN_DIR` 안에서 **한 번만** 실행된다. 같은 단계를 다시 하려면 새 `RUN_DIR`로 `render`부터 한다.

```bash
# 0) render — 로컬, oc 호출 없음
RUN_DIR=~/netpol-$(TZ=Asia/Seoul date +%Y%m%dT%H%M) NS=fds-app TEAM=321team \
DB_IP=<IF-18> DB_PORT=<IF-18> REG_MODE=none TEST_IMAGE=<…@sha256:…> HTTP_IMAGE=<…@sha256:…> \
  bash platform/netpol/netpol-run.sh render
# → RENDER_SUMS_SHA256=<64hex> 를 리뷰 요청

# 공통 대상 값(이후 단계)
export RUN_DIR=<위 RUN_DIR> CTX=<context> API=https://api.<cluster>:443 \
  EXPECTED_CLUSTER_ID=<uuid> EXPECTED_NS_UID=<uuid> APPROVED_RENDER_SUMS_SHA256=<승인값>

# 2) precheck — 읽기 + server dry-run, 클러스터 변경 없음
bash platform/netpol/netpol-run.sh precheck

# 5) stage-b — #37 T3 PASS 직후
STAGE_C_REF=<url> T3_REF=<url> DB_WINDOW_REF=<url> N3_TARGET=<ip:port> \
  bash platform/netpol/netpol-run.sh stage-b

# 6) stage-a — stage-b 직후 이어서
bash platform/netpol/netpol-run.sh stage-a

# 8) cleanup
bash platform/netpol/netpol-run.sh cleanup
```

`stage-b`·`stage-a`는 시작·끝 시각을 `notice.txt`와 화면에 찍는다. **재환 님께 이 시각을 알려** Relay `to_onprem`·vpn-gw01 `from_vpc` 카운터와 db01 출발지 관측을 같은 구간으로 묶는다(질문 Q2). 각 시도의 UTC 시작·끝은 `results.tsv`에 있다.

## 5. 단계별 판정

| 단계 | 시험 | 기대 | 실패 시 |
|---|---|---|---|
| precheck | C1 Worker IP 전부 `WORKER_CIDR` / C3 OVN / C4 router 라벨 / C5 DNS 5353 / 대상 NS 비어 있음 / 7개 파일 server dry-run | 모두 충족 | rc 20 STOP(변경 없음) |
| stage-b (B) | P1 DB, N1 대조 Pod→DB, N5 Pod 간 진입, P3 DNS, (P2 Registry) | CONNECTED / OK | rc 40 — **정책 시험으로 넘어가지 않음**. 경로·T3 상태 확인 후 cleanup |
| stage-b (B) | N2 승인 밖 포트, N3 승인 밖 IP, N4 인터넷 | 기록만 | — |
| stage-a | 정책 집합 = 이 시험의 5개, 00 spec = `podSelector {}` + Ingress·Egress, 허용 규칙 없음 | 일치 | rc 42 STOP |
| stage-a (A) | P1, (P2), P3 | CONNECTED / OK | rc 50 |
| stage-a (A) | N1~N5 | TIMEOUT | CONNECTED면 rc 50, REFUSED·UNREACHABLE·TOOL_ERROR면 rc 51(차단 증거 아님) |
| stage-a | R1 `https://<route>/` (실행 위치=클러스터 밖), R2 `Admitted=True` | `R1_EXPECTED_CODES`, True | rc 50 |
| cleanup | 이 RUN이 만든 7개만 UID 대조 삭제, 00~03 UID·spec 유지 | 일치 | rc 60 HOLD(지우지 않음) |

- 정책 효과의 주 증거는 **N1(B CONNECTED → A TIMEOUT)** 이다. N2~N4는 B에서 이미 막혀 있을 수 있어 "승인 밖은 열려 있지 않음" 기록으로 쓴다.
- N1이 A에서 막힐 때 Relay `to_onprem` 카운터가 **늘지 않아야** 노드(OVN)에서 막힌 것이다(Q2 카운터 기록과 묶음).
- 자동 재시도·자동 원복은 없다. 실패하면 그 상태로 멈추고 `RUN_DIR`을 보존해 보고한다.

종료 코드 전체: `0` 성공, `2` 입력, `10` 대상 불일치, `11` 조회 오류, `20` precheck 불충족, `21` 렌더 해시/자리표시자, `30` 순서·시각(이전 단계 없음·재실행·Pod 수명), `40` B 기준 불성립, `41` apply·Ready 실패, `42` 정책 집합/00 spec, `50` A FAIL, `51` A 판정 불가, `60` cleanup HOLD.

## 6. Handoff (→ #4)

`stage-a/handoff.txt`:

| 항목 | 값 | 근거 |
|---|---|---|
| 8. Route 생성 가능 | `ROUTE_READY=YES\|NO` | R1, R2 |
| 9. Hybrid route prerequisite | `HYBRID_ROUTE=READY\|BLOCKED` + `STAGE_C_REF`·`T3_REF`·`DB_WINDOW_REF` | C1(`/24`), P1(A), N1(B→A) |

stage-b 전이면 9번은 `PENDING`(실행기 출력 없음)으로 #4에 적는다.

## 7. 증적·receipt

`fds-project-evidence` `evidence/P2-ROSA-01/<RUN>/` (증적 PR 독립 리뷰). `RUN_DIR` 구조:

| 경로 | 내용 |
|---|---|
| `state.env` | 입력값, 렌더 해시, 키트 SHA, source Git HEAD, #37 기록 링크 |
| `manifests/` + `SHA256SUMS` | 실제 적용한 렌더본 |
| `<단계>/commands.tsv`, `*.out/.err/.rc` | 모든 명령의 UTC 시각·rc·원본 출력 |
| `<단계>/context.txt` | `ENV=ROSA`, Cluster ID, NS·UID, whoami |
| `stage-b/created.tsv` | 만든 자원 이름·UID |
| `stage-*/results.tsv` | 단계·ID·시작/끝 UTC·Pod·목적지·rc·판정 |
| `stage-a/np-applied.tsv`, `np-yaml.out` | 00~03 UID·spec SHA-256, 적용 직후 원본 |
| `cleanup/cleanup.txt` | 자원별 DELETED / ALREADY_ABSENT / HOLD |

kubeconfig·토큰·Pull Secret 원문은 남기지 않는다(`whoami` 이름만).

권욱 님 receipt 조건([#7 리뷰](https://github.com/321Team/infra-rosa/issues/7))과의 대응:

| 조건 | 이 키트 |
|---|---|
| 00~03 source·승인 입력·실제 spec 연결 | `state.env`(source SHA·입력), `manifests/SHA256SUMS`, `np-applied.tsv`·`np-yaml.out` |
| 00은 실제 spec 확인, 기존 NP 합산 확인 | stage-a 00 spec 검사, precheck·stage-b 대상 NS 비어 있음, stage-a 정책 집합 5개 |
| B단계를 기존 정책 삭제로 만들지 않음 | NS가 비어 있지 않으면 precheck·stage-b STOP |
| `onprem-egress` 라벨 범위 | 시험 Pod `tcp-allowed`만. 앱 workload 라벨 검사는 #43 렌더 계약·#46 사전검사 소관(이 키트는 NS가 비어 있을 때만 실행) |
| 앱 NP 2개(#43) receipt | **이 키트 범위 밖** — 앱 배포 뒤 #5/#7 실행자가 별도 |
| 양성·음성·정리 실측 후에만 AC-3 판정 | `results.tsv`(B/A), 카운터 기록(재환), `cleanup.txt` |

## 8. 시험 범위와 열린 항목

- **MOCK:** `bash platform/netpol/tests/netpol-run-mock.sh` → 42/42 PASS (2026-10-16, Windows Git Bash, 가짜 `oc`·`curl`). 단계 순서·재실행 거부·판정 분기·쓰기 0(precheck)·UID 대조 정리를 본다. **실제 클러스터·OVN·router 동작 PASS가 아니다.**
- **O1:** 시험 이미지(ubi-minimal)에 `bash`·`timeout`·`getent`가 있는지 digest 고정 때 확인한다.
- **O2:** httpd-24 기본 응답 코드(빈 문서 루트면 200이 아닐 수 있음). 실제 확인 뒤 `R1_EXPECTED_CODES`를 정하고 리뷰에 적는다.
- **O3:** `oc exec`가 원격 종료 코드(124)를 그대로 돌려주는 것을 전제로 한다. 첫 실행에서 `probe-*.err`로 확인한다.
- **O4:** cleanup의 UID 대조와 삭제 사이에는 짧은 경합 구간이 있다(`oc delete`에 UID 조건 옵션 없음). 이 NS의 다른 writer가 없다는 시작 조건으로 막는다.
- 재환 님·권욱 님 확인 질문(Q1 순서, Q2 카운터, Q3 N3 대상, Q4 #47 경계, Q5 db01 창 길이, Q6 앱 NP 적용 전 시험 시점): 별도 댓글로 요청한다.

AI 사용: CLAUDE_ASSISTED (Claude Code, 이하영 지시로 작성)
