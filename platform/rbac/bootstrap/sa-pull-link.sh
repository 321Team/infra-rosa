#!/usr/bin/env bash
# infra-rosa#12 결정 6315085580 — fds-app 앱 SA 2개에 Harbor pull Secret 이름 참조를 추가(link)하고, 이 RUN이 추가한 항목만 원복(revert)한다.
# 사용: EXPECTED_CONTEXT=… EXPECTED_API=… EXPECTED_USER=… EXPECTED_NS_UID=… EXPECTED_SECRET_UID=… \
#         sa-pull-link.sh link <RUN 폴더(새로 만듦)>   |   (같은 EXPECTED_*) sa-pull-link.sh revert <같은 RUN 폴더>
# 규칙(PR#52 리뷰 R1·R2·R3):
#  - 모든 실패는 그 자리에서 비정상 종료(rc≠0). 부분 성공·응답 불명은 RUN 폴더에 남기고 자동 재시도·자동 삭제하지 않는다.
#  - link 는 SA마다 intent(patch 전) → 정확한 readback → ACK(배타 생성)를 남긴다. ACK에는 대상 API·namespace UID·Secret UID·SA UID·원 목록·추가 항목.
#  - revert 는 ACK가 있는 SA만, 현재 SA UID = ACK의 SA UID일 때만, uid·resourceVersion·항목 이름을 test 한 JSON patch로 그 1개만 지운다.
#  - R3: EXPECTED_*(실행 GO 원문의 승인값)가 없으면 시작하지 않는다. 모든 oc API 호출은 oc_call(고정 --context·--server,
#    TLS 검증 강제, 유한 상한)로만 한다. kubeconfig의 EXPECTED_CONTEXT→server가 EXPECTED_API인지 시작 때와 매 patch 직전에 확인하고,
#    API·사용자·namespace UID·Secret UID가 승인값과 다르면 첫 patch 전에 멈춘다.
#  - Secret 값은 읽지 않는다(type·UID 메타데이터만). SA에는 이름 참조만 있다.
set -euo pipefail
umask 077
OC=${OC:-oc}
PY=${PY:-python3}
NS=fds-app
SECRET=p2-coldpull-harbor-pull
SAS=(transaction-api-sa fds-engine-sa)
MODE=${1:-}; RUN=${2:-}
[[ "$MODE" == link || "$MODE" == revert ]] && [[ -n "$RUN" ]] || { echo "usage: EXPECTED_*=… $0 link|revert <RUN dir>" >&2; exit 2; }
for v in EXPECTED_CONTEXT EXPECTED_API EXPECTED_USER EXPECTED_NS_UID EXPECTED_SECRET_UID; do
  [[ -n "${!v:-}" ]] || { echo "STOP $v 없음 — 실행 GO 원문의 승인값을 넣고 실행(추정값 금지)" >&2; exit 2; }
done

say() { echo "$(TZ=KST-9 date '+%F %T KST') [$MODE] $*" | tee -a "$RUN/ledger.txt" >&2; }
stop() { say "STOP $*"; echo "RESULT=STOP mode=$MODE reason=$*"; exit "${STOP_RC:-1}"; }
excl() { ( set -o noclobber; cat >"$1" ) 2>/dev/null; }   # 배타 생성: 이미 있으면 실패

# R3: 모든 API 호출은 이 함수로만 — 승인 context·server 고정, TLS 검증 강제, 유한 상한
oc_call() {
  timeout --kill-after=5s 45s "$OC" --context="$EXPECTED_CONTEXT" --server="$EXPECTED_API" \
    --insecure-skip-tls-verify=false --request-timeout=30s "$@"
}
ctx_check() { # kubeconfig에서 EXPECTED_CONTEXT → cluster.server = EXPECTED_API, TLS 생략 설정 없음 (네트워크 호출 없음)
  local s
  s=$(timeout 15s "$OC" config view -o json | "$PY" -c 'import json, sys
c = json.load(sys.stdin); ctx = sys.argv[1]
m = [x.get("context") or {} for x in (c.get("contexts") or []) if x.get("name") == ctx]
if len(m) != 1: sys.exit("CONTEXT_NOT_FOUND")
cl = [x.get("cluster") or {} for x in (c.get("clusters") or []) if x.get("name") == m[0].get("cluster")]
if len(cl) != 1: sys.exit("CLUSTER_NOT_FOUND")
if cl[0].get("insecure-skip-tls-verify"): sys.exit("CONTEXT_TLS_SKIP")
print(cl[0].get("server", ""))' "$EXPECTED_CONTEXT") || return 1
  [[ "$s" == "$EXPECTED_API" ]]
}
target_now() { # 고정 대상의 API·사용자·namespace UID (secret 값 없음)
  local server user nsuid
  ctx_check || return 1
  server=$(oc_call whoami --show-server) || return 1
  user=$(oc_call whoami) || return 1
  nsuid=$(oc_call get ns "$NS" -o jsonpath='{.metadata.uid}') || return 1
  [[ -n "$server" && -n "$user" && -n "$nsuid" ]] || return 1
  printf '%s\n%s\n%s\n' "$server" "$user" "$nsuid"
}
expect_target() { # target 파일 = 승인값
  local s u n
  { read -r s; read -r u; read -r n; } <"$1"
  [[ "$s" == "$EXPECTED_API" && "$u" == "$EXPECTED_USER" && "$n" == "$EXPECTED_NS_UID" ]]
}

if [[ "$MODE" == link ]]; then
  mkdir -m 700 "$RUN" 2>/dev/null || { echo "STOP RUN dir exists or cannot be created: $RUN (원 snapshot 보존을 위해 새 폴더만 허용)" >&2; exit 1; }
  # 0) 대상: 고정 context·server로 읽고 승인값과 대조
  target_now >"$RUN/target.txt" || stop "target read failed (context→server/TLS 또는 조회)"
  { read -r SERVER; read -r USER_NAME; read -r NS_UID; } <"$RUN/target.txt"
  say "target context=$EXPECTED_CONTEXT server=$SERVER user=$USER_NAME ns_uid=$NS_UID"
  expect_target "$RUN/target.txt" || stop "target differs from EXPECTED_API/USER/NS_UID"
  # 1) Secret 메타데이터만: type·UID(승인값과 같아야 함)
  META=$(oc_call get secret "$SECRET" -n "$NS" -o jsonpath='{.type}{" "}{.metadata.uid}') || stop "secret read failed"
  read -r SECRET_TYPE SECRET_UID <<<"$META"
  [[ "$SECRET_TYPE" == kubernetes.io/dockerconfigjson && -n "${SECRET_UID:-}" ]] || stop "secret type/uid ($META)"
  [[ "$SECRET_UID" == "$EXPECTED_SECRET_UID" ]] || stop "secret uid differs from EXPECTED_SECRET_UID ($SECRET_UID)"
  say "secret type=$SECRET_TYPE uid=$SECRET_UID"
  # 2) 변경 전 snapshot 전부(덮어쓰기 없음) — 하나라도 실패하면 아무 SA도 바꾸지 않는다
  for sa in "${SAS[@]}"; do
    oc_call get sa "$sa" -n "$NS" -o json | excl "$RUN/before-$sa.json" || stop "snapshot $sa"
    "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$RUN/before-$sa.json" || stop "snapshot $sa not json"
  done
  # 3) SA마다: patch 생성(이미 있으면 거부) → intent → context 재확인 → patch → readback → ACK
  for sa in "${SAS[@]}"; do
    PATCH=$("$PY" - "$RUN/before-$sa.json" "$SECRET" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); s = sys.argv[2]; cur = o.get("imagePullSecrets")
if o.get("automountServiceAccountToken") is not False:
    sys.exit("AUTOMOUNT_NOT_FALSE")
ops = [{"op": "test", "path": "/metadata/uid", "value": o["metadata"]["uid"]},
       {"op": "test", "path": "/metadata/resourceVersion", "value": o["metadata"]["resourceVersion"]}]
if cur is None:
    ops.append({"op": "add", "path": "/imagePullSecrets", "value": [{"name": s}]})
elif any(e.get("name") == s for e in cur):
    sys.exit("ALREADY_PRESENT")
else:
    ops.append({"op": "add", "path": "/imagePullSecrets/-", "value": {"name": s}})
print(json.dumps(ops))
PY
    ) || stop "patch build $sa (ALREADY_PRESENT/AUTOMOUNT은 수동 readback)"
    ctx_check || stop "context→server changed before patch $sa (patch 안 함)"
    printf '%s\n' "$PATCH" | excl "$RUN/intent-$sa.json" || stop "intent $sa already exists"
    oc_call patch sa "$sa" -n "$NS" --type=json -p "$PATCH" >/dev/null || stop "patch $sa (intent 있음, ACK 없음 → 응답 불명: 수동 readback·인수)"
    oc_call get sa "$sa" -n "$NS" -o json | excl "$RUN/after-$sa.json" || stop "readback $sa"
    "$PY" - "$RUN/before-$sa.json" "$RUN/after-$sa.json" "$SECRET" "$SERVER" "$NS" "$NS_UID" "$SECRET_UID" "$RUN" "$EXPECTED_CONTEXT" \
      >"$RUN/ack-$sa.tmp" <<'PY' || { rm -f "$RUN/ack-$sa.tmp"; stop "readback mismatch $sa (ACK 없음 → 수동 readback·인수)"; }
import json, sys
b, a = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
s, server, ns, ns_uid, secret_uid, run, context = sys.argv[3:10]
before = b.get("imagePullSecrets") or []
want = before + [{"name": s}]
ok = (a.get("imagePullSecrets") == want and a["metadata"]["uid"] == b["metadata"]["uid"]
      and a["metadata"]["name"] == b["metadata"]["name"] and a.get("automountServiceAccountToken") is False)
print(a["metadata"]["name"], "SA_PULL_LINK_PASS" if ok else "SA_PULL_LINK_FAIL",
      [e.get("name") for e in a.get("imagePullSecrets", [])], file=sys.stderr)
if not ok:
    sys.exit(1)
print(json.dumps({"run": run, "context": context, "server": server, "namespace": ns, "namespace_uid": ns_uid,
                  "secret": s, "secret_uid": secret_uid, "sa": a["metadata"]["name"], "sa_uid": a["metadata"]["uid"],
                  "before": before, "added": {"name": s}, "after_resource_version": a["metadata"]["resourceVersion"]},
                 sort_keys=True))
PY
    excl "$RUN/ack-$sa.json" <"$RUN/ack-$sa.tmp" || stop "ack $sa already exists"
    rm -f "$RUN/ack-$sa.tmp"
    say "ACK $sa"
  done
  say "LINK_PASS"; echo "RESULT=LINK_PASS run=$RUN"
  exit 0
fi

# ---- revert: 이 RUN의 ACK가 있는 SA만 ----
[[ -d "$RUN" && -f "$RUN/target.txt" ]] || { echo "STOP RUN dir/target.txt missing: $RUN" >&2; exit 1; }
target_now >"$RUN/target-revert.now" || stop "target read failed (context→server/TLS 또는 조회)"
cmp -s "$RUN/target.txt" "$RUN/target-revert.now" || stop "target (API/user/namespace UID) differs from link RUN"
expect_target "$RUN/target-revert.now" || stop "target differs from EXPECTED_API/USER/NS_UID"
unknown=0; done_n=0
for sa in "${SAS[@]}"; do
  if [[ ! -f "$RUN/ack-$sa.json" ]]; then
    if [[ -f "$RUN/intent-$sa.json" ]]; then say "UNKNOWN $sa: intent만 있고 ACK 없음 → 삭제하지 않음(수동 readback·인수)"; unknown=1
    else say "SKIP $sa: 이 RUN에서 추가하지 않음"; fi
    continue
  fi
  if [[ -f "$RUN/revert-ack-$sa.json" ]]; then say "SKIP $sa: 이미 원복 확인됨"; done_n=$((done_n+1)); continue; fi
  "$PY" -c 'import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if a.get("secret_uid")==sys.argv[2] and a.get("namespace_uid")==sys.argv[3] and a.get("server")==sys.argv[4] else 1)' \
    "$RUN/ack-$sa.json" "$EXPECTED_SECRET_UID" "$EXPECTED_NS_UID" "$EXPECTED_API" || stop "ACK $sa target/secret uid differs from EXPECTED_*"
  oc_call get sa "$sa" -n "$NS" -o json | excl "$RUN/pre-revert-$sa.json" \
    || stop "pre-revert $sa (이미 있으면 이전 원복 시도 흔적 → 수동 readback)"
  PATCH=$("$PY" - "$RUN/ack-$sa.json" "$RUN/pre-revert-$sa.json" <<'PY'
import json, sys
ack, cur = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
s = ack["secret"]
if cur["metadata"]["uid"] != ack["sa_uid"]:
    sys.exit("SA_UID_CHANGED")
idx = [i for i, e in enumerate(cur.get("imagePullSecrets") or []) if e.get("name") == s]
if len(idx) != 1:
    sys.exit("NOT_EXACTLY_ONE")
i = idx[0]
print(json.dumps([{"op": "test", "path": "/metadata/uid", "value": ack["sa_uid"]},
                  {"op": "test", "path": "/metadata/resourceVersion", "value": cur["metadata"]["resourceVersion"]},
                  {"op": "test", "path": f"/imagePullSecrets/{i}/name", "value": s},
                  {"op": "remove", "path": f"/imagePullSecrets/{i}"}]))
PY
  ) || stop "revert build $sa (UID 변경/항목 불일치 → 삭제하지 않음)"
  ctx_check || stop "context→server changed before revert patch $sa (patch 안 함)"
  printf '%s\n' "$PATCH" | excl "$RUN/revert-intent-$sa.json" || stop "revert intent $sa already exists (재삭제 금지, 수동 readback)"
  oc_call patch sa "$sa" -n "$NS" --type=json -p "$PATCH" >/dev/null || stop "revert patch $sa (응답 불명 → 수동 readback·인수)"
  oc_call get sa "$sa" -n "$NS" -o json | excl "$RUN/post-revert-$sa.json" || stop "post-revert readback $sa"
  "$PY" - "$RUN/ack-$sa.json" "$RUN/pre-revert-$sa.json" "$RUN/post-revert-$sa.json" >"$RUN/revert-ack-$sa.tmp" <<'PY' \
    || { rm -f "$RUN/revert-ack-$sa.tmp"; stop "revert readback mismatch $sa"; }
import json, sys
ack, pre, post = (json.load(open(p)) for p in sys.argv[1:4])
s = ack["secret"]; lst = pre.get("imagePullSecrets") or []
i = [k for k, e in enumerate(lst) if e.get("name") == s][0]
want = lst[:i] + lst[i + 1:]
got = post.get("imagePullSecrets") or []
ok = (got == want and post["metadata"]["uid"] == ack["sa_uid"] and post.get("automountServiceAccountToken") is False)
print(post["metadata"]["name"], "SA_PULL_REVERT_PASS" if ok else "SA_PULL_REVERT_FAIL", [e.get("name") for e in got], file=sys.stderr)
if not ok:
    sys.exit(1)
print(json.dumps({"sa": ack["sa"], "sa_uid": ack["sa_uid"], "removed": {"name": s}, "remaining": got}, sort_keys=True))
PY
  excl "$RUN/revert-ack-$sa.json" <"$RUN/revert-ack-$sa.tmp" || stop "revert ack $sa already exists"
  rm -f "$RUN/revert-ack-$sa.tmp"
  say "REVERTED $sa"; done_n=$((done_n+1))
done
[[ $unknown == 0 ]] || stop "UNKNOWN SA remains (see ledger)"
say "REVERT_PASS ($done_n SA)"; echo "RESULT=REVERT_PASS run=$RUN"
