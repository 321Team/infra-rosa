# infra-rosa#6 PG-03 — ROSA admission 실행 안내 (생성 직후용)

ROSA 클러스터가 생긴 뒤 `pg03-rosa-check.sh`(PR #36)를 **CloudShell에서 바로 돌리기 위한 순서**입니다. 스크립트 자체 설명과 종료 코드는 [README](README.md)의 "2026-10-10 infra-rosa#6" 절을 따릅니다.

> 이 문서는 실행 순서 안내이며 **실행 승인이 아닙니다.** 실제 실행은 아래 시작 조건이 모두 기록된 뒤에 합니다.

## 무엇을 확인하나 (쉬운 말)

ROSA는 앱이 사용자 번호(UID)를 직접 고르지 못하게 하는 기본 보안 규칙 `restricted-v2`를 씁니다. 이 단계는 앱을 띄우지 않고 **"이 앱 설정이면 어떤 보안 규칙이 허용해 주는가"를 클러스터에 물어봅니다**(`scc-subject-review`).

| 비교 | 기대 |
|---|---|
| portable(UID 고정 없음, fds-msa `deploy/base` 그대로) | 두 앱 모두 `restricted-v2`로 허용 |
| fixed(Phase 1 고정값 `runAsUser 10001` / `runAsGroup 999`를 더한 비교본) | 허용하는 규칙 없음(거부) |

- 클러스터에 영구 자원을 만들지 않습니다. 다만 review API에 대한 Create(POST) 요청이라 조회(get) 권한만으로는 안 될 수 있습니다.
- 결과는 admission **참고 근거**입니다. 실제 Pod의 SCC·UID·기동 확인(6-2)과 PG-03 판정은 별도입니다.
- 비용: 이미 있는 클러스터에 조회·리뷰 요청만 보냅니다. 새 AWS 리소스를 만들지 않습니다. 비용 판단은 이권욱 소관입니다.

## 시작 조건

| # | 조건 | 근거·담당 |
|---|---|---|
| S1 | ROSA Cluster/Worker Ready, 클러스터 ID 두 종류 기록: `rosa_cluster_id`(ROSA/OCM `rosa describe cluster`의 id)와 `openshift_cluster_uuid`(`oc get clusterversion version`의 `spec.clusterID`) | infra-rosa#4 Handoff 항목 1 |
| S2 | namespace `fds-app` 생성과 UID 기록, 실행자 본인 IdP 사용자에 `fds-app` admin 부여 | infra-rosa#5 첫 설정 ⑤·⑥ |
| S3 | 앱 SA `transaction-api-sa`·`fds-engine-sa`가 실제로 생성됐고 식별(이름·UID)을 확인함 | fds-msa `deploy/overlays/rosa-prereq`, #5/#7 bootstrap 실행자 |
| S4 | 작업창: 실행 시각·실행자, **이번 회차에 채택한 infra-rosa·fds-msa SHA와 이미지**를 #6에 먼저 기록 | 이하영 → 이권욱 확인 |

하나라도 없으면 실행하지 않습니다. 대신하는 값(Shared OCP 결과, 추정 UID 등)을 쓰지 않습니다.

S3 보충: 정식 ROSA admission 입력은 `transaction-api-sa`와 `fds-engine-sa`의 실제 생성·식별 확인 후 수집합니다. 수집기가 SA 없이도 이름 기준으로 평가하는 기능은 실제 SA/RBAC/SCC 적용 완료를 증명하지 않으며, 이 안내의 시작 조건을 대신하지 않습니다.

## 입력값

| 입력 | 값 | 어디서 |
|---|---|---|
| `API` | `https://api.<cluster>…:443` | #4 Handoff 항목 2 |
| `CTX` | 로그인 뒤 `oc config current-context` 값 | 2단계 |
| `EXPECTED_CLUSTER_ID` | **OpenShift UUID** | #4 Handoff 항목 1의 `openshift_cluster_uuid`(`oc get clusterversion`의 `spec.clusterID`). ROSA/OCM `rosa_cluster_id`와 다른 값이니 섞어 넣지 않습니다 |
| `NS` / `EXPECTED_NS_UID` | `fds-app` / UUID | #5 ⑤ 기록 |
| `PORT_ENV` | `ROSA` | 고정 |
| `INFRA_ROSA_SHA` / `MSA_SHA` | 이번 회차에 **채택한** 40자리 SHA(검토된 버전). 실행 당일 main을 그냥 받아 쓰지 않습니다 | S4에서 #6에 먼저 기록한 값. 1단계에서 받은 코드가 이 SHA인지 대조합니다 |
| `TX_IMAGE` / `ENG_IMAGE` | `<registry>/fds/transaction-api@sha256:<digest>` / `<registry>/fds/fds-engine@sha256:<digest>` | **실행 회차의 #43 채택 digest**(S4에 기록). 2026-10-15 기준 fds-msa `rosa-app` overlay(`c9c42cc`, fds-msa PR37)의 P2 current는 transaction-api `338b8a2871507ce8b42deedc916b26e350577ee6efd18df23d7ff2dd4b17dff0`, fds-engine `8b257adb08b6d381f72b66d3386efea6112a8f072ecfafcbcd463bcd1c3be89d`입니다. `<registry>`는 #42 결정값이고, 결정 전이면 `registry-input-pending.invalid`를 그대로 씁니다. admission은 이미지를 받지 않지만, 실제 배포·관측(PR39)과 같은 이미지로 묻도록 맞춥니다 |

참고: 이전 판에 적었던 `a7093136…`/`5e2a081c…`는 #15 Phase 1 승인 digest입니다. 과거 admission 기준값(historical fixture)으로만 쓸 수 있고, 현재 ROSA 배포 이미지 설명으로 쓰지 않습니다. 이 digest의 P1 rollback 수용을 취소하거나 사용을 금지한다는 뜻은 아닙니다.

## CloudShell 순서

명령은 모두 AWS CloudShell(Amazon Linux 2023, x86_64) 기준입니다.

### 0. `oc` 설치 (처음 한 번)

공식 배포처에서 4.22.17 클라이언트를 받고, 공식 해시로 확인한 뒤 압축을 풉니다. AWS API는 부르지 않습니다.

```bash
mkdir -p ~/pg03-rosa/bin && cd ~/pg03-rosa && curl -sSfLO https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.22.17/openshift-client-linux-amd64-rhel9-4.22.17.tar.gz && echo "87f436029301f4856d3c3df85586bd34aafb807d7870939f1aa4885afdd4834f  openshift-client-linux-amd64-rhel9-4.22.17.tar.gz" | sha256sum -c - && tar xzf openshift-client-linux-amd64-rhel9-4.22.17.tar.gz -C bin oc && ~/pg03-rosa/bin/oc version --client
```

- 해시 값은 [공식 sha256sum.txt](https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.22.17/sha256sum.txt)의 `openshift-client-linux-amd64-rhel9-4.22.17.tar.gz` 줄입니다(2026-10-15 확인).
- CloudShell 창을 새로 열면 `export PATH=~/pg03-rosa/bin:$PATH`를 다시 해야 합니다.
- 클러스터 버전이 4.22.17이 아니면 버전 번호와 해시를 그 버전 것으로 바꿉니다.

### 1. 코드 받기

두 저장소를 받은 뒤 **S4에 기록한 채택 SHA로 고정**하고, 실제로 그 SHA인지 대조합니다. `HEAD_OK`가 나오지 않으면 멈춥니다. 비공개 저장소라 비밀번호 자리에 **두 저장소 읽기(Contents: Read-only) fine-grained 토큰**을 넣습니다. 토큰은 어디에도 붙여 넣지 않고, 끝나면 삭제합니다.

```bash
cd ~/pg03-rosa && INFRA_ROSA_SHA="<채택 infra-rosa SHA>" && MSA_SHA="<채택 fds-msa SHA>" && git clone -q https://github.com/321Team/infra-rosa.git && git clone -q https://github.com/321Team/fds-msa.git && git -C infra-rosa checkout -q --detach "$INFRA_ROSA_SHA" && git -C fds-msa checkout -q --detach "$MSA_SHA" && [ "$(git -C infra-rosa rev-parse HEAD)" = "$INFRA_ROSA_SHA" ] && [ "$(git -C fds-msa rev-parse HEAD)" = "$MSA_SHA" ] && echo HEAD_OK && git -C fds-msa log -1 --format='BASE_LAST=%h %cI' -- deploy/base
```

- `INFRA_ROSA_SHA`·`MSA_SHA`는 3단계에서도 쓰므로 같은 CloudShell 창에서 이어서 실행합니다.
- `BASE_LAST`가 `f618377`이 아니면 채택 SHA에서 `deploy/base`가 바뀐 것입니다. 바뀐 내용이 검토됐는지 확인하고 #6에 기록합니다.

### 2. 로그인

#5에서 만든 **본인 IdP 사용자**로 로그인합니다. 비밀번호는 본인이 직접 입력합니다. 임시 cluster-admin 상태(#5 bootstrap 창)에서는 실행하지 않습니다.

```bash
export PATH=~/pg03-rosa/bin:$PATH && oc login "<API>" -u "<본인 IdP 사용자>" && oc whoami && oc config current-context
```

### 3. 실행

`<…>`를 위 입력값으로 바꿔 실행합니다. `API`는 2단계 `oc login`에 쓴 문자열과 **똑같이** 넣습니다(스크립트가 context의 서버 주소와 글자 그대로 비교). 결과는 `~/pg03-rosa/run-admission-<시각>/`에 남습니다.

```bash
cd ~/pg03-rosa/infra-rosa && export PATH=~/pg03-rosa/bin:$PATH && OUT=~/pg03-rosa/run-admission-$(date -u +%Y%m%dT%H%M%SZ) && CTX="$(oc config current-context)" API="<API>" NS=fds-app PORT_ENV=ROSA EXPECTED_CLUSTER_ID="<openshift_cluster_uuid>" EXPECTED_NS_UID="<fds-app UID>" MSA_DIR=~/pg03-rosa/fds-msa MSA_SHA="$MSA_SHA" TX_IMAGE="<채택 transaction-api 이미지@sha256:…>" ENG_IMAGE="<채택 fds-engine 이미지@sha256:…>" OUT_DIR="$OUT" bash precheck/portability/pg03-rosa-check.sh; echo "RC=$?"; echo "OUT=$OUT"
```

### 4. 결과 보기

| RC | 뜻 | 다음 |
|---:|---|---|
| 0 | portable 2건 `restricted-v2` 허용, fixed 2건 거부 | 5단계로 증적 반출 |
| 2 | 입력 오류(클러스터 호출 전) | 입력값을 고쳐 **새 OUT**으로 다시 실행 |
| 10 | 대상 불일치 또는 조회 불가 | 멈춤. `cluster-id.err`·`ns-uid.err` 확인 → 아래 "권한" |
| 11 | 수집 오류(리뷰 rc≠0, 응답 형식 이상 등) | 멈춤. 원본 보존. 응답 형식 문제면 원문으로 검사 기준을 고친 뒤 재리뷰. **현장에서 기준을 완화하지 않음** |
| 20 | portable이 `restricted-v2`가 아님 | 멈춤. PG-03 HOLD. SA 권한·namespace UID 범위 확인 |
| 21 | fixed가 허용됨 | 멈춤. "거부 성공"으로 쓰지 않음. SA에 넓은 SCC가 묶였는지 확인 |

0이 아닌 결과도 그 자체로 증적입니다. 어떤 경우에도 SCC·권한을 넓혀서 다시 돌리지 않습니다.

### 5. 증적 반출

```bash
cd ~/pg03-rosa && tar czf "$(basename "$OUT").tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")" && sha256sum "$(basename "$OUT").tgz" && cat "$OUT/admission-result.txt"
```

- 화면 출력을 #6에 붙이고, tgz는 CloudShell **Actions → Download file**로 받아 팀 공유 폴더에 둡니다. 증적 편입 위치는 `fds-project-evidence` `evidence/P2-ROSA-01/infra-rosa-issue-6-admission-<날짜>/`(독립 리뷰)입니다.
- kubeconfig·토큰·비밀번호는 tgz에 들어가지 않습니다(스크립트가 수집하지 않음). 반출 전에 `tar tzf`로 목록을 한 번 봅니다.

## 권한 (현장 확인 항목)

- `get clusterversion`(Cluster ID 대조)은 클러스터 범위 읽기입니다. namespace admin만 있는 사용자는 거부될 수 있습니다. 거부되면 RC10으로 멈춥니다.
- `scc-subject-review`는 `security.openshift.io`의 review Create 권한이 필요합니다.
- 어느 쪽이든 막히면 **권한을 임의로 추가하지 않습니다.** #5에서 정한 승인된 조회·리뷰 주체로 실행할지, 어떤 범위로 줄지는 이권욱 판단으로 넘깁니다. 배포 SA(`ci-cd/fds-deployer`)에 권한을 더하지 않습니다.

## 하지 않는 것

- 앱 배포·Pod 생성·Secret 생성·SCC/RBAC 변경
- Phase 1 manifest·서버 변경(fixed 값은 로컬 비교 입력일 뿐)
- Shared OCP 결과를 ROSA PASS로 쓰기
