# RBAC bootstrap kit (infra-rosa#5)

ROSA 생성 후 첫 설정(IdP → RBAC)에서 **임시 cluster-admin을 반드시 회수**하기 위한 래퍼와 권한 목록 저장 도구입니다.
정의·순서: [#5 첫 설정 순서 v3](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6163890960) (v2 [6163449444](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6163449444) 기준 delta).

| 파일 | 역할 |
|---|---|
| `bootstrap-session.sh` | `rosa grant user cluster-admin` → `steps.sh`의 `run_steps` → **성공·실패·INT·TERM·마감 모두** revoke → 회수 확인 → 최종 rc (회수 실패 rc=1, `CLEANUP_REQUIRED`) |
| `steps-template.sh` | 순서 ③~⑩-b 단계 템플릿. 실행본은 manifest 경로·token 전달 방식을 채운 뒤 별도 리뷰 |
| `collect-access-inventory.sh` | ⑩-b 권한 목록 저장(읽기 전용, bootstrap 창 안에서만) |
| `mock-test.sh` | 래퍼 MOCK 17경우(가짜 rosa/oc, 클라우드 호출 없음). 조회 실패·형식 불명·401 을 회수 성공으로 보지 않는지 포함 |
| `mock-test-inventory.sh` | 권한 목록 저장 MOCK(가짜 oc, jq 필요). Role 규칙 namespace별 저장, 참조 부재·미지원 kind STOP 포함 |

## MOCK 실행 (비용 없음, 클라우드 호출 없음)

```bash
bash platform/rbac/bootstrap/mock-test.sh
bash platform/rbac/bootstrap/mock-test-inventory.sh
```

## 경계
- 이 키트는 **실행 승인(IdP·grant·RBAC GO)이 아닙니다.** 실제 실행은 #5 리뷰와 작업창 결정 후에만 합니다.
- 비밀번호·token·kubeconfig·htpasswd 해시를 저장소·이슈·증적에 넣지 않습니다.
- SIGKILL·세션 통째 유실은 trap 보장 밖입니다 → 두 번째 관리 세션에서 수동 revoke(v2 §3).

## 실행본 확정 전 남은 것
- `ROSA_USERS_HEADER_RE`: 실제 `rosa list users` 출력(ROSA CLI 1.2.53) 머리글로 확정. 확정 전에는 실행본 아님.
- `rosa revoke user ... -y` 옵션 실제 확인.
- `steps-template.sh`의 manifest 경로·⑩ A/D 시험 token 전달(전용 KUBECONFIG)·`aud` 기대값(#46).
