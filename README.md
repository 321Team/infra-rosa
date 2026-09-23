# infra-rosa

Phase 2 ROSA(Red Hat OpenShift Service on AWS) 플랫폼 구성 저장소. 클러스터 접근·Namespace/Project·RBAC·NetworkPolicy·SecurityContext, OADP/S3 백업·복구, 조건부 Operator 공급망(oc-mirror·CatalogSource)의 manifest와 Runbook을 관리한다.

**상태: 저장소 초기 구성 단계.** manifest·Runbook은 아직 없다. 저장소 생성은 P2-ROSA-01 착수·AC 충족·G5 판정을 뜻하지 않는다.

## 책임 티켓

| 티켓 | 이 저장소 범위 | Lead / Support |
|---|---|---|
| [P2-ROSA-01](https://github.com/321Team/fds-project-baseline/issues/38) | Namespace/Project, RBAC, NetworkPolicy, SecurityContext, Access, Hybrid Route 확인 | 이하영 / 이권욱 |
| [P2-OADP-01](https://github.com/321Team/fds-project-baseline/issues/44) | OADP DataProtectionApplication, Backup/Schedule, Restore Runbook | 이하영 / 이권욱 |
| [P2-OP-01](https://github.com/321Team/fds-project-baseline/issues/51) | D26이 Mirror를 선택한 경우에만 ImageSetConfiguration·CatalogSource. Direct 선택 시 Cancelled | 이하영 / 이권욱, 이재환 |
| [DEC-P2-RHOAI-01](https://github.com/321Team/fds-project-baseline/issues/95) | 도입 결정 시에만 후속 구현 티켓으로 범위 추가. 결정 전 구현 없음 | 이하영 / 이권욱, 이재환 |

Lead·Support는 2026-09-23 Issue 본문 속성표 기준이다. 정확한 Lead·Support·AC는 연결된 Issue와 발행 정본을 따른다.

## 다른 저장소와의 경계

| 저장소 | 범위 |
|---|---|
| [fds-project-baseline](https://github.com/321Team/fds-project-baseline) | 요구사항·AC·Interface·Decision 정본 |
| [infra-terraform](https://github.com/321Team/infra-terraform) | AWS VPC·IAM/OIDC·ROSA 선행 인프라. 클러스터 생성 입력과 Output 제공 |
| [fds-msa](https://github.com/321Team/fds-msa) | 업무 앱 Source·Dockerfile·앱 전용 manifest(P2-APP-01 OpenShift 배포 입력 포함) |
| [infra-cicd](https://github.com/321Team/infra-cicd) | Runner→ROSA Delivery(P2-CICD-01) |
| [infra-harbor-trivy](https://github.com/321Team/infra-harbor-trivy) | Harbor 운영. Mirror 선택 시 저장 대상 |
| [infra-kubernetes](https://github.com/321Team/infra-kubernetes) | Phase 1 On-Prem 클러스터. ROSA 구성과 섞지 않는다 |
| [fds-project-evidence](https://github.com/321Team/fds-project-evidence) | 실행 증적 원본. 경로 `evidence/<Record ID>/` |

## 비밀정보

kubeconfig·로그인 토큰·Pull Secret·S3/Cloud Credential을 커밋하지 않는다. Secret manifest는 값 없이 참조 구조만 두거나 승인된 외부 Secret 관리 방식을 사용한다. Cluster Admin 접근은 최소화하고 사용 기록을 남긴다.

## 변경 절차

리뷰·병합과 Lead 판단은 [리뷰 정책](docs/REVIEW_POLICY.md)을 따른다. manifest·RBAC·NetworkPolicy·OADP 설정은 **코드 변경**이므로 작성자 외 적격 검토자의 독립 리뷰 후 Lead가 병합을 결정한다. 문서만 변경한 PR은 책임 Lead가 판단한다. 사전 검증(Pre-check) 코드는 담당 Lead 권한으로 바로 병합할 수 있으나, ROSA 클러스터에 적용하기 전에는 해당 SHA의 코드 리뷰가 필수다. 클러스터를 바꾸지 않는 순수 검증기 실행은 예외다. main 직접 push·force push·자동 병합을 하지 않는다.

이 문서는 운영 통제이며, GitHub branch protection/ruleset이 활성화됐다는 뜻이 아니다.
