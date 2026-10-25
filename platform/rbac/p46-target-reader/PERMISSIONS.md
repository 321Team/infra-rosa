# #46 최종 CI/CD 권한 일괄 확인표

현재 채택된 source69e28c49·두 앱/6객체 배포 경로 기준이다. 이 표는 실효 권한 PASS 보고가 아니다.

| 구간 / 주체 | 필요한 권한·접근 | 확인 근거 / 이번 요청 |
|---|---|---|
| GitHub workflow GITHUB_TOKEN | 현재 저장소 Contents read | p2-rosa-delivery.yml 기존 선언. write/다른 저장소 접근 추가 없음 |
| GitHub 원본 읽기 자격 | baseline·infra-cicd·evidence의 Metadata/Contents/Issues/Actions read | 검토된 fine-grained 자격 경로 유지. 입력 shape/전달 성공이 실제 원본 GET 권한 PASS는 아님 |
| 발급자 gwonuk | ci-cd의 fds-deployer에 create serviceaccounts/token | 기존 gwonuk-p2-admin-temp 범위. 10/25 실제 발급·전달 도달. SA 자신에게 재발급 권한을 주지 않음 |
| 배포 SA — 대상 신원 | get clusterversions/version, get namespaces/fds-app | 이번 ClusterRole/Binding2개로 추가할 정확한 읽기2건 |
| 배포 SA — 본인/실효 조회 | create selfsubjectreviews, create selfsubjectaccessreviews | 기본 binding에 의존하는 항목. live 확인을 이번16건에 포함. SubjectAccessReview를 SA에 주는 것은 아님 |
| 배포 SA — 적용 | fds-app의 Service2·Deployment2·Route2 각각 get/patch | 기존 fds-deployer Role에 있음. 새get2개가 이 쓰기를 대체하지 않음. 이번16건에 포함 |
| 배포 SA — 생성/custom host | 기존 Role의 create/update 및 routes/custom-host create | 기존 manifest에 정의. 현재 #46은 기존6객체 SSA PATCH 경로이며 누락/교체 객체는 baseline guard STOP. 새 앱9객체/새 host/범위 확대 승인 아님 |
| 배포 SA — rollout/finish | 같은 Deployment GET·6객체 GET | 이미 위get 범위. finish를 위해 RBAC·Secret·exec·delete 추가하지 않음 |
| 최종 앱0 전환 / 운영자 | 기존 Deployment parent patch, 기존 소유권 보존 | 기존 namespace admin/배포 SA patch 범위. deployments/scale 별도 권한이나 임의 manager 소유권 변경 추가 불필요 |
| 이미지 pull / 앱 SA·kubelet | 기존 pull 전용 Robot·pull Secret 참조 | #12/PR52 기존 인계 영역. 배포 SA가 Secret 값을 직접 읽도록 권한을 추가하지 않음 |
| DB 연결 / 앱 | 기존 DB Secret 참조 및 승인된 네트워크/DB 예외 | OCP 배포 SA 권한과 구분. DB 사용자·pg_hba·route·SG 변경 요청 아님 |
| SSH·READY·원본/finish helper | 기존 ansible→Runner SSH, UID1000 자기 P2 경로 | 실제READY/전달 성공. sudo/root/새SSH키/호스트 전역쓰기 추가 없음 |
| Build·Scan·Harbor push | 기존 Runner/Harbor push 경로 | 이전 Build/Scan/Push 원본을 소비하는 이번deploy job은 새Build/Push를 실행하지 않음. 새push 자격을 발급하는 요청 아님 |

## 한 번에 확인할 16건

하영님 기존 관리 세션에서 적용 전·후 `p46-effective-permissions.yaml`을 조회한다. get/patch12건은 현재 source의 `delivery_platform_readback.capabilities()`에서 추출했고, 신원get2건과 self review create2건을 더했다. SA 토큰이나 자격을 새로 발급하지 않고 관리자가 SubjectAccessReview16개를 생성하는 비영속 권한 조회다.

```sh
oc create -f p46-effective-permissions.yaml -o yaml
```

16개 각각의 spec 대상과 `status.allowed=true`, denied 미설정/false, evaluationError 미설정/빈값을 대조한다. 명령 RC0만으로16개허용이라고 판단하지 않는다. 조회 자체가 Forbidden이면 실효 권한은 미확인이다. 이것을 해결하려고 SA에 SubjectAccessReview 관리자 권한을 주지 않는다.

추가할 것은 기본적으로 식별get2건뿐이다. 기존14건 중 거부가 있으면 전 항목을 한 회신에 묶어 기존 Role/RoleBinding·기본 self-review binding의 정의/실물을 함께 대조한다. 관련 부족 항목의 수정은 같은 PR/이슈에 취합하며, scope 밖 권한을 먼저 넣거나 권욱에게 항목마다 GO를 재요청하지 않는다. 기존 권한을 모두 새 역할로 복제하지 않는다. 권한16건이 모두허용이어도 원본/control·producer·drift·TLS 같은 다른 preflight 실패 가능성이 남는다.

## 변경·적용 상태

STATIC은 로컬 YAML 파싱·종류/이름/추가2규칙/SA1개·코드에서추출한12개와총16개대조까지다. MOCK·서버dry-run·liveSAR·실제권한반영은 아직 미실행, CI0건은 NOT RUN이다. 파일은 기존 bootstrap에서 자동 소비하지 않는 분리 경로다. 작성자 외 정확한HEAD 리뷰와 Lead 판단 후 같은 SHA를 적용한다.

이번 추가는 배포 SA에 cluster-admin·Secret/exec·RBAC쓰기·삭제·TokenRequest 권한을 주지 않는다. 회수 시각·순서와 기존관리자 인증 조건은 README를 따른다. 날짜가 고정된 #46 실제 실행 코드/GO를 다음날 자동 재사용하지 않는다.


## 2026-10-26 실제 일괄 조회 결과

00:13:39~00:13:53 KST, 본인 `gwonuk`·정확한 Cluster/Namespace/SA UID에서 관리자 `oc auth can-i '*' '*'`는 **yes/RC0**였다. 같은 세션에서 SA 대상 SubjectAccessReview16건은 **14 ALLOW / 2 DENY**, evaluationError0이었다. DENY는 위 두 식별get뿐이며 get/patch12·본인 review create2는 허용이었다. 사람 계정 임시상향이 배포 SA에 자동승계되지 않음을 실제로 확인했다. SA 토큰발급/실제RBAC/앱쓰기0이며 두 Deployment replicas0·Pod0도 읽기 확인했다. 본인 OAuth logout RC0→후속whoami RC1·memfd닫기완료이다.

원본은 고정 비공개 검토폴더 인계 대상 `OC_ADMIN_READONLY_RESULT.json`이다. 이 실측은 현재 일괄16개 권한조회이며 과거 A1의 정확한 실패 role/HTTP 원인이나 향후 전체 preflight 성공을 단정하는 근거는 아니다. 이번 2get 추가 실제 적용은 아직 NOT_RUN이다.
