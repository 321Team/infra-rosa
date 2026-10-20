# 승인 host 시험 Route 실행 키트 (baseline#38 8행 "Route 생성 가능 상태")

- 계획: [baseline#38 6285881794](https://github.com/321Team/fds-project-baseline/issues/38#issuecomment-6285881794)
- 권욱 검토 보완: [6286641386](https://github.com/321Team/fds-project-baseline/issues/38#issuecomment-6286641386)
- 승인 host: [infra-rosa#4 Handoff 2 6285488818](https://github.com/321Team/infra-rosa/issues/4#issuecomment-6285488818)(권욱 수용 6285752690)

**이 키트는 실행 승인이 아닙니다.** `run`은 별도 실행 GO(`GO_REF`)가 있어야 시작합니다.

## 1. 무엇을 확인하나
A-09(서버 dry-run 인가 검사)가 증명하지 못하는 범위를, 승인 host로 Route를 실제로 만들어 확인합니다.

| ID | 확인 | 기대 | 판정 근거 파일(`run/`) |
|---|---|---|---|
| R-1 | Route `Admitted`, host | `Admitted=True`, `spec.host`·`status.ingress[0].host` = 승인 host. routerName·canonical hostname·reason 기록 | `r1-*.out` |
| R-2 | DNS | 승인 host와 router canonical hostname이 **같은 IPv4 집합**으로 해석(runner에서 `getent ahostsv4`) | `r2-host-*`, `r2-canon-*` |
| R-3 | HTTPS(인증서 검증 유지, `-k` 없음) | `ssl_verify_result=0` + **403**(httpd 기본, 문서 루트 비어 있음). 업무 앱 Health·거래 성공이 아님. 인증서 subject/issuer/만료/SAN은 `openssl`이 있으면 기록만 | `r3-*`, `r3-cert.out` |
| R-4 | HTTP → HTTPS | **302**, `Location: https://<host>/` 정확 일치(따라가지 않음) | `r4.out`, `r4.hdr` |
| R-5 | 정리 | 이 RUN이 만든 **OWNED** 3개만 UID 대조 후 삭제 → NotFound → `fds-app` 목록이 시작 전과 같음 → 플랫폼 정책 4개 UID·spec 불변 | `cleanup.txt`, `inv-after.sorted`, `np-after.tsv` |

## 2. 고정 입력과 #7 정책 결속
| 항목 | 값 | 근거 |
|---|---|---|
| `NS` | `fds-app` (UID `222bf961-73d9-4743-972f-2d44da216af2`) | infra-rosa#5 인계 6267898472 |
| `ROUTE_HOST` | `fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com` | #4 Handoff 2 |
| `HTTP_IMAGE` | `registry.access.redhat.com/ubi9/httpd-24@sha256:b48d56ee57fa35ea7412f086fec5135e6db0ef50edddc40dfb0c46dc967fbd0d` | #7 승인 입력(권욱 수용 6259671029) |
| `EXPECTED_CLUSTER_ID` | `37eecf03-b7bc-45e1-8089-5a14a47fccd9` | #5 인계 1행 |
| `API` | `https://api.fds-rosa-hcp.khht.p3.openshiftapps.com:443` | #4 Handoff 2 |
| TLS | `edge` + `insecureEdgeTerminationPolicy: Redirect`, `wildcardPolicy: None`, 인증서 필드 없음(기본 apps 인증서) | #43 계약 |
| **#7 02 정책 결속** | Pod label **`route-exposed: "true"`**, 컨테이너 **8080**, Service `port`·`targetPort` **8080** | `platform/netpol/02-allow-ingress-router.yaml`이 router namespace의 TCP 8080만 허용 |

- render는 02 source가 `route-exposed: "true"`·`port: 8080`인지, 렌더 결과에 같은 값과 승인 host가 정확히 1개씩 있는지, 인증서 필드가 없는지 정적으로 확인합니다. 02 source 해시는 bundle에 묶입니다.
- precheck는 실제 `allow-ingress-from-router`가 `route-exposed=true|TCP|8080`인지 다시 봅니다.
- 이 연결이 맞지 않으면 시작하지 않습니다. backend 차단을 Route/TLS 결함으로 오판하거나 기본 정책을 완화하지 않기 위해서입니다.
- 새 DNS·LB·IngressController·인증서·NetworkPolicy 변경, 클러스터 관리자 권한은 쓰지 않습니다. precheck가 `can-i '*' '*' --all-namespaces = no`(본인 일반 계정)를 확인합니다.

## 3. 실행 순서 위치
**#7 B/A와 #7 cleanup이 끝난 뒤, #43 앱 배포 전**에 합니다.
- precheck는 `fds-app` 목록이 정확히 **#7 뒤 정책 4개**(`fds-platform-default-deny`, `allow-egress-dns`, `allow-ingress-from-router`, `allow-egress-onprem-approved`)일 때만 PASS합니다. #7 시험 자원이나 앱 객체가 남아 있으면 시작하지 않습니다.
- 임시 root Route(`route-host-probe`)는 앱 Route(`transaction-api-api` `/api`, `transaction-api-readyz` `/readyz`)를 적용하기 전에 정리합니다. 같은 host라도 path가 다르면 공존할 수 있으므로 항상 충돌한다고 일반화하지 않지만, 순서는 그대로 지킵니다(6286641386).
- `run`은 `SEVEN_DONE_REF`(#7 A·정리 완료 기록 댓글 URL)와 `GO_REF`(실행 GO 기록 댓글 URL)가 없으면 시작하지 않습니다.

## 4. 명령 (CloudShell, 본인 일반 계정 `oc login` 뒤)
아래 명령은 하영 본인 계정 context에서 실행합니다. 토큰·kubeconfig는 기록하지 않습니다. 이 키트 폴더는 PR 병합본의 **정확한 commit**으로 가져옵니다(`git -C <clone> rev-parse HEAD`가 리뷰한 SHA와 같아야 함).

```bash
K=<infra-rosa clone>/platform/route-test; RUN_DIR=$HOME/route-test-$(date -u +%Y%m%dT%H%M%SZ)
# 1) render (로컬만, oc 호출 없음)
RUN_DIR=$RUN_DIR NS=fds-app TEAM=321team ROUTE_HOST=fds-api.apps.rosa.fds-rosa-hcp.khht.p3.openshiftapps.com \
  HTTP_IMAGE=registry.access.redhat.com/ubi9/httpd-24@sha256:b48d56ee57fa35ea7412f086fec5135e6db0ef50edddc40dfb0c46dc967fbd0d \
  bash $K/route-test-run.sh render
# → RENDER_OK BUNDLE_SHA256=<값>  (GO 요청에 이 값을 넣음)

# 2) precheck (읽기 + server dry-run, 변경 없음)
RUN_DIR=$RUN_DIR APPROVED_BUNDLE_SHA256=<BUNDLE_SHA256> CTX=$(oc config current-context) \
  API=https://api.fds-rosa-hcp.khht.p3.openshiftapps.com:443 \
  EXPECTED_CLUSTER_ID=37eecf03-b7bc-45e1-8089-5a14a47fccd9 EXPECTED_NS_UID=222bf961-73d9-4743-972f-2d44da216af2 \
  bash $K/route-test-run.sh precheck

# 3) run (GO 뒤 1회). 생성 → R-1~R-4 → (실패 시 진단) → R-5 정리까지 한 번에
RUN_DIR=$RUN_DIR APPROVED_BUNDLE_SHA256=<BUNDLE_SHA256> GO_REF=<GO 기록 URL> SEVEN_DONE_REF=<#7 정리 완료 URL> \
  bash $K/route-test-run.sh run

# 4) (run이 60 = 정리 HOLD로 끝났을 때만) 원인 확인 뒤 같은 RUN으로 정리 재시도
RUN_DIR=$RUN_DIR APPROVED_BUNDLE_SHA256=<BUNDLE_SHA256> bash $K/route-test-run.sh cleanup
```

- `TEAM=321team`은 `fds-app` namespace 라벨·#7 render 입력과 같은 값입니다.
- `CLUSTER_ID_CHECK`: 본인 일반 계정이 `clusterversion`을 읽을 수 없으면(`Forbidden`) `UNREADABLE_FORBIDDEN`으로 기록하고, CTX 서버 = API 대조와 project UID로 대상을 고정합니다. 이를 위해 새 clusterwide 읽기 권한을 요청하지 않습니다(6286641386). 읽을 수 있으면 반드시 일치해야 합니다.

## 5. 실패·정리 분기
| 상황 | 동작 | 종료 코드 |
|---|---|---|
| 입력·bundle·대상 불일치 | oc 변경 전 중단 | 2 / 21 / 10 |
| precheck 불충족: 관리자 계정, 권한 부족, 예상 밖 객체, 02 정책 불일치, dry-run 실패 | 변경 없이 중단, `stop.txt` | 20 |
| precheck 뒤 목록·정책 변화, REF 없음, 재실행 | 생성 전 중단 | 30 |
| 생성 일부 실패·Ready 실패(pull 포함)·imageID가 승인 digest와 다름 | 진단 원본 보존 → **OWNED만 정리** → 결과 기록 | 41 |
| R-1~R-4 중 FAIL | 진단 원본 보존(`diag-*`) → **OWNED만 정리** → 결과 기록 | 50 |
| 정리 HOLD: UID 불일치(이름만 같은 객체), 소유 미확정(UNCONFIRMED), 조회·삭제 오류, NotFound 미확인, 목록 불일치, 정책 변화 | 그 객체는 **지우지 않고** 담당자 인계, 같은 RUN으로 `cleanup` 재시도. **앱 배포 금지** | 60 |
| 전부 PASS | 정리 완료 | 0 |

- 같은 GO로 `run`을 자동 재시도하지 않습니다. `run`·`precheck`는 RUN당 1회이고, 다시 하려면 새 RUN·새 GO가 필요합니다.
- `cleanup`은 정리 HOLD일 때만 같은 RUN에서 반복할 수 있습니다(`cleanup-attempt-N`).

## 6. 시간 예산 (보수적, 완료 보장 아님)
| 구간 | 상한·예산 | 키트 값 |
|---|---|---|
| 준비: 키트 반입·해시, `oc login`, render | 10분 | — |
| precheck (읽기·dry-run) | 5분 | 호출당 60s |
| 생성 + image pull·Ready | 최대 5분 | `READY_TIMEOUT_S=300` |
| R-1 Admitted | 최대 2분 | `ADMIT_TIMEOUT_S=120` |
| R-2 DNS (wildcard 해석 대기 포함) | 최대 5분 | `DNS_TIMEOUT_S=300` |
| R-3·R-4 HTTPS/HTTP (backend 503 대기 포함) | 최대 3분 | `HTTP_TIMEOUT_S=180` |
| 실패 진단(describe·endpoints·events) | 5분 | — |
| R-5 정리·NotFound·목록/정책 readback | 5분 | 삭제 대기 120s |
| 증적 봉인·반출·공유 재해시 | 15분 | — |
| 보고(#38 8행·#4) | 15분 | — |
| **합계** | **약 70분 → 작업창 90분 권장** | |

- 새 AWS 자원 생성은 없습니다. 기존 worker에 작은 Pod 1개를 몇 분 띄웁니다. 비용 판단은 권욱 님 몫입니다.
- 시간은 실제 #7 결과·OWNED 정리, 창A 정리·보고, 다른 cluster writer와의 비중첩을 확인한 뒤 배치합니다.

## 7. 증적
`RUN_DIR`에는 다음이 남습니다. 공유폴더로 반출한 뒤 공유 사본을 재해시합니다.
- `bundle.txt`, `approved-inputs.env`, `manifests/`, `target.env`, `journal.tsv`
- 단계별 `commands.tsv`(UTC·rc·명령), `*.out/.err/.rc`, `context.txt`(API·Cluster ID 확인 결과·NS UID·본인 계정)
- `run/created.tsv`(OWNED UID), `run/results.tsv`·`run/result.txt`, `run/cleanup.txt`

## 8. 시험 (MOCK)
```bash
bash platform/route-test/tests/route-test-mock.sh
```
실제 oc·클러스터 없이 가짜 `oc`·`curl`·`getent`·`openssl`로 아래를 확인합니다.
- 단계 순서와 무쓰기(render·precheck)
- 02 정책 결속과 정상 경로
- R-1~R-4 각 실패 분기에서의 진단·OWNED 정리
- 이름만 같은 객체(UID 불일치) 보존
- 목록 변화 중단과 정리 재시도
