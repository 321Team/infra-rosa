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
- 키트의 실제 `coldpull_tool.podspec()`으로 tool·pull Pod를 만들어 선택자와 대조하고(tool 선택·pull 비선택·#7 03 비선택), 허용 tuple이 키트 `kit.env`(`IMAGE_HOST`·`HARBOR_PORT`·`NEG_HARBOR_PORTS`·`P3_TARGET_*`)와 **정확히 같은지** 봅니다. Egress만, /32 ipBlock·TCP 단일 포트만 허용합니다.
- 2026-10-19 결과: 키트 v5(`SHA256SUMS` `73be95ab…`, `coldpull_tool.py` `477a2228…`, `kit.env` `75cb1fe9…`)로 **PASS**. 반례 시험 15/15 OK(`python3 platform/netpol/window-b/tests/test_check_window_b_np.py`).
- 이 검사는 CNI 실제 효과 시험이 아닙니다. 실제 효과는 창 B의 P0·P1·P2·P3 결과와 Relay·vpn-gw01·Harbor guard 카운터로 봅니다.

## 3. 창 B 안 절차 (카드 ④-P·⑨, 별도 GO 뒤)

**만들기(④-P, P0 전):**
1. 기존 정책 목록 읽기: `oc -n fds-app get networkpolicy -o name` 원문 기록. 같은 이름이 있으면 **만들지 않고 HOLD**. 같은 정확 허용(선택자·tuple 4개)이 이미 live에 있으면 그것을 재사용하고 새로 만들지 않습니다(UID 기록).
2. 만들기: `oc create -f platform/netpol/window-b/20-coldpull-probe-egress.yaml -o jsonpath='{.metadata.uid}'` → **UID 기록**(`apply`가 아니라 `create`: 기존 객체를 덮어쓰지 않음)
3. readback: `oc -n fds-app get networkpolicy coldpull-probe-egress-window-b -o yaml` 원본 보존, 정책 목록을 1번과 대조(이 정책 1개만 늘어야 함)

**지우기(⑨, 창 끝):**
4. `oc -n fds-app get networkpolicy coldpull-probe-egress-window-b -o jsonpath='{.metadata.uid}'`가 2번 UID와 같을 때만 `oc -n fds-app delete networkpolicy coldpull-probe-egress-window-b --wait=true`
5. readback: 같은 이름 NotFound, 정책 목록이 1번과 같음(플랫폼 00~03 그대로)

**멈추는 조건:** 1번에 예상 밖 정책, 3번 목록 불일치, 4번 UID 불일치·조회 오류 → 지우지 않고 HOLD·보고. 자동 재시도·다른 정책 삭제·디렉터리 일괄 delete 없음.

💰 이 정책은 과금 자원을 만들지 않습니다.

AI 사용: CLAUDE_ASSISTED (Claude Code, 이하영 지시로 작성)
