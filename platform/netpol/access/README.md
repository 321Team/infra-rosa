# #7 창 한정 읽기 권한(reader) — 붙이기·확인·떼기 (DRAFT)

- 작성: 이하영, 2026-10-22 KST. **권한 변경·실행 아님(MOCK만).** 근거: [#7 권한 경로 제안 6286217735](https://github.com/321Team/infra-rosa/issues/7#issuecomment-6286217735) 안 A
- 왜: `netpol-run.sh`(`91a46461…`)는 precheck·결속 확인에 클러스터 범위 읽기 4종이 필요하다. 하영 일반 권한(3개 namespace `admin` + `fds-clusterversion-reader`, #5 PR#47)에는 없다. #5 임시 cluster-admin은 10/19 회수됐다.
- 파일: [`reader.yaml`](reader.yaml) · [`steps-reader.sh`](steps-reader.sh)(래퍼 단계 파일) · [`reader-check.sh`](reader-check.sh)(회수 뒤 확인·반출) · [`tests/reader-mock.sh`](tests/reader-mock.sh)

## 1. 권한 범위

| 규칙 | 동사 | `netpol-run.sh` 사용처 |
|---|---|---|
| `nodes` | get, list | precheck C1(Worker IP), 결속(`get node`) |
| `namespaces` | get, list | precheck C4(`get namespace -l policy-group…ingress`) |
| `pods` | get, list | precheck C5(`-n openshift-dns get pods`), 결속(`get pods -A --field-selector spec.nodeName=`) |
| `config.openshift.io/networks` `cluster` | get | precheck C3(networkType) |

- ClusterRole `fds-netpol-window-reader` + ClusterRoleBinding `fds-netpol-window-reader-hayeoung`(User `hayeoung`). 쓰기·Secret·RBAC·exec 없음. `fds-app` 안 생성·exec·삭제는 기존 `hayeoung-admin`.
- 잔여 위험: 전체 Pod list는 다른 namespace Pod spec(환경변수 등)을 볼 수 있다. 창 시간 안으로만 붙여 줄인다.
- 상시 binding이 아니다. 붙어 있는 동안 #5 정책 표(`platform-defaults.approved.tsv`) 기준 인벤토리를 다시 돌리면 이 경로가 승인 밖으로 잡힌다. 창 끝에 떼어 #5 ⑫ 상태(노드 조회 불가)로 되돌린다.

## 2. 절차 (CloudShell, `rosa`·`oc`·`jq` 준비, 하영 본인)

붙이기·떼기는 #5 래퍼(`platform/rbac/bootstrap/bootstrap-session.sh`: grant → 단계 → **항상 revoke** → 회수 확인)로 각 1회, 짧게 한다. 래퍼 작업 폴더는 #5와 섞지 않게 `WORKDIR=~/rosa-netpol-reader`.

```bash
cd ~/infra-rosa/platform/netpol/access
export CLUSTER_ID=<ROSA cluster ID> API_URL=https://api.fds-rosa-hcp.khht.p3.openshiftapps.com:443 WORKDIR=~/rosa-netpol-reader
# ① 창 시작: 붙이기 (oc login 비밀번호는 프롬프트에 본인 입력)
READER_MODE=on DEADLINE_EPOCH=$(date -d '+20 min' +%s) bash ../../rbac/bootstrap/bootstrap-session.sh steps-reader.sh
# ② 회수 뒤 일반 세션으로 확인 → READER_CHECK_on=PASS, 묶음 ~/rosa-netpol-reader/netpol-reader-on-*.tgz
bash reader-check.sh on
#    … #7 precheck → prepare → stage-b → stage-a → cleanup (netpol-run.sh, 하영 일반 세션) …
# ③ 창 끝(P8·P9 전): 떼기
READER_MODE=off DEADLINE_EPOCH=$(date -d '+20 min' +%s) bash ../../rbac/bootstrap/bootstrap-session.sh steps-reader.sh
# ④ 확인 → READER_CHECK_off=PASS(읽기 4종 no)
bash reader-check.sh off
```

| 단계 | 판정 | 멈춤 |
|---|---|---|
| on | 두 객체가 **없을 때만** `oc create`(덮어쓰기 없음) → create 출력·UID 확인 → binding 대상 = `fds-netpol-window-reader`·`User:hayeoung` 하나 → UID를 `$WORKDIR/netpol-reader-current.env`에 기록 | 이미 있음·조회 오류 → 만들지 않음. 일부만 생성 → UNKNOWN(떼기 전에 사람 확인). 실패해도 래퍼가 cluster-admin은 회수 |
| check on | 마지막 래퍼 회차가 이 단계·`REVOKE_VERIFIED`·`final_rc=0`으로 끝났는지 → 읽기 4종 **yes**, Secret 읽기·openshift-dns Pod 생성·node 삭제·network 수정·CRB 생성·`* *` **no**, `fds-app` NP 생성 yes, 실제 nodes·networkType 읽기 | 하나라도 다르면 FAIL — 떼기(③)로 |
| off | 기록 UID = 현재 UID일 때만 **Binding → Role** 순서로 삭제 → NotFound | UID 불일치·조회 오류·기록 없음 → 지우지 않고 STOP·인계 |
| check off | 읽기 4종 **no**(#5 ⑫ 상태) | — |

- 자동 재시도 없음. 래퍼가 중간에 끊겨도 trap이 revoke한다(SIGKILL·세션 유실은 두 번째 관리 세션에서 수동 revoke — #5와 같음).
- 반출: `reader-check.sh`가 단계 기록 + 래퍼 회수 원본(`session-events.log`·`verify-*`·`revoke.*`·`preflight-cluster.json`)을 묶는다. kubeconfig·token은 넣지 않는다. #5 receipt(`99-receipt.env`)는 이 회차에 발행되지 않는 것이 정상(증적 변수 `EV` 미사용).

## 3. 시험

`bash platform/netpol/access/tests/reader-mock.sh` → **13/13 PASS**(2026-10-22, Windows Git Bash, 가짜 `oc`, 래퍼는 log 줄로 흉내). 정상 on→check→off→check, Binding 먼저 삭제, scope 경고 허용, 이미 있음·UID 불일치·기록 없음·일부 생성 STOP, 회수 확인 없는 회차 판정 거부, Secret 읽기 yes FAIL, token 미기록. **실제 ROSA·래퍼 grant/revoke 동작 PASS가 아니다.**

💰 권한 변경은 과금 자원과 무관하다.

AI 사용: CLAUDE_ASSISTED (Claude Code, 이하영 지시로 작성)
