# 창 B 전용 tool Pod NetworkPolicy (infra-rosa#7 소관, DRAFT)

- 작성: 이하영, 2026-10-19 KST. **적용·승인 아님.** 클러스터 호출 0
- 근거: [infra-rosa#12 권욱 검토 6263431388](https://github.com/321Team/infra-rosa/issues/12#issuecomment-6263431388) B2(정책 원문), [창 B 카드 v2 6263634565](https://github.com/321Team/infra-rosa/issues/12#issuecomment-6263634565) P7·④-P
- 파일: [`20-coldpull-probe-egress.yaml`](20-coldpull-probe-egress.yaml) · 검사기 [`check_window_b_np.py`](check_window_b_np.py) · 시험 [`tests/`](tests/)

## 1. 무엇을 하는 정책인가

창 B(cold-pull) 동안 `fds-app`에서 **cold-pull 키트 v5의 tool Pod만** 골라, 키트가 시험하는 4개 대상으로만 나가게 허용합니다.

| 대상 | 포트 | 키트 시험 | 기대 |
|---|---|---|---|
| `10.1.93.54`(harbor01) | 443 | P0(길 열기 전)·P1·T1·T2 | P0 연결 안 됨, P1 401, T1 curl 60, T2 verify 0 |
| `10.1.93.54` | 22, 80 | P2-22·P2-80(음성) | 연결 안 됨(SG·Relay nft에서) |
| `10.1.93.50`(edge01) | 443 | P3(음성) | 연결 안 됨 |

- **왜 필요한가:** tool Pod 라벨(`app.kubernetes.io/part-of=fds-coldpull`, `fds-coldpull-case=tool`)은 #7 `03-allow-egress-onprem.yaml`(`onprem-egress=true`)에 선택되지 않습니다. 창 A 뒤 `fds-app`에는 플랫폼 00(기본 차단)이 남아 있으므로, 이 정책이 없으면 P1·T1·T2가 Pod 단계에서 막힙니다. `.54:443`만 열면 음성 P2·P3가 Pod 단계에서 먼저 막혀 **SG·Relay nft가 막았는지 귀속할 수 없습니다.** 그래서 음성 대상까지 Pod 단계만 통과시켜 아래 계층의 차단을 관측합니다.
- **넓히지 않는 것:** AWS SG·Relay nft·vpn-gw01·Harbor 허용은 이 정책과 무관하며 넓히지 않습니다. 새 포트 스캔·서비스 로그인·TLS 우회가 아닙니다. 플랫폼 00~03과 키트는 바꾸지 않습니다.
- **선택 범위:** `fds-coldpull-case=tool`만. pull Pod(`case=pull`)는 선택하지 않습니다(이미지 pull은 node CRI-O 경로로 Pod NetworkPolicy와 무관). run 라벨(`fds-coldpull-run`)은 `61` 실행마다 바뀌어(before·after가 다름) 선택자에 쓰지 않습니다.
- **DNS:** 키트는 IP(`https://10.1.93.54/v2/`)로 접속하므로 넣지 않습니다.
- D22(Registry 경로 최종 선택)를 이 임시 시험 정책으로 확정하지 않습니다.

## 2. 오프라인 검사 (적용 전, 무료)

```bash
python3 platform/netpol/window-b/check_window_b_np.py platform/netpol/window-b/20-coldpull-probe-egress.yaml platform/netpol/03-allow-egress-onprem.yaml <coldpull-kit-v5 폴더>
```
- namespace는 `fds-app`, 선택자는 승인된 tool 라벨 두 개와 **정확히 같아야** 합니다(기준값은 검사 대상 정책에서 가져오지 않음).
- 키트의 실제 `coldpull_tool.podspec()`으로 `fds-app`의 tool·pull Pod를 만들어 선택자와 대조하고(tool 선택·pull 비선택·#7 03 비선택), 허용 tuple이 키트 `kit.env`(`IMAGE_HOST`·`HARBOR_PORT`·`NEG_HARBOR_PORTS`·`P3_TARGET_*`)와 **정확히 같은지** 봅니다. Egress만, /32 ipBlock·TCP 단일 포트만 허용합니다.
- 2026-10-20 결과: 키트 v5(`SHA256SUMS` `73be95ab…`, `coldpull_tool.py` `477a2228…`, `kit.env` `75cb1fe9…`)로 **PASS**. 반례 시험 18/18 OK(`python3 platform/netpol/window-b/tests/test_check_window_b_np.py`, namespace 틀림·없음·`part-of` 삭제 3건 추가).
- 이 검사는 CNI 실제 효과 시험이 아닙니다. 실제 효과는 창 B의 P0·P1·P2·P3 결과와 Relay·vpn-gw01·Harbor guard 카운터로 봅니다.

## 3. 창 B 안 절차 (카드 ④-P·⑨, 별도 GO 뒤)

**공통 사전 읽기(④-P, P0 전):**
1. `oc -n fds-app get networkpolicy -o yaml` 원문 보존, 이름·UID·`spec` SHA-256 목록 기록. NetworkPolicy는 허용이 합집합이므로 기존 정책 원문도 함께 대조합니다([Kubernetes 문서](https://kubernetes.io/docs/concepts/services-networking/network-policies/#the-two-sorts-of-pod-isolation)).
2. 아래 중 **하나로만** 갑니다. 기록 칸 `CREATED_THIS_WINDOW`로 구분합니다.
   - 이름 `coldpull-probe-egress-window-b`가 이미 있음 → **만들지 않고 HOLD**(재사용으로 넘기지 않음)
   - 다른 이름의 **같은 정확 허용**(선택자 두 라벨·tuple 4개·Egress만)이 이미 있음 → **경우 A(재사용)**
   - 둘 다 아님 → **경우 B(새로 만들기)**
   - 예상 밖 정책·조회 오류 → HOLD

**경우 A — 기존 동등 정책 재사용 (`CREATED_THIS_WINDOW=false`)**
- 기록: 그 정책의 이름·UID·`spec` SHA-256·원문, `CREATED_THIS_WINDOW=false`
- 이 창에서 만들지도 지우지도 않습니다.
- 창 끝(⑨): 같은 이름·UID·`spec` SHA-256이 그대로인지, 정책 목록이 1번과 같은지(늘거나 줄지 않음) readback만 합니다. 달라졌으면 HOLD·보고(되돌리지 않음).

**경우 B — 새로 만들기 (`CREATED_THIS_WINDOW=true`)**
- 만들기: `oc create -f platform/netpol/window-b/20-coldpull-probe-egress.yaml -o jsonpath='{.metadata.uid}'` → 성공한 경우에만 **생성 UID**와 `CREATED_THIS_WINDOW=true` 기록(`apply`가 아니라 `create`: 기존 객체를 덮어쓰지 않음)
- 만들기 실패·timeout·UID 수신 실패: 서버에 저장된 뒤 응답만 끊겼을 수 있으므로 `false`로 바로 확정하지 않고 **생성 결과 불명확(`CREATED_THIS_WINDOW=UNKNOWN`)**으로 기록하고 HOLD합니다. 자동 재시도·삭제는 하지 않습니다. 창 B 카드 P7 readback·inventory로 정확한 이름 `coldpull-probe-egress-window-b`를 조회해
  - 정상 NotFound면 미생성으로 보고 `CREATED_THIS_WINDOW=false`로 확정
  - 객체가 있으면 UID·원문(`-o yaml`)을 보존하고 **소유 미확정 잔여**로 권욱 님께 보고(이 창이 만든 것으로 추정해 지우지 않음)
  - 조회도 실패하면 `UNKNOWN`을 유지하고 보고
- readback: `oc -n fds-app get networkpolicy coldpull-probe-egress-window-b -o yaml` 원본 보존, 정책 목록이 1번 대비 **이 정책 1개만 늘었는지** 대조
- 창 끝(⑨): `oc -n fds-app get networkpolicy coldpull-probe-egress-window-b -o jsonpath='{.metadata.uid}'`가 **생성 UID와 같을 때만** `oc -n fds-app delete networkpolicy coldpull-probe-egress-window-b --wait=true` → 같은 이름 NotFound, 정책 목록이 1번과 같음(플랫폼 00~03 그대로)

**멈추는 조건:** 예상 밖 정책, 목록 불일치, UID 불일치·조회 오류·생성 결과 불명확(`UNKNOWN`) → 지우지 않고 HOLD·보고. `CREATED_THIS_WINDOW=false`·`UNKNOWN`인 정책과 소유 불명 객체는 어떤 경우에도 지우지 않습니다. 자동 재시도·다른 정책 삭제·디렉터리 일괄 delete 없음.

💰 이 정책은 과금 자원을 만들지 않습니다.

AI 사용: CLAUDE_ASSISTED (Claude Code, 이하영 지시로 작성)
