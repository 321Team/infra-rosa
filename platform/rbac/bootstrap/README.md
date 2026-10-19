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
| `classify-access-paths.sh` | ⑩-b 경로 분류(오프라인 공용 규칙). bootstrap 과 회수 뒤 재판정에서 같은 규칙. 승인 policy 대조, rc 0/3/1 |
| `post-revoke-check.sh` | ⑫ 회수 뒤 D-11 판정(회수 전 세션 → 새 로그인 → 관리면·SSAR·경로 검토 → 회수 전 세션 정리) |
| `mock-test.sh` / `mock-test-inventory.sh` / `mock-test-post.sh` / `mock-test-classify.sh` / `mock-test-receipt.sh` / `mock-test-d11d.sh` / `mock-test-d11d.ps1` | 가짜 rosa/oc 로 하는 MOCK 시험. 클라우드 호출 없음, 비용 없음. FAIL 이 하나라도 있으면 rc1 |

## 생성 당일 순서 (요약)

1. **① IdP**: htpasswd IdP `fds-htpasswd`에 `hayeoung`·`gwonuk`·`jaehwan` 3명을 등록합니다. 이 단계는 래퍼 밖에서 하는 **유일한 쓰기**라 래퍼의 결속 검사를 거치지 않습니다. 그래서 클러스터 이름이 아니라 **Cluster ID**로 지정합니다(PR#43 리뷰 S2).
   - **비밀번호 방식(#5 GO [6251906186](https://github.com/321Team/infra-rosa/issues/5#issuecomment-6251906186) §2와 같음)**
     - IdP 관리자 하영이 3명의 비밀번호(무작위 20자 이상)를 만들고 bcrypt 해시 파일을 일괄 생성합니다.
     - 비밀번호는 각 계정 소유자에게만 개인적으로 전달합니다. GitHub·이슈·공유폴더·증적에는 넣지 않습니다.
     - 시작 기록에는 **전달 경로의 종류만**(대면, 개인 메신저 등) 적습니다.
     - 파일은 `~/rosa-idp`(700)에만 두고 IdP 생성 직후 삭제합니다.
     - 계정 소유자 동의(GO P8)가 있어야 시작합니다. 관리자가 현재 비밀번호를 안다는 위험은 각 계정 소유자가 받아들인 것으로 기록합니다.
   ```bash
   CLUSTER_ID=<id>                                   # 실행 카드의 Cluster ID
   rosa list idps -c "$CLUSTER_ID"                   # htpasswd 가 이미 있으면 STOP
   rosa create idp -c "$CLUSTER_ID" --type htpasswd --name fds-htpasswd --from-file ~/rosa-idp/htpasswd
   rm -f ~/rosa-idp/htpasswd                         # 생성 직후 삭제
   ```
2. **②~⑪ 래퍼 한 번 실행** — 아래 "실행 카드"를 먼저 채우고, 두 번째 관리 세션(회수용)을 미리 열어 둡니다.
   `API_URL`은 손으로 적지 않고 **`rosa describe`가 돌려주는 표기 그대로** 씁니다. 래퍼는 이 값과 정확히 일치하는지 비교하며(포트 `:443`·끝 `/` 차이도 불일치 → STOP), 표기를 정규화하지 않습니다.
   ```bash
   cd platform/rbac/bootstrap
   umask 077; mkdir -p ~/rosa-idp; chmod 700 ~/rosa-idp     # 로그 디렉터리는 파이프 전에 준비
   CLUSTER_ID=<id>
   API_URL=$(rosa describe cluster -c "$CLUSTER_ID" -o json | jq -er '.api.url'); echo "$API_URL"
   CLUSTER_ID="$CLUSTER_ID" API_URL="$API_URL" DEADLINE_EPOCH=$(date -d '+90 min' +%s) \
     KIT_DIR="$PWD" ./bootstrap-session.sh steps.sh 2>&1 | tee ~/rosa-idp/bootstrap.log
   pipeline_status=("${PIPESTATUS[@]}")
   wrapper_rc=${pipeline_status[0]}
   log_rc=${pipeline_status[1]}
   printf 'wrapper_rc=%s log_rc=%s\n' "$wrapper_rc" "$log_rc"
   ```
   - `pipeline_status=…` 줄은 **파이프 바로 다음 줄**이어야 합니다(사이에 다른 명령이 있으면 값이 사라짐). `| tee`만 쓰면 화면의 rc는 tee의 값이라 래퍼 실패가 숨겨집니다(PR#40 리뷰 R4).
   - 회수(revoke)가 시작되면 **Ctrl+C는 무시됩니다**. 회수와 회수 확인(최대 `VERIFY_TRIES×VERIFY_INTERVAL`, 기본 10분)을 끝까지 하기 위해서입니다. 그래도 멈춰야 하면 두 번째 관리 세션에서 수동 revoke합니다(아래 실행 카드).
   - **`log_rc`가 0이 아니면** 로그가 온전히 저장되지 않은 것입니다. 증적이 불완전하므로 STOP하고 #5에 보고합니다.
   - **`wrapper_rc=0` 그리고 `log_rc=0`** → 3으로 갑니다(완료, receipt `STATUS=COMPLETE`).
   - **`wrapper_rc=3` 그리고 `log_rc=0`** → 설정·회수는 끝났고 **플랫폼 기본 binding 승인 목록만 대기 중**입니다(receipt `STATUS=POLICY_PENDING`).
     - ⑩-b 증적의 `10b-path-review.tsv`(PENDING_POLICY 행)와 `10b-inventory/clusterrole-*.json`을 근거로 `../policy/platform-defaults.approved.tsv`를 PR로 제안하고 리뷰를 받습니다.
     - 병합한 뒤 3으로 갑니다. 마스터키를 다시 빌릴 필요는 없습니다.
   - 그 밖의 rc나 `CLEANUP_REQUIRED`가 나오면 #5에 즉시 보고합니다. IdP 삭제로 회수를 대신하지 않습니다.
3. **⑫ D-11 판정** — 래퍼 로그의 `EVIDENCE_DIR` 경로를 넘깁니다.
   - 시작 전에 래퍼 완료 receipt(`99-receipt.env`)와 대상·해시·회수 전 세션 지문을 대조하고, 저장된 ⑩-b 증적을 승인 policy로 오프라인 재판정합니다.
   - 하나라도 다르면 판정 전에 STOP합니다(회수 전 세션 파일은 조사용으로 남김).
   ```bash
   CLUSTER_ID=<id> API_URL=<api url> ./post-revoke-check.sh ~/rosa-idp/evidence-<시각>; echo "rc=$?"
   ```
4. **D-11d** — 권욱·재환이 **각자 본인 로그인**으로 확인해 #5에 결과를 붙입니다.
   - **이번 회차 전용 임시 kubeconfig로 실행하고, 끝나면 실행 전 `KUBECONFIG` 상태로 되돌립니다(PR#43 리뷰 S1·B1, GO P9).**
     - 기본 kubeconfig에 로그인하면 Phase 1 공용 OCP context가 있는 파일에 ROSA context가 추가되고 current-context가 바뀝니다.
     - `KUBECONFIG` 환경변수로 Phase 1 파일을 지정해 쓰고 있었다면, 그 지정도 실행 뒤 그대로 남아 있어야 합니다. 그래서 Bash는 **서브셸 `( … )`** 안에서 실행하고, PowerShell은 **`finally`에서 원래 값을 먼저 복원**합니다.
     - kubeconfig는 고정 경로가 아니라 `mktemp -d`(PowerShell은 임시 폴더 + GUID)로 이번 회차 전용 파일을 만들고, 끝나면 그 파일과 폴더만 지웁니다.
   - `fds-app`·`monitoring-api`는 Phase 1에도 있는 namespace 이름입니다. 로그인 뒤 **`oc whoami` = 본인 ID, `oc whoami --show-server` = 승인 API**를 둘 다 확인하고, 하나라도 다르면 권한 확인을 하지 않고 중단합니다. 두 값은 결과에 포함합니다.
   - `can-i` 6개는 기대값(yes/no)과 rc를 함께 확인하고 출력합니다. 하나라도 다르면 FAIL입니다.

     | 확인 | `jaehwan` | `gwonuk` |
     |---|---|---|
     | `fds-app` Pod 조회 | yes | yes |
     | `fds-app` Deployment 생성 | no | no |
     | 노드 목록 조회 | no | no |
     | `fds-app` Secret 조회 | no | no |
     | `fds-app` ServiceMonitor 생성 (J-1과 같은 질문) | **yes** | no |
     | `fds-app` PrometheusRule 생성 (J-2와 같은 질문) | **yes** | no |

     - 아래 두 줄은 `monitoring-edit`이 **재환 계정에만** 붙었는지 본인 로그인으로 확인하는 항목입니다.
     - 첫 설정 중 J-1·J-2는 관리자가 `--as`로 대신 물어본 결과입니다.
   - 실행 전에 `<승인 API_URL>`(실행 카드 값)과 `<본인 id>`(`gwonuk` 또는 `jaehwan`)를 바꿉니다.
   - 증적 표기: "계정 소유자가 실행, 비밀번호는 IdP 관리자도 앎"(GO §2).

   bash(CloudShell·Linux·Git Bash) — 마지막 줄의 `D-11d rc=0`이 PASS입니다:
<!-- d11d-bash:start -->
   ```bash
   (
     umask 077
     d11_dir=$(mktemp -d) || exit 1
     export KUBECONFIG="$d11_dir/kubeconfig"
     trap 'oc logout >/dev/null 2>&1 || true; rm -f -- "$KUBECONFIG"; rmdir -- "$d11_dir"' EXIT
     API_URL="<승인 API_URL>"
     EXPECTED_USER="<본인 id>"
     oc login "$API_URL" -u "$EXPECTED_USER" || exit 1
     actual_user=$(oc whoami) || exit 1
     actual_server=$(oc whoami --show-server) || exit 1
     printf 'USER=%s\nSERVER=%s\n' "$actual_user" "$actual_server"
     [ "$actual_user" = "$EXPECTED_USER" ] && [ "$actual_server" = "$API_URL" ] || exit 1
     check_can_i() {
       local want=$1 got rc=0; shift
       got=$(oc auth can-i "$@") || rc=$?
       printf 'can-i %s => %s (rc=%s)\n' "$*" "$got" "$rc"
       [[ "$want" == yes && $rc == 0 && "$got" == yes ]] ||
         [[ "$want" == no && $rc == 1 && "$got" == no ]]
     }
     check_can_i yes get pods -n fds-app           || exit 1
     check_can_i no create deployments -n fds-app  || exit 1
     check_can_i no list nodes                    || exit 1
     check_can_i no get secrets -n fds-app         || exit 1
     # monitoring-edit 은 jaehwan 에게만 fds-app 에서 부여(baseline#25). 본인 로그인으로 J-1·J-2 와 같은 질문을 확인
     if [ "$EXPECTED_USER" = jaehwan ]; then mon=yes; else mon=no; fi
     check_can_i "$mon" create servicemonitors.monitoring.coreos.com -n fds-app  || exit 1
     check_can_i "$mon" create prometheusrules.monitoring.coreos.com -n fds-app  || exit 1
   )
   echo "D-11d rc=$?"
   ```
<!-- d11d-bash:end -->
   PowerShell(Windows) — 마지막 줄의 `D-11d RESULT: PASS`가 PASS입니다:
<!-- d11d-ps:start -->
   ```powershell
   $d11HadConfig = Test-Path Env:KUBECONFIG
   $d11PreviousConfig = $env:KUBECONFIG
   $d11Directory = Join-Path ([IO.Path]::GetTempPath()) ("rosa-d11d-" + [guid]::NewGuid().ToString("N"))
   New-Item -ItemType Directory -Path $d11Directory -ErrorAction Stop | Out-Null
   $d11Config = Join-Path $d11Directory "kubeconfig"
   $d11Ok = $false
   try {
     $env:KUBECONFIG = $d11Config
     $API_URL = "<승인 API_URL>"
     $EXPECTED_USER = "<본인 id>"
     oc login $API_URL -u $EXPECTED_USER
     if ($LASTEXITCODE -ne 0) { throw "STOP: 로그인 실패" }
     $actualUser = oc whoami
     if ($LASTEXITCODE -ne 0) { throw "STOP: whoami 실패" }
     $actualServer = oc whoami --show-server
     if ($LASTEXITCODE -ne 0) { throw "STOP: server 조회 실패" }
     "USER=$actualUser"; "SERVER=$actualServer"
     if ($actualUser -ne $EXPECTED_USER -or $actualServer -ne $API_URL) { throw "STOP: 사용자 또는 server 불일치" }
     # monitoring-edit 은 jaehwan 에게만 fds-app 에서 부여(baseline#25). 본인 로그인으로 J-1·J-2 와 같은 질문을 확인
     $mon = if ($EXPECTED_USER -eq 'jaehwan') { 'yes' } else { 'no' }
     foreach ($c in @(@('yes','get','pods','-n','fds-app'), @('no','create','deployments','-n','fds-app'),
                      @('no','list','nodes'), @('no','get','secrets','-n','fds-app'),
                      @($mon,'create','servicemonitors.monitoring.coreos.com','-n','fds-app'),
                      @($mon,'create','prometheusrules.monitoring.coreos.com','-n','fds-app'))) {
       $want = $c[0]; $args2 = $c[1..($c.Count - 1)]
       $got = oc auth can-i @args2; $rc = $LASTEXITCODE
       "can-i $($args2 -join ' ') => $got (rc=$rc)"
       if (-not (($want -eq 'yes' -and $rc -eq 0 -and $got -eq 'yes') -or ($want -eq 'no' -and $rc -eq 1 -and $got -eq 'no'))) {
         throw "STOP: can-i 기대값 불일치($($args2 -join ' '))"
       }
     }
     $d11Ok = $true
   } finally {
     if ($d11HadConfig) { $env:KUBECONFIG = $d11PreviousConfig } else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }
     if (Test-Path -LiteralPath $d11Config) { oc --kubeconfig $d11Config logout | Out-Null; Remove-Item -LiteralPath $d11Config }
     Remove-Item -LiteralPath $d11Directory -ErrorAction SilentlyContinue
     if ($d11Ok) { "D-11d RESULT: PASS" } else { "D-11d RESULT: FAIL" }
   }
   ```
<!-- d11d-ps:end -->
5. 증적을 `fds-project-evidence` `evidence/P2-ROSA-01/`로 PR 편입(독립 리뷰)하고, #4 Handoff 4·5에 제공합니다.
   - **반출 대상(PR#43 리뷰 S3)**: 아래 전부를 묶고, 묶음 안에 `SHA256SUMS`를 넣은 뒤 공유 사본을 재해시합니다.
     - `~/rosa-idp/bootstrap.log` — 래퍼 로그
     - `~/rosa-idp/evidence-<시각>/` 전체 — 특히 `11-revoke-verify/`가 들어 있어야 합니다. 래퍼가 cleanup에서 복사합니다:
       - `verify-users.N.{out,err}`: 관리면 회수 판정 원문. `REVOKE_VERIFIED`의 직접 근거
       - `verify-cani.N.{out,err}`: 회수 전 세션 SSAR 원문
       - `preflight-cluster.json`: grant 전 Cluster ID↔API 결속, `external_id` 근거
       - `SHA256SUMS`
     - `~/rosa-idp/d11-<시각>/` — ⑫ 결과
   - `11-revoke-verify/`가 없거나 `sha256sum -c`가 실패하면 증적이 불완전한 것입니다. 래퍼도 복사에 실패하면 `EVIDENCE_COPY_FAILED`로 rc=1이 되고 receipt를 발행하지 않습니다.
   - `rosa whoami` 출력에 들어 있는 계정 이메일·이름 줄은 evidence 저장소로 옮기기 전에 가립니다.

## 실행 카드 — 작업창 확정 때 채워서 #5에 먼저 올림 (PR#37 이권욱 리뷰)

| 항목 | 값 |
|---|---|
| Cluster ID / `API_URL`(describe 표기 그대로) | |
| 작업창(KST 시작–끝) / `DEADLINE_EPOCH` | |
| 회수 담당 / 두 번째 관리 세션 위치 | 이하영 / (예: CloudShell 두 번째 탭, `rosa whoami` 확인 완료) |
| **명령 대기 상한** | 한 명령이 **5분(제안값 — 작업창 확정 때 조정)** 넘게 응답이 없으면(예: `oc login` 비밀번호 대기, 네트워크 정지) 기다리지 않고 두 번째 세션에서 수동 revoke. 래퍼의 마감 watchdog은 foreground 명령이 끝나야 처리되므로 이 상한을 대신하지 못함 |
| 수동 revoke 인계 | 아래 명령 → `rosa list users -c <id>`로 grant 없음 확인 → #5에 `CLEANUP_REQUIRED` 경위·시각 기록 |
| 수동 revoke가 필요한 경우 | ① 명령 대기 상한 초과 ② 회수 중 Ctrl+C로도 멈추지 않아 강제 종료(kill -9)한 경우 ③ CloudShell 세션 유실 ④ 래퍼가 `CLEANUP_REQUIRED`로 끝남 |

```bash
# 두 번째 관리 세션 — 수동 회수
rosa revoke user cluster-admin --user hayeoung -c <id> -y
rosa list users -c <id>
```

## 생성 후 확인 `[AFTER-CREATE]` — 실제 클러스터가 있어야 알 수 있는 것 (가정하지 않음)

| 항목 | 위치 | 확인 방법 / 다르면 |
|---|---|---|
| `rosa list users` 빈 목록 | `ROSA_USERS_EMPTY_LINE` (래퍼·post) | **A단계 실측(2026-10-18)**: 머리글 없이 stdout 1줄 `INFO: There are no users configured for cluster '<id>'`, rc0, stderr 없음. 정확히 이 1줄(이 회차 ID)일 때만 부재. 다른 ID·추가 줄·stderr·rc≠0 은 UNKNOWN |
| `rosa list users` 머리글(사용자 있을 때) | `ROSA_USERS_HEADER_RE` (래퍼·post) | grant 전에는 볼 수 없음. ③에서 grant 상태 원문을 `03-granted-users.out`에 기록만 함 → 첫 회차 증적으로 정규식 확정·리뷰. 회수 뒤 판정은 빈 목록 규칙을 쓰므로 머리글이 달라도 회수 확인은 막히지 않음(수렴 대기 중 PRESENT 를 못 읽으면 UNKNOWN → 재조회) |
| `rosa describe` 의 `api.url` 실제 표기 | 래퍼 F1 결속·`steps.sh` ③ server 비교 | **A단계 실측**: `https://api.fds-rosa-hcp.khht.p3.openshiftapps.com:443`. `API_URL`은 이 값 그대로. `oc whoami --show-server` 표기와 다르면 ③에서 STOP → 기록 후 재검토 |
| `rosa revoke user ... -y` 옵션 | 래퍼 cleanup | **A단계 실측**: `-y, --yes` 있음. `rosa grant user cluster-admin` 형식도 help 예시와 일치 |
| htpasswd IdP 개수 제한·`--from-file` | ① | **A단계 실측**: 기존 IdP 0개, `--from-file` 있음. 실행 직전 `rosa list idps`를 다시 보고 htpasswd 가 있으면 STOP |
| OpenShift cluster UUID·노드 Ready (#4 Handoff 1·3번) | `steps.sh` ④ `04-handoff-1-3.txt` | 회수 뒤 namespace admin 으로는 `clusterversion`·`nodes` 를 읽을 수 없어 cluster-admin 이 있는 ④에서 읽음. 읽기 실패·값 없음이면 STOP(→ 회수). UUID 는 `rosa describe` `external_id`(A단계 `37eecf03-…`)와 교차 확인 |
| CloudShell `oc` | 실행 전 준비 | **A단계 실측**: 설치 안 됨. 실행 전에 설치하고 `oc version --client` 기록 |
| grant/revoke 반영 지연 | 래퍼 `VERIFY_TRIES`·`VERIFY_INTERVAL` | 기본 60초 × 10회. 넘으면 CLEANUP_REQUIRED |
| `cluster-admins` 그룹·binding 실제 이름, `dedicated-admins` 유무 | `steps.sh` ④·⑩-b 분류 | 다르면 ⑩-b가 UNEXPECTED로 STOP → 정의 갱신·리뷰 |
| self-provisioner 등 플랫폼 기본 binding | ④·⑩-b | `system:authenticated(:oauth)` 대상은 PLATFORM_DEFAULT로 기록만, 수정하지 않음 |
| token `aud` 실제 값 | ⑩ claim | 기록만 함. #46 소비 계약 확정 후 정확 일치로 변경 |
| API 인증서 CA | ⑩ SA kubeconfig | 하영 세션 kubeconfig의 CA를 그대로 씀. TLS 검증 해제 없음 |
| 승인 Route host | `ROUTE_HOST` → A-09 | #4 Handoff 2 이후. 그 전에는 A-09 NOT_RUN 기록 |
| UWM 활성 여부 | ④ | 읽기만. 활성화는 범위 밖 |
| RBAC 거부 메시지 형식 | `steps.sh` `_classify`, `post-revoke-check.sh` `cls` | `User "<주체>" cannot <verb> resource "<res>"` 문장이 실제 ROSA 4.22 응답에 있는지 첫 실행 `req/*.err`로 확인. 다르면 OTHER → STOP(정상 거부로 통과시키지 않음) → 형식 갱신은 리뷰 |
| `system:authenticated(:oauth)` 대상 기본 binding 승인 목록 | `../policy/platform-defaults.approved.tsv` (`classify-access-paths.sh`) | 범위·binding·roleRef·주체 + ClusterRole 규칙 sha256 까지 대조. 첫 실행은 목록이 없어 래퍼 rc=3(정책 대기) → 증적으로 PR 제안·리뷰 → 병합 후 `post-revoke-check.sh`가 오프라인 재판정. 수집값을 자동 승인하지 않음 |
| `rosa list users` 본문 행 형식·그룹 이름 | `ROSA_USERS_ROW_RE` (래퍼·post) | 머리글이 맞아도 본문 한 행이라도 형식이 다르면 UNKNOWN → 회수 확인 실패(rc1). 실제 형식으로 확정 |
| namespace admin 의 `oc get project <ns>` 허용 | `post-revoke-check.sh` TARGET-uid | 허용 안 되면 UID 대조가 UNKNOWN → FAIL. 그때는 대조 방법을 바꿔 리뷰 |
| D-10 (만료 token 401) | 별도 | 15분 대기가 필요해 bootstrap 창 밖에서 별도 기록 |

## MOCK 실행 (비용 없음, 클라우드 호출 없음, jq 필요)

```bash
bash platform/rbac/bootstrap/mock-test.sh; echo "rc=$?"
SELFTEST_EXPECT=42 bash platform/rbac/bootstrap/mock-test.sh > /dev/null; echo "selftest rc=$? (1이어야 정상)"
bash platform/rbac/bootstrap/mock-test-inventory.sh; echo "rc=$?"
bash platform/rbac/bootstrap/mock-test-post.sh; echo "rc=$?"
bash platform/rbac/bootstrap/mock-test-classify.sh; echo "rc=$?"
bash platform/rbac/bootstrap/mock-test-receipt.sh; echo "rc=$?"   # jq 불필요
bash platform/rbac/bootstrap/mock-test-d11d.sh; echo "rc=$?"      # README D-11d Bash 예시 그대로 실행, jq 불필요
# Windows: powershell -NoProfile -ExecutionPolicy Bypass -File platform/rbac/bootstrap/mock-test-d11d.ps1   # README D-11d PowerShell 예시
```

## 경계
- 비밀번호·token·kubeconfig·htpasswd 해시를 저장소·이슈·증적에 넣지 않습니다. token은 파일(700)과 bash 내장으로만 다룹니다.
- SIGKILL·세션 통째 유실은 trap 보장 밖입니다 → 두 번째 관리 세션에서 수동 revoke(v2 §3).
- Phase 1·Shared OCP context·인증·방화벽·DNS·Harbor·CA·AC, `openshift-*` 설정은 변경하지 않습니다.
