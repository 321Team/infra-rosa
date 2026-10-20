# P2 Portability W0 Precheck

## 목적

Phase 1의 고정 UID/GID SecurityContext가 OpenShift/ROSA의 기본 SCC 경계와 호환되는지 **실제 리소스를 생성하지 않고** 먼저 확인한다.

연계:
- baseline #34 P2-ARC-01
- baseline #38 P2-ROSA-01
- baseline PR #112
- `P2-PORTABILITY-W0-01`

현재 도구는 PG-03의 **Admission 단계만** 검증한다. 성공해도 PG-03 전체 PASS나 ROSA Runtime PASS로 승격하지 않는다.

## 안전 경계

`uid-scc-admission.sh`는 다음만 수행한다.

- 대상 Namespace read
- OpenShift Server-side dry-run Pod admission
- 로컬 evidence 파일 생성

다음은 수행하지 않는다.

- Namespace 생성/수정
- Pod 실제 생성
- SCC/Role/RoleBinding 수정
- cluster-wide 리소스 변경
- Secret 조회/출력
- 이미지 Pull/실행
- ROSA/AWS 리소스 생성

스크립트의 `oc create` 호출은 모두 **`--dry-run=server`**가 필수다.

## 실행 전 입력

1. Shared OCP 로그인 완료
2. 승인된 Team Namespace
3. 승인 image digest
4. OC_CONTEXT, EXPECTED_API_SERVER(HTTPS endpoint), PORT_ENV=SHARED_OCP_LAB 또는 ROSA

이미지는 mutable tag를 받지 않는다.

예:

```bash
export OC_CONTEXT='APPROVED_CONTEXT'
export EXPECTED_API_SERVER='https://APPROVED_API:6443'
export PORT_ENV='SHARED_OCP_LAB'
export PORT_NS='j1-fds-app'
export APP_IMAGE='registry.example.invalid/fds/transaction-api@sha256:<approved-digest>'
```

실제 Registry hostname/digest는 실행 환경에서 주입하며 Git에 Secret/credential을 기록하지 않는다.

## 실행

검토할 SHA를 고정한 뒤 저장소 루트에서:

```bash
git rev-parse HEAD

PORT_NS="$PORT_NS" \
APP_IMAGE="$APP_IMAGE" \
bash precheck/portability/uid-scc-admission.sh
```

기본 증적 경로:

```text
./evidence-local/p2-portability-w0/capture.<unique>/
```

이 경로의 원본은 로컬 수집물이며 비밀정보 포함 여부를 확인하기 전 Git에 커밋하지 않는다.

## 시험

### T1 — Phase 1 fixed UID/GID

- `runAsUser: 10001`
- `runAsGroup: 999`
- `runAsNonRoot: true`
- `seccompProfile: RuntimeDefault`
- `allowPrivilegeEscalation: false`
- `readOnlyRootFilesystem: true`
- capability drop ALL

결과:
- PASS 또는 REJECTED 모두 유효한 관측 결과다.
- REJECTED를 custom SCC 추가로 즉시 우회하지 않는다.

### T2 — Portable UID

T1에서 UID/GID 고정만 제거하고 나머지 SecurityContext는 유지한다.

성공 기준:
- Server-side admission RC=0

이 결과만으로 image가 arbitrary UID로 **실제 기동**된다고 판정하지 않는다. 실제 Pod Running/Ready, filesystem write 경계, health는 별도 Runtime Window에서 검증한다.

## 종료 코드

| RC | 의미 |
|---:|---|
| 0 | Portable UID admission precheck PASS |
| 2 | 필수 입력 누락 |
| 3 | image digest 미고정 |
| 4 | 필수 CLI 없음 |
| 5 | 로컬 evidence 디렉터리 생성 실패 |
| 10 | Namespace 조회 불가 |
| 20 | Portable UID admission REJECTED |

Fixed UID가 REJECTED여도 Portable UID가 PASS면 스크립트 자체 RC는 0이다. 이때 판정은 **`PG03=PARTIAL_ONLY`**다.

## Evidence

- `context.txt`
- `fixed-uid-pod.yaml`
- `portable-uid-pod.yaml`
- `MANIFEST_SHA256SUMS.txt`
- T1/T2 stdout/stderr
- `result.txt`

필수 추적값:
- 실행 KST
- Source SHA
- Namespace
- Image digest
- T1/T2 RC
- Cluster mutation = NONE
- Runtime = NOT RUN

## 리뷰/실행 상태

이 파일들은 W0 Precheck 후보 실행코드다.

- SOURCE: CANDIDATE
- STATIC: REVIEW REQUIRED
- CI: NOT RUN
- SHARED OCP RUNTIME: NOT RUN
- ROSA RUNTIME: NOT RUN
- PG-03: HOLD

PR 병합 또는 실제 Shared OCP 실행은 각각 별도 단계로 판단한다.

## 2026-10-03 follow-up

`bash precheck/portability/tests/input-contract.sh`는 임시 로컬 Git fixture와 oc mock으로 malformed image/namespace, non-repo/dirty source를 검증한다. 실제 cluster 연결/변경 없음. 실행은 Bash/git/sha256sum 기준이며 10 fault cases (ignored copy 포함)와 dry-run-only 두 요청을 확인한다. 이 결과는 MOCK이며 SCC/Runtime PASS가 아니다.

PG-03 Runtime은 [current private architecture candidate](https://github.com/321Team/fds-project-baseline/pull/137)의 플랫폼·이미지 handoff 계약을 따른다. 실제 approved image/namespace/source에서 restricted-v2 arbitrary UID로 Running/Ready/health/imageID/RO filesystem과 필수 volume 접근/cleanup을 검증한다. 고정 UID 제거 admission PASS만으로 PG03 PASS 처리하지 않는다. Custom/broad SCC 우회 금지. 현 script는 admission-only이며 Runtime Pod 생성은 수행하지 않는다.

## 2026-10-05 증적 보존·대상 고정 보완
기존 architecture PR8은 종료된 역사 출처이며 현행 입력은 private baseline PR137이다.
- OUT_DIR 지정 시 부모 디렉터리는 미리 존재해야 하며 최종 경로가 이미 있으면 RC5로 중단한다. 기본 경로는 mktemp로 배타적으로 생성한다. 기존 결과를 덮어쓰지 않는다.
- 모든 인증 oc 요청은 명시 context/server와 TLS 검증 사용. namespace UID를 시작/종료에 비교하고 identity/UTC/KST/environment를 기록한다. token/kubeconfig 원문은 저장하지 않는다. 같은 endpoint 자체가 다른 cluster로 교체되는 상황까지 방지하는 cryptographic cluster attestation은 아니다.
- SHA256SUMS는 context, 입력, raw stdout/stderr, result 및 기존 입력 해시를 모두 상대경로로 포함한다. SHA256SUMS.sha256는 목록 자체 해시다. 둘을 별도 수신·보관하여 대조하며, 동일 폴더의 해시만으로 서명/변조 방지를 주장하지 않는다.
- 파일 생성/필수 context 조회/해시 실패는 중단한다. 성공 결과는 최종 해시 검증 후 stdout에 출력한다. 중단된 디렉터리는 불완전 수집물로 보존하고 새 경로에서 원인을 해결한 뒤 재수집한다.
- RC11=대상 입력 부적합, RC12=필수 raw 파일 부재, RC13=namespace identity 변경. 기타 필수 명령 오류는 해당 nonzero RC로 종료한다.
- MOCK: 기존 10 input cases 및 dry-run2, 경로 재사용 거부·원본 보존, raw 변조 검출, context/API 입력 거부, 해시 실패 시 성공 출력 없음 확인. 실제 Shared OCP/ROSA 접속·Runtime·PG03 인수는 미수행이다.

## 2026-10-10 infra-rosa#6 PG-03 실제 manifest 검사 (`pg03-rosa-check.sh`, v2 admission 전용)

계획: [#6 댓글 6096647524](https://github.com/321Team/infra-rosa/issues/6#issuecomment-6096647524). 위 W0 스크립트는 일반 Pod 하나로 검사합니다. 이 스크립트는 fds-msa `deploy/base` 실제 manifest(clean checkout, `MSA_SHA` 고정)를 씁니다. v2는 [PR36 리뷰](https://github.com/321Team/infra-rosa/pull/36#pullrequestreview-5478734431)를 반영했습니다.

**하는 일(영구 자원 변경 없음)** — 단, `scc-subject-review`는 review API에 대한 Create(POST) 요청입니다. 영구 workload를 만들지는 않지만 get 권한만으로 된다고 가정하지 않습니다. #5에서 승인된 조회·리뷰 주체로 실행합니다.
1. 첫 API 요청 전에 kubeconfig context의 서버가 `API`와 같은지 확인하고, 이어서 Cluster ID와 Namespace UID를 **승인 inventory 값**(`EXPECTED_CLUSTER_ID`, `EXPECTED_NS_UID`)과 대조합니다. System namespace(`openshift-*`, `kube-*`, `default`)는 입력 단계에서 거부합니다.
2. portable(UID 고정 없음)과 fixed(Phase 1 `runAsUser 10001`/`runAsGroup 999`) 두 벌을 렌더합니다. 라벨을 덧붙이지 않습니다.
3. 렌더 결과에서 **Deployment 2개만** 골라 냅니다. SA·Service·NetworkPolicy는 Pod template이 없어 리뷰에 넘기지 않습니다(oc가 오류를 냄).
4. 앱 SA(`fds-engine-sa`, `transaction-api-sa`)의 존재를 기록합니다. NotFound만 부재로 인정하고, 403 등 다른 오류는 중단합니다.
5. 각 Deployment를 **앱 SA 단독 주체**(`-z <sa>`)로 `oc adm policy scc-subject-review -o json` 평가합니다. `-z`가 없으면 self-subject 평가가 되어 실행자 권한이 섞입니다.
6. 4건 결과를 구조적으로 판정합니다.

| 종료 코드 | 의미 |
|---:|---|
| 0 | portable 2건 모두 `restricted-v2`, fixed 2건 모두 거부 |
| 2 | 입력 오류(oc 호출 전). `MODE=runtime` 포함 |
| 10 | 대상 불일치(서버·Cluster ID·NS UID) 또는 조회 불가 |
| 11 | 수집 오류: 렌더·변환·리뷰 rc≠0, 결과 누락·부분 출력, Deployment 2건 아님, SA 조회 오류, **응답 형식 이상**(아래) |
| 20 | portable이 `restricted-v2`가 아님(거부 또는 더 넓은 SCC — SA 권한 점검 필요) |
| 21 | fixed가 허용됨(`restricted-v2` 또는 더 넓은 SCC). "거부 성공"으로 표시하지 않음 |

- 응답 형식 검사(리뷰 B4): 리뷰 결과마다 `apiVersion: security.openshift.io/v1`, `kind: PodSecurityPolicySubjectReview`, 객체인 `status`가 있어야 합니다. `allowedBy`가 있으면 비어 있지 않은 `name`이 있는 객체여야 하고, `reason`은 문자열이어야 합니다. `template`은 API상 optional(`omitempty`)이지만, 있으면 객체여야 합니다. `allowedBy`가 없을 때는 거부 근거, 즉 비어 있지 않은 `reason` 또는 객체인 `template`이 있어야 거부로 읽습니다. 빈 `status`, `template`이 null·배열·문자열인 경우, 빈 `reason`만 있는 경우는 모두 RC11입니다.
  - 아직 실측하지 않은 가정: 실제 `oc` 출력에 `apiVersion`/`kind`가 실리고, 거부 응답에 거부 근거(`reason` 또는 `template`)가 실린다고 봅니다. 특정 oc 버전의 출력 형식을 모든 버전의 보장으로 보지 않습니다. 지원 oc exact 버전과 실제 응답 원문은 첫 승인 admission 회차에서 fixture로 연결합니다. **첫 실행에서 이 가정 때문에 RC11이 나오면 원본 `.out`을 보존하고, 그 원문을 근거로 검사 기준을 고친 뒤 재리뷰를 받습니다. 현장에서 기준을 느슨하게 바꾸지 않습니다.**
- 증적 분류: Cluster ID·NS UID·서버 대조는 **필수**입니다. 실패하면 RC10으로 중단합니다. `whoami`·`oc version`·namespace UID 범위 annotation 조회는 **보조 증적**이라 실패해도 진행하지만, rc와 오류는 `commands.tsv`와 `.err`에 남기고 결과 보고에 함께 적습니다.
- 증적: `context.txt`(수집기 SHA-256·Git HEAD, Cluster ID, NS UID, whoami), `commands.tsv`(명령별 시작·종료 UTC·rc), 명령별 `.out/.err/.rc`, `admission-result.{txt,json}`, `SHA256SUMS`. SHA256SUMS 생성은 시험 PASS가 아닙니다.
- 실행 권한: Cluster ID 조회(`clusterversion` get)와 namespace·SA 조회, `scc-subject-review`가 필요합니다. 이 권한이 named user의 namespace admin에 없으면 #5에서 정한 승인된 조회 주체로 실행합니다. 배포 SA(`ci-cd/fds-deployer`)에 권한을 더하지 않습니다.
- 결과의 의미: admission **참고 근거**입니다. 실제 SCC annotation·UID·기동 확인을 대체하지 않으며, 이 도구의 rc0이 PG03 PASS는 아닙니다.
- **Runtime(실제 Pod 기동) 시험은 이 PR에서 뺐습니다.** 기존 자원 보존(동명 자원 존재 시 첫 변경 전 STOP), 실행별 이름·UID 장부, 장부 기준 정리·잔여 판정, 별도 시험 실행자 범위를 설계한 뒤 별도 PR로 리뷰받습니다.
- MOCK 시험: `bash precheck/portability/tests/pg03-mock.sh`(가짜 oc, 45건). Linux(bash·python3·git·GNU coreutils)에서 실행합니다. Windows Python은 줄바꿈·경로 처리가 달라 결과로 쓰지 않습니다.
  - 기존 22건: 입력 거부 7건(oc 호출 0), 서버 불일치(API 요청 0), Cluster ID 불일치·403, NS UID 불일치, 리뷰 rc7(지원 안 되는 객체), 부분 출력, Deployment 누락, SA 403, portable 거부·넓은 SCC, fixed의 restricted-v2·넓은 SCC 허용, 정상, SA NotFound 기록, 기존 OUT_DIR 보존
  - 응답 형식 15건(리뷰 B4): 깨진 응답 14건이 RC11인지 확인합니다. 빈 문서, 다른 kind·apiVersion, status null·빈 객체·문자열, allowedBy 문자열·빈 name, reason 타입 오류·빈 reason, template null·배열·문자열이 여기에 들어갑니다. 나머지 1건은 template만 있는 정상 거부가 RC0인지 확인합니다
  - 마지막 namespace 확인 3건(PR39 R3와 같은 보완): 판정이 정상이어도 종료 시 namespace 조회가 다른 UID·빈 출력 실패·UID 출력 후 실패이면 RC10이고 SHA256SUMS로 마감하지 않는지 확인합니다
  - oc `-o json` 출력 형식 5건(2026-10-20 ROSA 실행 RC11 원인 보완): 실제 `oc` 4.22.17은 렌더 객체를 List가 아니라 **JSON 객체를 이어 붙여** 출력합니다. 수집기는 둘 다 읽습니다. 예전 List 형식 정상, **실측 원본 그대로**(`tests/fixtures/oc-4.22.17-json-*.out`) 정상, 잘린 출력·뒤에 쓰레기·빈 출력은 11
  - 모든 경우 쓰기 명령 0건을 확인합니다.
- 상태: oc JSON 이어 붙임 형식 보완 HEAD의 MOCK 45건은 **NOT RUN**(Linux 실행 후 기록). 이전 기록: `b7a9186` MOCK 40건 PASS, `5585754` 37건 PASS([evidence #204](https://github.com/321Team/fds-project-evidence/pull/204)). ROSA 실제 실행 1회: 2026-10-20 RC11 STOP(수집기 JSON 파싱, review POST 0) — [#6 결과 6280562644](https://github.com/321Team/infra-rosa/issues/6#issuecomment-6280562644). PG03=HOLD.

## 생성 직후 실행 안내

ROSA 생성 뒤 CloudShell에서 이 수집기를 돌리는 순서(oc 설치·입력값 출처·결과 해석·증적 반출)는 [RUN-ROSA-ADMISSION.md](RUN-ROSA-ADMISSION.md)에 있습니다.

## 2026-10-15 infra-rosa#6 PG-03 실제 배포 Pod 관측 (`pg03-rosa-observe.sh`, 6-2 Runtime)

admission 수집기(위 절)가 "허용될지"를 묻는다면, 이 도구는 **#43/#46이 실제로 배포한 Pod가 어떻게 떴는지**를 읽기만 해서 확인합니다. 앱을 따로 띄우지 않으므로 PR36 리뷰 B1/B2의 소유권·정리 문제가 생기지 않습니다.

**하는 일(get만, 클러스터 변경 없음)**
1. admission 수집기와 같은 대상 고정을 씁니다. context 서버·`API` 대조(첫 API 요청 전), Cluster ID·NS UID를 승인 inventory 값과 대조, System namespace 거부. 판정이 끝난 뒤 namespace UID를 **다시 조회해 rc=0이고 같을 때만** 증적을 마감합니다(아니면 10, `namespace-final.*`에 원본).
2. `transaction-api`·`fds-engine` Deployment, 그 소유 ReplicaSet, Pod를 get합니다. **현재 revision의 ReplicaSet이 소유하고 `pod-template-hash`가 같은 Pod만** 판정합니다. 이전 revision Pod와 종료 중인 Pod(`deletionTimestamp`)는 뺍니다. Deployment가 일시정지(`paused`)이거나 `observedGeneration`이 `generation`보다 작으면 revision이 옛 버전을 가리킬 수 있어 **판정하지 않고 11로 멈춥니다**.
3. 판정
   - Pod 주석 `openshift.io/scc=restricted-v2`
   - SCC가 배정한 UID가 namespace `uid-range` 안에 있고 10001이 아닐 것
   - 보안 설정을 **유효값**(컨테이너 값이 있으면 그것, 없으면 Pod 값)으로 판정하고, Deployment template과 live Pod에 같이 적용합니다(init 컨테이너 포함): `runAsNonRoot` true, seccomp RuntimeDefault, 읽기 전용 루트, 권한 상승 금지, privileged 아님, `drop ALL`. template에는 UID/GID 고정이 없어야 합니다(live Pod의 runAsUser는 SCC 배정값이라 UID 판정에서 따로 봅니다)
   - **승인 입력은 앱마다 컨테이너 1개**(`TX_IMAGE`/`ENG_IMAGE`)입니다. template·live Pod에 그 밖의 container·init·ephemeral 컨테이너가 있으면 UID·이미지·digest를 결속할 승인 입력이 없으므로 **판정하지 않고 11로 멈춥니다**(sidecar 일반 지원은 승인 목록 입력 계약을 따로 만든 뒤). 앱 컨테이너와 그 status는 이름으로 정확히 1개씩 찾습니다
   - 이미지 참조와 `imageID` digest가 승인값과 같을 것
   - rollout 완료(전체 `status.replicas`·updated·ready·available = replicas — 옛 ReplicaSet Pod가 남아 있으면 미완료, unavailable 없음, 종료 중 Pod 없음)와 Ready(Pod `Ready` 조건 True — readiness gate 포함 — 이면서 앱 컨테이너 ready, phase Running)

| 종료 코드 | 의미 |
|---:|---|
| 0 | 위 판정을 모두 만족 |
| 2 / 10 | 입력 오류 / 대상 불일치 (admission 수집기와 같음) |
| 11 | 수집·파싱 오류 또는 판정 불가: 조회 rc≠0, 형식 이상, Deployment·현재 ReplicaSet 누락, `pod-template-hash` 불일치, 앱 컨테이너 없음·중복, **승인 입력 밖 컨테이너(추가 container·init·ephemeral)**, 앱 status가 정확히 1개가 아님, uid-range 주석 이상, Deployment 일시정지·`observedGeneration` 지연 |
| 31 | SCC가 `restricted-v2`가 아님, 또는 UID가 10001·범위 밖·미배정 |
| 32 | SecurityContext가 portable 계약과 다름 |
| 33 | 이미지 참조 또는 digest가 다름. 멀티아키텍처 index digest와 실행 child digest 차이일 수 있어 **사람이 확인**하고, PASS로 쓰지 않습니다 |
| 30 | rollout 미완료 또는 Ready 아님. transaction-api Ready에는 DB 경로가 필요합니다(#43/#47) |

여러 문제가 겹치면 11 > 31 > 32 > 33 > 30 순서로 종료 코드를 고르고, 행별 결과는 `observe-result.{txt,json}`에 모두 남깁니다.

**11을 읽는 법(아직 뜨는 중인 Pod):** 앱 container status가 정확히 1개가 아니면 11로 멈춥니다. 그래서 스케줄 전·이미지 받는 중처럼 status가 아직 없는 Pod도 11로 나옵니다(30보다 보수적인 쪽). 11이 나오면 `observe-result.txt`의 `ERROR` 줄과 `pods.out`에서 해당 Pod의 `status.containerStatuses`가 비어 있는지 먼저 봅니다. 비어 있고 phase가 `Pending`이면 "수집 오류"가 아니라 "아직 기동 중"일 수 있으니, 결과를 보존한 채 잠시 뒤 **새 OUT_DIR로** 다시 관측합니다. 같은 Pod가 계속 그 상태이면 기동 실패로 보고 원인(이벤트·이미지 pull)을 따로 확인합니다. 판정 기준은 바꾸지 않습니다.

- **하지 않는 것:** exec·port-forward·debug를 포함한 모든 쓰기와 Pod 안 명령. 그래서 "읽기 전용 루트에서 실제 쓰기가 errno 30으로 막히는지"는 확인하지 않습니다(`WRITE_TEST=NOT_RUN`). 필요하면 exec 범위를 정해 별도로 승인받습니다.
- **실행 시점:** #46 배포 이후, 배포 receipt의 이미지 값(`TX_IMAGE`/`ENG_IMAGE`)으로 실행합니다. 실행 권한은 `fds-app` 읽기와 `get clusterversion`입니다(admission과 같은 현장 확인 항목).
- **MOCK 시험:** `bash precheck/portability/tests/pg03-observe-mock.sh`(Linux). 입력 거부 9, 대상 불일치 7(마지막 namespace 확인의 다른 UID·빈 출력 실패·UID 출력 후 실패 포함), 수집 오류·판정 불가 16(Deployment NotFound, Pod 403, 현재 RS 중복, uid-range 이상, 잘못된 kind, 잘린 JSON, observedGeneration 지연, paused, pod-template-hash 불일치, 앱 컨테이너 없음, sidecar 공존, template만 추가 컨테이너, 미승인 live sidecar(UID 10001·`:latest`), live init 컨테이너, 앱 status 누락, status 2개), 판정 분기 17(31×4, 32×6, 33×2, 30×5 — Pod Ready 조건 False·종료 중 Pod·옛 replica 잔존 포함), 정상 1(이전 ReplicaSet Pod 제외), 기존 OUT_DIR 보존 1. 총 51건. 모든 경우 쓰기 명령 0건, 고정되지 않은 oc 호출 0건을 확인합니다.
- 상태: PR39 R3(마지막 namespace 확인 RC) 반영 후 MOCK 51건 PASS — `3ff835b`, 2026-10-16 KST, 개인 AWS CloudShell(`env -i` 격리, 같은 회차 admission 수정본 MOCK 40·input-contract도 PASS), 묶음 `pg03-r3-3ff835b-b7a9186.tgz` SHA-256 `04f2c499947cfb35c0a3b2186765cd1892ce7954965ee98b47d7288802ee4158`(CloudShell 보관). 이전 기록: R1·R2 반영 후 MOCK 48건 PASS — `38e6d81`, 2026-10-16 KST, 개인 AWS CloudShell(`env -i` 격리, 기존 admission MOCK 37·input-contract도 같은 회차 PASS), 묶음 `pg03-observe-mock-38e6d81.tgz` SHA-256 `40a2bb35e8dcd06020cbac968721ece382fdbddc683abb634b6c938f401606cf`(CloudShell 보관). 이전 기록: `cd387da` MOCK 42건 PASS(묶음 SHA-256 `3de9132a0ab45429833dc4c854e5e18f2fb7276ed1ef855dfd0eddde4427192d`), `24dcf78` MOCK 32건 PASS(`9b717628…`). 실제 oc·ROSA RUNTIME은 NOT RUN. PG03=HOLD.
