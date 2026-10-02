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

이미지는 mutable tag를 받지 않는다.

예:

```bash
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
./evidence-local/p2-portability-w0/<timestamp>/
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
