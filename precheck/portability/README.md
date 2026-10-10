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

## 2026-10-10 infra-rosa#6 PG-03 실제 manifest 검사 (`pg03-rosa-check.sh`, 초안)

계획: [#6 댓글 6096647524](https://github.com/321Team/infra-rosa/issues/6#issuecomment-6096647524). 위 W0 스크립트는 일반 Pod 하나로 검사합니다. 이 스크립트는 fds-msa `deploy/base` 실제 manifest(clean checkout, `MSA_SHA` 고정)를 씁니다.

- `MODE=admission`: 조회 전용입니다. 고정 UID 버전(T1)과 portable 버전(T2)을 렌더해 `oc adm policy scc-subject-review`로 어떤 SCC가 받아주는지 기록합니다. Deployment server dry-run은 SCC를 평가하지 않기 때문입니다. 클러스터는 변경하지 않습니다.
- `MODE=runtime`: 클러스터를 변경합니다. `PG03_RUNTIME_GO=yes`가 있어야 실행됩니다. portable 렌더(replicas 1, Route·lab-db 없음)를 apply하고 SCC 주석, UID/GID, imageID, 읽기 전용 루트, `/livez`·`/readyz`를 확인한 뒤 삭제하고 잔여가 없는지 확인합니다. transaction-api는 연결되지 않는 더미 `DATABASE_URL`로 시작만 확인하고, Ready 판정은 #43 lab-db 범위로 넘깁니다. namespace는 지우지 않습니다(#5 소유).
- fds-msa는 수정하지 않습니다. 임시 overlay는 증적 폴더 안에 만듭니다.
- 상태: STATIC(`bash -n`)만 확인했습니다. MOCK·CI·SHARED_OCP·ROSA RUNTIME은 실행하지 않았습니다. PG03=HOLD.
