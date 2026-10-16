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
| F1 | 단계 B(터널 수립, route OFF)는 10/15 RUN `20261015T1100`에서 시험 후 **양쪽 원복**, 터널 유지 안 함 | infra-terraform#11 6183080378, 리뷰 6183290093 | 단계 C에서 터널·Route를 다시 세워야 #7 P1이 가능 |
| F2 | 단계 C의 db01 규칙은 **runtime**(`10.20.10.0/24 → 5432`, 복귀 `10.20.0.0/16 via 10.1.93.51`)이고 단계 D 정리에서 `pre-rollback` | infra-vpn `p2-vpn-01/README.md` 단계 C-3·D | #7 P1·N1은 db01 사전 창이 열려 있을 때만 판정 가능 |
| F3 | route는 `onprem_route_keys=["private_a"]`만, db01 허용 출발지도 private_a | 같은 README 단계 C-1 | Pod egress는 Worker IP로 SNAT → Worker가 private_a여야 함 |
| F4 | ROSA Worker는 `private_a`(10.20.10.0/24) 1AZ × 3대 | infra-terraform `terraform/rosa-runtime` | F3과 맞음. precheck가 실제 노드 IP로 다시 확인(`WORKER_CIDR`) |
| F5 | Relay SG는 worker 서브넷에서 TCP 5432만 허용 | #37 [6205733242](https://github.com/321Team/fds-project-baseline/issues/37#issuecomment-6205733242) Q3 | N2·N3은 B부터 SG에서 막힐 수 있음 → 정책 효과를 주장하지 않음(§5) |

TEST-PLAN C1은 `10.20.0.0/16`을 기준으로 했지만, 이 키트는 단계 C 허용 범위에 맞춰 **`10.20.10.0/24`로 좁혀** 판정한다.

## 2. 합동 순서

`[하영]` 이 키트·#4/#35 승인 범위 실행, `[재환]` #37 터널·단계 D 시험, `[권욱]` Gate·원복 통제.

| 순번 | 담당 | 내용 | 실행기 단계 | 넘어가는 조건 |
|---|---|---|---|---|
| 0 | 하영 | 승인 입력으로 렌더 → bundle 해시 리뷰 | `render` | `BUNDLE_SHA256` 리뷰 승인 |
| 1 | 하영 / 권욱 Gate | #4 ROSA Create(승인 범위 실행) → Cluster Ready·Inventory | — | Cluster ID |
| 2 | #5 | `fds-app` 생성·소유권·**Namespace UID 확인** | — | NS UID |
| 3 | 하영 | 읽기 확인 + server dry-run, 대상 고정(`target.env`), 창 시작 출발지 목록(`worker-ips.tsv`) | `precheck` | `PRECHECK_OK` |
| 4 | 재환 / 하영(#35) | **단계 C**: 재환 터널 수립·회차 조율, 하영 #35 Terraform route·SG Plan/Apply(`private_a → Relay ENI`), 승인된 db01 runtime 사전 창 `pre-apply` | — | 단계 C·db01 창 기록(`STAGE_C_REF`, `DB_WINDOW_REF`) |
| 5 | 재환 | 단계 D **T3 첫 PASS** → 안정 구간을 하영에게 인계 | — | T3 기록(`T3_REF`) |
| **6** | **하영** | **시험 자원 생성 → 정책 전(B) 측정** (재환 전후 카운터 관측) | `stage-b` | `STAGE_B_OK` |
| **7** | **하영** | **00→01→02→03 적용 → 정책 후(A) 측정 → Handoff 8·9** | `stage-a` | `STAGE_A_PASS`, 재환 님께 "#7 종료" 통보 |
| 8 | 하영 | 시험 자원 정리(00~03 유지) | `cleanup` | `CLEANUP_OK` |
| 9 | 재환 | T6 → T3(복구 후). **T7·T9·T11은 다음 창**(db01 창 시간, #37 Q1). T8은 원래 별도 창 | — | — |
| 10 | 재환 / 권욱 원복 통제 | T12, 임시 인스턴스 삭제, db01 `pre-rollback`·readback | — | #7 6~8번 확인 뒤 |

- 6~7번을 T3 직후에 두는 이유: T6(SA 내림)·T7(재시작)·T8(재부팅) 중에는 터널이 흔들려 #7 B/A 판정이 섞인다. 이 구간에 장애 유발 작업을 겹치지 않는다.
- 터널·Route 상시 유지 여부는 **이권욱 결정 대기**(#37 6205733242 "먼저 정할 것 1"). 결정 전에는 창 단위로 진행하며, 어느 쪽이든 6~7번은 같은 창의 T3 직후에 둔다. 이 순서가 route·SG 쓰기 권한을 재환에게 넘기거나 상시 유지·DB 창을 새로 승인하는 것은 아니다.
- 시험 Namespace: `fds-app`에서 **앱 NetworkPolicy·workload를 넣기 전에** B→A를 한다([#7 6206079534](https://github.com/321Team/infra-rosa/issues/7#issuecomment-6206079534) Q6 1안). 기존 자원을 지워 시험 조건을 만들지 않는다. 이미 자원이 있으면 precheck·stage-b가 STOP하며, 격리 Namespace 안은 별도 검토다.
- **9번 이후(`pre-rollback` 뒤)로는 미루지 않는다** — 그때는 P1·N1을 `PENDING(#37 창 없음)`으로 둔다.
- db01 출발지 조건: 창 시작 때 `/24` 안 출발지 목록(probe 1 + precheck `worker-ips.tsv`의 worker IP)을 고정하고, 목록 밖 출발지가 db01에 보이면 중단한다([#37 6206092897](https://github.com/321Team/fds-project-baseline/issues/37#issuecomment-6206092897), 최종 확정은 이권욱).

### 작업창 시간
- 시작·종료 시각과 DB 창 연장은 **미배정**이다. 작업창은 이미지 pull·스케줄링·B/A 측정·카운터 수집·실패 진단·cleanup·db01 원복/readback을 모두 포함해 보수적으로 잡는다.
- `POD_MAX_AGE_MIN`(기본 50분)은 시험 Pod 수명(`sleep 3600`)과 A 측정이 섞이지 않게 하는 **보호 장치일 뿐 작업창 상한이 아니다.**
- Pod 안 TCP 시도는 5초 상한, 바깥 `oc` 명령은 `NETPOL_EXEC_TIMEOUT_S`(기본 60초) 상한이다. 바깥 상한 초과는 `EXEC_TIMEOUT`(판정 불가)으로 남고 원격 TCP `TIMEOUT`(정상 차단)과 섞이지 않는다.

## 3. 입력값과 출처

### 승인 입력 (render에서 `approved-inputs.env`로 고정, bundle 해시에 포함)

| 변수 | 값/출처 | 확정 전이면 |
|---|---|---|
| `NS`, `TEAM` | #5 대상 Namespace(`fds-app`), `321team`(#3 수용) | render 안 함 |
| `DB_IP`, `DB_PORT` | IF-18 실행 입력 수용(후보 `10.1.93.55`/`5432`) | render 안 함 |
| `REG_MODE`, `REG_IP`, `REG_PORT` | D22. 미선택 `none`(03의 IF-19 블록 제거), 선택 `include` | render 안 함 |
| `TEST_IMAGE`, `HTTP_IMAGE` | ubi9/ubi-minimal, ubi9/httpd-24 — `@sha256:` 고정. 필수 도구(`bash`·`timeout`·`getent`)·SCC 적합성 확인 | render 안 함 |
| `N3_TARGET` | 승인 밖 On-Prem 대상 `<ip>:<port>`. 후보 `10.1.93.50:443`(edge01)은 Relay SG에서 먼저 막혀 `NO_CLAIM_UPSTREAM`으로 기록됨. 대상 확정은 재환·권욱 | render 안 함 |
| `N2_PORT`, `N4_TARGET` | 기본 `22`, `1.1.1.1:443` | — |
| `WORKER_CIDR` | 기본 `10.20.10.0/24`(private_a) | — |
| `R1_EXPECTED_CODES` | 기본 `200`. httpd-24 기본 응답은 실제 확인 뒤 정하고 **승인 입력으로만** 바꾼다(열린 항목 O2) | — |
| `POD_MAX_AGE_MIN` | 기본 `50` (1~55) | — |

`bundle.txt` = kit SHA + source 7개 SHA + Git HEAD + `manifests/SHA256SUMS` 해시 + `approved-inputs.env` 해시. 이 파일의 해시(`BUNDLE_SHA256`)를 리뷰 승인값 `APPROVED_BUNDLE_SHA256`으로 모든 클러스터 단계에 넣는다. 셋 중 하나라도 바뀌면 쓰기·exec 전에 STOP(rc 21)하고 새 RUN·재리뷰가 필요하다. 진행 기록(`state.env`)은 승인 입력과 분리되어 있으며 probe 대상에 쓰이지 않는다.

### 대상 고정 (precheck에서 `target.env`로 고정)
- `CTX`, `API`, `EXPECTED_CLUSTER_ID`, `EXPECTED_NS_UID`는 **precheck에만** 넣는다(#4 Inventory, #5 NS UID). 이후 단계는 `target.env`를 쓰고, 환경변수가 있으면 같아야 한다(다르면 rc 10).
- `precheck.ok`·`stage-b.ok`에는 bundle 해시와 `target.env` 해시가 들어 있어 이전 단계와 같은 대상·같은 bundle인지 확인한다.

### 실행 시점 기록 (stage-b)
- `STAGE_C_REF`, `T3_REF`, `DB_WINDOW_REF` — #37/#11 재환 님 기록 댓글 URL. 없으면 oc 호출 전 거부(rc 30).

## 4. 실행 (실행 위치: #5 bootstrap/관리자 접속 경로, `oc` 로그인 상태)

render·precheck·stage-b·stage-a는 `RUN_DIR`당 한 번만 실행된다. cleanup은 완료 전까지 같은 RUN에서 다시 시도할 수 있다(`cleanup-attempt-N`).

```bash
# 0) render — 로컬, oc 호출 없음
RUN_DIR=~/netpol-$(TZ=KST-9 date +%Y%m%dT%H%M) NS=fds-app TEAM=321team \
DB_IP=<IF-18> DB_PORT=<IF-18> REG_MODE=none TEST_IMAGE=<…@sha256:…> HTTP_IMAGE=<…@sha256:…> \
N3_TARGET=<승인 밖 ip:port> \
  bash platform/netpol/netpol-run.sh render
# → BUNDLE_SHA256=<64hex>, bundle.txt·approved-inputs.env·manifests/ 를 리뷰 요청

export RUN_DIR=<위 RUN_DIR> APPROVED_BUNDLE_SHA256=<승인값>

# 3) precheck — 읽기 + server dry-run, 클러스터 변경 없음, 대상 고정
CTX=<context> API=https://api.<cluster>:443 EXPECTED_CLUSTER_ID=<uuid> EXPECTED_NS_UID=<uuid> \
  bash platform/netpol/netpol-run.sh precheck

# 6) stage-b — #37 T3 PASS 직후
STAGE_C_REF=<url> T3_REF=<url> DB_WINDOW_REF=<url> bash platform/netpol/netpol-run.sh stage-b

# 7) stage-a — stage-b 직후 이어서
bash platform/netpol/netpol-run.sh stage-a

# 8) cleanup — HOLD(rc 60)면 원인 해소 뒤 같은 명령으로 재시도
bash platform/netpol/netpol-run.sh cleanup
```

`stage-b`·`stage-a`는 시작·끝 시각을 `notice.txt`와 화면에 찍는다. **재환 님께 이 시각을 알려** Relay `to_onprem`·vpn-gw01 `from_vpc` 카운터와 db01 출발지 관측을 같은 구간으로 묶는다(#37 Q2). 각 시도의 UTC 시작·끝은 `results.tsv`에 있다.

## 5. 단계별 판정

| 단계 | 시험 | 기대 | 실패 시 |
|---|---|---|---|
| precheck | C1 Worker IP 전부 `WORKER_CIDR` / C3 OVN / C4 router 라벨 / C5 DNS 5353 / 대상 NS 비어 있음 / 7개 파일 server dry-run | 모두 충족 | rc 20 STOP(변경 없음) |
| stage-b (B) | P1 DB, N1 대조 Pod→DB, N5 Pod 간 진입, P3 DNS, (P2 Registry) | CONNECTED / OK | rc 40 — **정책 시험으로 넘어가지 않음**. 경로·T3 상태 확인 후 cleanup |
| stage-b (B) | N2 승인 밖 포트, N3 승인 밖 IP, N4 인터넷, R1·R2 | 기록만 | — |
| stage-a | 정책 집합 = 이 시험의 5개, 00 spec = `podSelector {}` + Ingress·Egress, 허용 규칙 없음, 정책 원본 YAML 수집 | 일치·수집 성공 | rc 42 / 원본 실패는 rc 11(EVIDENCE_INCOMPLETE) |
| stage-a (A) | P1, (P2), P3 | CONNECTED / OK | rc 50 |
| stage-a (A) | N1·N5 | TIMEOUT(`NP_EFFECT`) | CONNECTED면 rc 50, REFUSED·UNREACHABLE·TOOL_ERROR·EXEC_TIMEOUT이면 rc 51 |
| stage-a (A) | N2·N3·N4 | B CONNECTED였으면 TIMEOUT(`NP_EFFECT`). B부터 막혔으면 기록만(`NO_CLAIM_UPSTREAM`) | A CONNECTED면 rc 50. B CONNECTED였는데 A가 REFUSED 등이면 rc 51 |
| stage-a | R1 `https://<route>/` (실행 위치=클러스터 밖) | **TLS 검증 성공** + `R1_EXPECTED_CODES` | rc 50. `-k` 재시도 없음 |
| stage-a | R2 `Admitted` | 조회 rc 0 + `True` | rc 50 |
| cleanup | OWNED 자원만 UID 대조 삭제, 00~03 UID·spec 유지, 최종 목록 = 남겨야 할 정책뿐 | 일치 | rc 60 HOLD(지우지 않음, 재시도 가능) / 부분 정책이면 rc 61 |

- 정책 효과(`NP_EFFECT`)는 **B CONNECTED → A TIMEOUT**일 때만 주장한다. N1·N5는 B가 열려 있어야 시작하므로 항상 이 조건이다.
- N2·N3은 Relay SG 때문에 **B부터 막힐 수 있다**(F5). 그때 A TIMEOUT은 "승인 밖은 열려 있지 않음" 기록일 뿐 정책 차단 증거가 아니다(`NO_CLAIM_UPSTREAM`). 노드 캡처·OVN ACL 카운터로 정책 효과를 따로 증명하지 않는 대신 **주장하지 않는다**. N4(인터넷)도 같은 규칙이다.
- 결과는 `stage-a/np-effect.tsv`(ID·B·A·주장)와 `handoff.txt`의 `NP_EFFECT=`·`NO_CLAIM_UPSTREAM=` 줄에 남는다.
- 자동 재시도·자동 원복은 없다. 실패하면 그 상태로 멈추고 `RUN_DIR`을 보존해 보고한다.

### 부분 생성·부분 적용 기록 (R2)
- 파일을 적용할 때마다 `journal.tsv`에 의도(INTENT)·결과(APPLIED rc)를 남기고, 그 파일의 기대 객체마다 즉시 기록한다.
  - `OWNED`: `apply -o name` 출력에 있고 UID 확인됨 → cleanup이 UID 대조 후 삭제
  - `UNCONFIRMED`: 존재하지만 apply 출력에 없음, 또는 UID 조회 실패 → **삭제하지 않음**. RUN manifest·실제 UID·작업 주체를 대조하는 복구 절차로 넘김(cleanup HOLD)
- 플랫폼 정책은 하나씩 성공할 때마다 `np-applied.tsv`에 APPLIED로 기록하고 `policy-set.txt`를 `NONE`→`PARTIAL`→`FULL`로 갱신한다. `PARTIAL`이면 cleanup이 시험 자원을 정리해도 rc 61로 끝나며 **앱 배포·Handoff READY 금지**다.
- 이름만으로 자원을 인수하거나 삭제하지 않는다.

종료 코드 전체: `0` 성공, `2` 입력, `10` 대상 불일치, `11` 조회 오류·필수 증적 실패, `20` precheck 불충족, `21` bundle 불일치, `30` 순서·시각(이전 단계 없음·다른 bundle/대상·재실행·Pod 수명), `40` B 기준 불성립, `41` apply·Ready 실패(부분 기록), `42` 정책 집합/00 spec, `50` A FAIL, `51` A 판정 불가, `60` cleanup HOLD, `61` 정리 완료·부분 정책.

## 6. Handoff (→ #4)

`stage-a/handoff.txt`:

| 항목 | 값 | 근거 |
|---|---|---|
| 8. Route 생성 가능 | `ROUTE_READY=YES\|NO` | R1(TLS 검증 + 코드), R2(rc 0 + True) |
| 9. Hybrid route prerequisite | `HYBRID_ROUTE=READY\|BLOCKED` + `STAGE_C_REF`·`T3_REF`·`DB_WINDOW_REF` | C1(`/24`), P1(A), N1(B→A), A 판정 전체 PASS |
| 정책 집합 | `POLICY_SET=FULL` | `policy-set.txt` |
| TLS 서비스 검증 | `TLS_SERVICE_CHECK=NOT_IMPLEMENTED` | TEST-PLAN §4는 이 실행기 범위 밖 — 별도 증적 소비 |

stage-b 전이면 9번은 `PENDING`(실행기 출력 없음)으로 #4에 적는다. R1(A)·P2 TCP 결과를 B/A 전체나 Registry trust·cold-pull 완료로 확대하지 않는다.

## 7. 증적·receipt

`fds-project-evidence` `evidence/P2-ROSA-01/<RUN>/` (증적 PR 독립 리뷰). `RUN_DIR` 구조:

| 경로 | 내용 |
|---|---|
| `bundle.txt`, `approved-inputs.env`, `manifests/` + `SHA256SUMS` | 승인 bundle(kit·source·manifest·입력 해시), 승인 입력, 실제 적용 렌더본 |
| `target.env`, `precheck.ok`, `stage-b.ok` | 고정 대상(API·Cluster ID·NS UID)과 단계 결속 표식(bundle·target 해시) |
| `state.env` | 진행 기록(C1 결과, #37 기록 링크) — 승인 입력 아님 |
| `journal.tsv` | 단계 시작·끝, 적용 의도·결과, POLICY_SET 변경(UTC) |
| `<단계>/commands.tsv`, `*.out/.err/.rc` | 모든 명령의 UTC 시각·rc·argv(비밀값 없음)·원본 출력 |
| `<단계>/context.txt` | `ENV=ROSA`, Cluster ID, NS·UID, whoami, oc client·bash 버전 |
| `precheck/worker-ips.tsv` | 창 시작 출발지 목록(worker 노드 IP) |
| `stage-b/created.tsv` | 시험 자원 이름·UID·OWNED/UNCONFIRMED·원본 파일 |
| `stage-*/results.tsv` | 단계·ID·시작/끝 UTC·Pod·목적지·exec/tcp rc·판정 |
| `stage-a/np-applied.tsv`, `np-objects.tsv`, `np-yaml.out`, `np-effect.tsv` | 정책별 UID·spec SHA-256·상태, 적용 직후 원본, 정책 효과 주장 |
| `policy-set.txt` | `NONE`/`PARTIAL`/`FULL` |
| `cleanup-attempt-N/cleanup.txt`, `hold.txt`, `cleanup.done` | 자원별 DELETED / ALREADY_ABSENT / HOLD, 최종 목록 대조, 완료 표식 |

kubeconfig·토큰·Pull Secret 원문은 남기지 않는다(`whoami` 이름만).

권욱 님 receipt 조건과의 대응:

| 조건 | 이 키트 |
|---|---|
| kit/source SHA + manifest 해시 + 승인 입력 해시 + Cluster ID/API + NS/UID + 단계 결과 | `bundle.txt`, `target.env`, `precheck.ok`/`stage-b.ok`, `results.tsv` |
| 00~03 실제 spec 연결, 00 spec 확인, 기존 NP 합산 확인 | `np-applied.tsv`·`np-yaml.out`, 00 spec 검사, NS 비어 있음, 정책 집합 5개 |
| B단계를 기존 정책 삭제로 만들지 않음 | NS가 비어 있지 않으면 precheck·stage-b STOP |
| `onprem-egress` 라벨 범위 | 시험 Pod `tcp-allowed`만. 앱 workload 라벨 검사는 #43 렌더 계약·#46 사전검사 소관 |
| 앱 NP 2개(#43) receipt | **이 키트 범위 밖** — 앱 배포 뒤 #5/#7 실행자가 별도 |
| 양성·음성·정리 실측 후에만 AC-3 판정 | `results.tsv`(B/A), `np-effect.tsv`, 카운터 기록(재환), `cleanup.txt` |

## 8. 시험 범위와 실행 전 조건

- **MOCK:** `bash platform/netpol/tests/netpol-run-mock.sh` → 86/86 PASS (2026-10-16, Windows Git Bash, 가짜 `oc`·`curl`). 단계 순서·재실행 거부·판정 분기·쓰기 0(precheck)·승인 입력/kit/대상 변조 STOP·부분 생성/부분 정책 기록·UNCONFIRMED 미삭제·cleanup 재시도·TLS 실패·R2 rc·증적 실패·exec 시간 초과를 본다. **실제 클러스터·OVN·router 동작 PASS가 아니다.**
- **실행 전 조건(없는 입력을 합성하지 않음):** 시험 이미지의 필수 도구·SCC 적합성과 승인 digest, N3 실제 대상과 안전성, D22 선택, IF-18 수용, #37 단계 C·T3·db01 창의 유효성, 작업창 시각 배정. 별도 Namespace나 DB 창 연장은 이 키트로 승인되지 않는다.
- **O2:** httpd-24 기본 응답 코드(빈 문서 루트면 200이 아닐 수 있음). 실제 확인 뒤 `R1_EXPECTED_CODES`를 승인 입력으로 정한다.
- **O4:** cleanup의 UID 대조와 삭제 사이에는 짧은 경합 구간이 있다(`oc delete`에 UID 조건 옵션 없음). 이 NS의 다른 writer가 없다는 시작 조건으로 막는다.

AI 사용: CLAUDE_ASSISTED (Claude Code, 이하영 지시로 작성)
