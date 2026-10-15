# RBAC bootstrap kit (infra-rosa#5)

ROSA 생성 직후 첫 설정(IdP → RBAC)을 **임시 cluster-admin을 반드시 회수하면서** 진행하는 키트입니다.
정의·순서: #5 첫 설정 순서 [v2](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6163449444) · [v3](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6163890960).

> 이 키트는 **실행 승인(IdP·grant·RBAC 작업창 GO)이 아닙니다.** 실제 실행은 클러스터 생성, #5 리뷰, 작업창 결정이 끝난 뒤에만 합니다.
> 비용: 키트 자체는 클러스터 내부 설정이라 새 AWS 자원이 생기지 않습니다. 클러스터 가동 비용은 이권욱 판정 대상입니다.

## 파일

| 파일 | 역할 |
|---|---|
| `../manifests/namespaces.yaml` | ⑤ Namespace 3개(`fds-app`, `monitoring-api`, `ci-cd`) + label/annotation |
| `../manifests/rbac.yaml` | ⑦ `ci-cd/fds-deployer` SA, 앱 SA 2개, `fds-app` Role(+`routes/custom-host` create)/RoleBinding |
| `../manifests/human-bindings.yaml` | ⑧ 하영 `admin`, 권욱 `view`, 재환 `view` + `fds-app` `monitoring-edit` |
| `bootstrap-session.sh` | 래퍼. 대상 결속(Cluster ID↔API) → grant → `steps.sh` → **성공·실패·INT·TERM·마감 모두** revoke → 회수 확인 → 최종 rc |
| `steps.sh` | ③~⑩-b 단계. 로그인·결속 → 상태 기록 → manifest 적용 → `--as` 판정·J-1~8 → **배포 SA 실제 token 허용/거부 시험** → 권한 목록 저장·경로 검토 |
| `collect-access-inventory.sh` | ⑩-b 권한 목록 저장(읽기 전용) |
| `post-revoke-check.sh` | ⑫ 회수 뒤 D-11 판정(회수 전 세션 → 새 로그인 → 관리면·SSAR·경로 검토 → 회수 전 세션 정리) |
| `mock-test.sh` / `mock-test-inventory.sh` / `mock-test-post.sh` | 가짜 rosa/oc 로 하는 MOCK 시험. 클라우드 호출 없음, 비용 없음. FAIL 이 하나라도 있으면 rc1 |

## 생성 당일 순서 (요약)

1. **① IdP**: htpasswd IdP `fds-htpasswd`에 `hayeoung`·`gwonuk`·`jaehwan` 3명을 등록합니다(해시는 개인 전달, 파일은 생성 직후 삭제). 이 단계는 래퍼 밖에서 합니다.
   ```bash
   rosa list idps -c fds-rosa-hcp
   rosa create idp -c fds-rosa-hcp --type htpasswd --name fds-htpasswd --from-file ~/rosa-idp/htpasswd
   ```
2. **②~⑪ 래퍼 한 번 실행** — 마감시각을 정하고, 두 번째 관리 세션(회수용)을 미리 열어 둡니다.
   ```bash
   cd platform/rbac/bootstrap
   CLUSTER_ID=<id> API_URL=<api url> DEADLINE_EPOCH=$(date -d '+90 min' +%s) \
     KIT_DIR="$PWD" ./bootstrap-session.sh steps.sh 2>&1 | tee ~/rosa-idp/bootstrap.log
   ```
   - rc=0이면 3으로 갑니다.
   - rc≠0이거나 `CLEANUP_REQUIRED`가 나오면 #5에 즉시 보고합니다. IdP 삭제로 회수를 대신하지 않습니다.
3. **⑫ D-11 판정** — 래퍼 로그의 `EVIDENCE_DIR` 경로를 넘깁니다.
   ```bash
   CLUSTER_ID=<id> API_URL=<api url> ./post-revoke-check.sh ~/rosa-idp/evidence-<시각>
   ```
4. **D-11d** — 권욱·재환이 **각자 본인 로그인**으로 확인해 #5에 결과를 붙입니다.
   ```bash
   oc login <api url> -u <본인 id>
   oc auth can-i get pods -n fds-app            # yes
   oc auth can-i create deployments -n fds-app  # no
   oc auth can-i list nodes                     # no
   oc auth can-i get secrets -n fds-app         # no
   ```
5. 증적을 `fds-project-evidence` `evidence/P2-ROSA-01/`로 PR 편입(독립 리뷰)하고, #4 Handoff 4·5에 제공합니다.

## 생성 후 확인 `[AFTER-CREATE]` — 실제 클러스터가 있어야 알 수 있는 것 (가정하지 않음)

| 항목 | 위치 | 확인 방법 / 다르면 |
|---|---|---|
| `rosa list users` 머리글 | `ROSA_USERS_HEADER_RE` (래퍼·post) | 생성 후 `rosa list users -c <id>` 실제 출력. 다르면 정규식을 고치고 다시 리뷰받기 전에는 실행하지 않음(그 전에는 UNKNOWN → rc1) |
| `rosa revoke user ... -y` 옵션 | 래퍼 cleanup | `rosa revoke user --help` |
| htpasswd IdP 개수 제한·`--from-file` | ① | 기존 htpasswd IdP가 있으면 STOP |
| grant/revoke 반영 지연 | 래퍼 `VERIFY_TRIES`·`VERIFY_INTERVAL` | 기본 60초 × 10회. 넘으면 CLEANUP_REQUIRED |
| `cluster-admins` 그룹·binding 실제 이름, `dedicated-admins` 유무 | `steps.sh` ④·⑩-b 분류 | 다르면 ⑩-b가 UNEXPECTED로 STOP → 정의 갱신·리뷰 |
| self-provisioner 등 플랫폼 기본 binding | ④·⑩-b | `system:authenticated(:oauth)` 대상은 PLATFORM_DEFAULT로 기록만, 수정하지 않음 |
| token `aud` 실제 값 | ⑩ claim | 기록만 함. #46 소비 계약 확정 후 정확 일치로 변경 |
| API 인증서 CA | ⑩ SA kubeconfig | 하영 세션 kubeconfig의 CA를 그대로 씀. TLS 검증 해제 없음 |
| 승인 Route host | `ROUTE_HOST` → A-09 | #4 Handoff 2 이후. 그 전에는 A-09 NOT_RUN 기록 |
| UWM 활성 여부 | ④ | 읽기만. 활성화는 범위 밖 |
| D-10 (만료 token 401) | 별도 | 15분 대기가 필요해 bootstrap 창 밖에서 별도 기록 |

## MOCK 실행 (비용 없음, 클라우드 호출 없음, jq 필요)

```bash
bash platform/rbac/bootstrap/mock-test.sh; echo "rc=$?"
SELFTEST_EXPECT=42 bash platform/rbac/bootstrap/mock-test.sh > /dev/null; echo "selftest rc=$? (1이어야 정상)"
bash platform/rbac/bootstrap/mock-test-inventory.sh; echo "rc=$?"
bash platform/rbac/bootstrap/mock-test-post.sh; echo "rc=$?"
```

## 경계
- 비밀번호·token·kubeconfig·htpasswd 해시를 저장소·이슈·증적에 넣지 않습니다. token은 파일(700)과 bash 내장으로만 다룹니다.
- SIGKILL·세션 통째 유실은 trap 보장 밖입니다 → 두 번째 관리 세션에서 수동 revoke(v2 §3).
- Phase 1·Shared OCP context·인증·방화벽·DNS·Harbor·CA·AC, `openshift-*` 설정은 변경하지 않습니다.
