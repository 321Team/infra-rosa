#!/usr/bin/env bash
# sa-pull-link.sh MOCK 시험(가짜 oc, 클러스터 호출 없음, 비용 없음). 하나라도 FAIL 이면 rc1.
# PR#52 리뷰 R1(실패 전파)·R2(ACK 소유 원복)·R3(승인 대상 결속: EXPECTED_*·고정 context/server)의 정상·실패 경로를 상태 JSON으로 확인한다.
# 가짜 oc는 kubeconfig(context→cluster→server)와 두 번째 클러스터(api.other.invalid)를 흉내 낸다. context의 자격으로 다른 server를
# 부르면 Unauthorized로 거부한다(실제 oc처럼 자격은 context 쪽).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY=${PY:-python3}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
cat >"$T/oc.py" <<'PY'
import json, os, sys
st_path = os.environ["MOCK_STATE"]; st = json.load(open(st_path))
def save(): json.dump(st, open(st_path, "w"))
def failpoint(key):
    rc = st.get("fail", {}).get(key)
    if rc:
        print(f"mock failure {key}", file=sys.stderr); sys.exit(rc)
kube = st.setdefault("kube", {"current": "rosa-ctx",
                              "contexts": {"rosa-ctx": "rosa", "other-ctx": "other"},
                              "clusters": {"rosa": "https://api.mock:443", "other": "https://api.other.invalid:443"}})
flags, a = {}, []
for x in sys.argv[1:]:
    if x.startswith("--context="): flags["context"] = x.split("=", 1)[1]
    elif x.startswith("--server="): flags["server"] = x.split("=", 1)[1]
    elif x == "--insecure-skip-tls-verify=false": flags["tls"] = "verify"
    elif x.startswith("--request-timeout="): flags["timeout"] = x.split("=", 1)[1]
    else: a.append(x)
if a[:2] == ["config", "view"]:
    print(json.dumps({"current-context": kube["current"],
                      "contexts": [{"name": n, "context": {"cluster": c, "user": "hayeoung"}} for n, c in kube["contexts"].items()],
                      "clusters": [{"name": n, "cluster": {"server": s}} for n, s in kube["clusters"].items()]}))
    sys.exit(0)
st.setdefault("calls", []).append({"context": flags.get("context"), "server": flags.get("server"),
                                   "tls": flags.get("tls"), "cmd": " ".join(a[:2])}); save()
ctx = flags.get("context") or kube["current"]
if ctx not in kube["contexts"]: print("error: context not found", file=sys.stderr); sys.exit(1)
ctx_server = kube["clusters"][kube["contexts"][ctx]]
server = flags.get("server") or ctx_server
if server != ctx_server: print("error: You must be logged in to the server (Unauthorized)", file=sys.stderr); sys.exit(1)
D = st if server == st["server"] else st.get("others", {}).get(server)
if D is None: print("Unable to connect to the server", file=sys.stderr); sys.exit(1)
if a[:2] == ["whoami", "--show-server"]: print(server); sys.exit(0)
if a[:1] == ["whoami"]: print(D["user"]); sys.exit(0)
if a[:2] == ["get", "ns"]: sys.stdout.write(D["ns_uid"]); sys.exit(0)
if a[:2] == ["get", "secret"]:
    failpoint("get_secret")
    s = D.get("secret")
    if not s: print('Error from server (NotFound)', file=sys.stderr); sys.exit(1)
    sys.stdout.write(f'{s["type"]} {s["uid"]}'); sys.exit(0)
if a[:2] == ["get", "sa"]:
    name = a[2]; failpoint("get_sa:" + name)
    n = st.setdefault("reads", {}); n[name] = n.get(name, 0) + 1
    # 조회 뒤 다른 셸의 context 전환(current) / 같은 context 이름의 cluster 재지정
    if st.get("switch_current_after_reads") == sum(n.values()): kube["current"] = "other-ctx"
    if st.get("repoint_after_reads") == sum(n.values()): kube["contexts"]["rosa-ctx"] = "other"
    save()
    failpoint(f"get_sa:{name}:{n[name]}")
    print(json.dumps(D["sas"][name])); sys.exit(0)
if a[:2] == ["patch", "sa"]:
    name = a[2]; ops = json.loads(a[a.index("-p") + 1]); failpoint("patch:" + name)
    obj = json.loads(json.dumps(D["sas"][name]))
    for o in ops:
        parts = o["path"].strip("/").split("/"); tgt = obj
        for p in parts[:-1]: tgt = tgt[int(p)] if isinstance(tgt, list) else tgt[p]
        k = parts[-1]
        if o["op"] == "test":
            v = tgt[int(k)] if isinstance(tgt, list) else tgt.get(k)
            if v != o["value"]: print("test failed", file=sys.stderr); sys.exit(1)
        elif o["op"] == "add":
            if isinstance(tgt, list): tgt.append(o["value"]) if k == "-" else tgt.insert(int(k), o["value"])
            else: tgt[k] = o["value"]
        elif o["op"] == "remove": del tgt[int(k)]
    obj["metadata"]["resourceVersion"] = str(int(obj["metadata"]["resourceVersion"]) + 1)
    if st.get("tamper") == name: obj.setdefault("imagePullSecrets", []).append({"name": "tamper"})
    D["sas"][name] = obj; st.setdefault("patches", []).append(server + "|" + name); save()
    failpoint("patch_after:" + name)  # 적용 후 응답 유실
    print(f"serviceaccount/{name} patched"); sys.exit(0)
print("unexpected oc " + " ".join(a), file=sys.stderr); sys.exit(99)
PY
printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$PY" "$T/oc.py" >"$T/oc"; chmod +x "$T/oc"

sa() { # sa <name> <uid> <pulls_json>
  printf '{"apiVersion":"v1","kind":"ServiceAccount","metadata":{"name":"%s","namespace":"fds-app","uid":"%s","resourceVersion":"100"},"automountServiceAccountToken":false%s}' \
    "$1" "$2" "$( [ "$3" = none ] && echo "" || echo ",\"imagePullSecrets\":$3")"
}
TX_DEFAULT='[{"name":"transaction-api-sa-dockercfg-abc"}]'
base_state() { # base_state <file> [tx_pulls] [fe_pulls]  (기본: tx는 OpenShift dockercfg 1개, fe는 목록 없음)
  local tx=${2:-$TX_DEFAULT} fe=${3:-none}
  printf '{"server":"https://api.mock:443","user":"hayeoung","ns_uid":"ns-1","secret":{"type":"kubernetes.io/dockerconfigjson","uid":"sec-1"},"sas":{"transaction-api-sa":%s,"fds-engine-sa":%s}}' \
    "$(sa transaction-api-sa tx-uid "$tx")" "$(sa fds-engine-sa fe-uid "$fe")" >"$1"
}
add_other() { # add_other <file> : 같은 fds-app·SA2·Secret 이름이 있는 다른 클러스터(api.other.invalid)
  "$PY" - "$1" "$(sa transaction-api-sa tx-OTHER none)" "$(sa fds-engine-sa fe-OTHER none)" <<'PY'
import json, sys
p = sys.argv[1]; st = json.load(open(p))
st["others"] = {"https://api.other.invalid:443": {"user": "hayeoung", "ns_uid": "ns-OTHER",
  "secret": {"type": "kubernetes.io/dockerconfigjson", "uid": "sec-OTHER"},
  "sas": {"transaction-api-sa": json.loads(sys.argv[2]), "fds-engine-sa": json.loads(sys.argv[3])}}}
json.dump(st, open(p, "w"))
PY
}
edit() { "$PY" - "$1" "$2" <<'PY'
import json, sys
p, code = sys.argv[1], sys.argv[2]; st = json.load(open(p)); exec(code); json.dump(st, open(p, "w"))
PY
}
pulls() { "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["sas"][sys.argv[2]]; print(json.dumps([e["name"] for e in s.get("imagePullSecrets",[])]))' "$1" "$2"; }
npatch() { "$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("patches",[])))' "$1"; }
npatch_srv() { "$PY" -c 'import json,sys; print(len([p for p in json.load(open(sys.argv[1])).get("patches",[]) if p.startswith(sys.argv[2]+"|")]))' "$1" "$2"; }
unpinned() { # 고정 context·server·TLS 없이 나간 API 호출 수
  "$PY" -c 'import json,sys; c=json.load(open(sys.argv[1])).get("calls",[]); print(len([x for x in c if x["context"]!="rosa-ctx" or x["server"]!="https://api.mock:443" or x["tls"]!="verify"]))' "$1"; }
# 승인값(기본). 시험마다 E_*로 바꿀 수 있고, 빈 값으로 두면 '없음'을 시험한다.
go() { # go <state> <mode> <run>  → rc
  MOCK_STATE="$1" OC="$T/oc" PY="$PY" \
  EXPECTED_CONTEXT="${E_CTX-rosa-ctx}" EXPECTED_API="${E_API-https://api.mock:443}" EXPECTED_USER="${E_USER-hayeoung}" \
  EXPECTED_NS_UID="${E_NS-ns-1}" EXPECTED_SECRET_UID="${E_SEC-sec-1}" \
    bash "$HERE/sa-pull-link.sh" "$2" "$3" >"$3.out.$2" 2>"$3.err.$2"; }
check() { # check <name> <cond-result 0/1>
  if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
eq() { [ "$1" = "$2" ]; }

# 1 정상 link → revert: 기존 dockercfg 보존, 자기 항목만 추가·삭제, 2회째 revert는 재patch 없음
S=$T/s1; base_state $S; R=$T/r1
go $S link $R; rc=$?
check "01 link PASS rc0" $([ $rc = 0 ] && grep -q RESULT=LINK_PASS $R.out.link && echo 0 || echo 1)
check "01 lists after link" $(eq "$(pulls $S transaction-api-sa)$(pulls $S fds-engine-sa)" '["transaction-api-sa-dockercfg-abc", "p2-coldpull-harbor-pull"]["p2-coldpull-harbor-pull"]' && echo 0 || echo 1)
check "01 ack has sa_uid+secret_uid" $(grep -q '"sa_uid": "tx-uid"' $R/ack-transaction-api-sa.json && grep -q '"secret_uid": "sec-1"' $R/ack-fds-engine-sa.json && echo 0 || echo 1)
go $S revert $R; rc=$?
check "01 revert PASS rc0" $([ $rc = 0 ] && grep -q RESULT=REVERT_PASS $R.out.revert && echo 0 || echo 1)
check "01 lists after revert" $(eq "$(pulls $S transaction-api-sa)$(pulls $S fds-engine-sa)" '["transaction-api-sa-dockercfg-abc"][]' && echo 0 || echo 1)
n=$(npatch $S); go $S revert $R; rc=$?
check "01 second revert no patch rc0" $([ $rc = 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)

# 2 Secret type 틀림 → rc≠0, SA patch 0
S=$T/s2; base_state $S; edit $S 'st["secret"]["type"]="Opaque"'; R=$T/r2; go $S link $R; rc=$?
check "02 wrong secret type stops, no patch" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 3 Secret 없음 → rc≠0
S=$T/s3; base_state $S; edit $S 'st["secret"]=None'; R=$T/r3; go $S link $R; rc=$?
check "03 missing secret stops, no patch" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 4 두 번째 SA snapshot 실패(rc29) → rc≠0, 아무 SA도 patch 안 함
S=$T/s4; base_state $S; edit $S 'st["fail"]={"get_sa:fds-engine-sa:1":29}'; R=$T/r4; go $S link $R; rc=$?
check "04 snapshot failure stops before any patch" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 5 첫 SA patch 실패(rc37) → rc≠0, ACK 없음; revert는 UNKNOWN STOP·삭제 0
S=$T/s5; base_state $S; edit $S 'st["fail"]={"patch:transaction-api-sa":37}'; R=$T/r5; go $S link $R; rc=$?
check "05 patch failure stops, no ack" $([ $rc != 0 ] && [ ! -e $R/ack-transaction-api-sa.json ] && [ ! -e $R/intent-fds-engine-sa.json ] && echo 0 || echo 1)
go $S revert $R; rc=$?
check "05 revert UNKNOWN stops, no patch" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && grep -q UNKNOWN $R/ledger.txt && echo 0 || echo 1)
# 6 patch는 적용됐지만 응답 유실 → ACK 없음; revert는 삭제하지 않음(수동 인수)
S=$T/s6; base_state $S; edit $S 'st["fail"]={"patch_after:transaction-api-sa":1}'; R=$T/r6; go $S link $R; rc=$?
check "06 lost response stops, no ack" $([ $rc != 0 ] && [ ! -e $R/ack-transaction-api-sa.json ] && echo 0 || echo 1)
n=$(npatch $S); go $S revert $R; rc=$?
check "06 revert does not delete unacked entry" $([ $rc != 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)
# 7 readback 불일치(다른 항목 끼어듦) → rc≠0, ACK 없음
S=$T/s7; base_state $S; edit $S 'st["tamper"]="transaction-api-sa"'; R=$T/r7; go $S link $R; rc=$?
check "07 readback mismatch stops, no ack" $([ $rc != 0 ] && [ ! -e $R/ack-transaction-api-sa.json ] && echo 0 || echo 1)
# 8 부분 성공: 둘째 SA patch 실패 → 첫 SA만 ACK; revert는 첫 SA만 원복하고 rc≠0(UNKNOWN 보고)
S=$T/s8; base_state $S; edit $S 'st["fail"]={"patch:fds-engine-sa":37}'; R=$T/r8; go $S link $R; rc=$?
check "08 partial: first acked only" $([ $rc != 0 ] && [ -e $R/ack-transaction-api-sa.json ] && [ ! -e $R/ack-fds-engine-sa.json ] && echo 0 || echo 1)
edit $S 'st["fail"]={}'; go $S revert $R; rc=$?
check "08 partial revert: first restored, rc≠0" $([ $rc != 0 ] && eq "$(pulls $S transaction-api-sa)" '["transaction-api-sa-dockercfg-abc"]' && echo 0 || echo 1)
# 9 이미 같은 이름 참조가 있는 SA(ACK 없음): link 거부, revert는 기존 참조 2개를 지우지 않음
S=$T/s9; base_state $S '[{"name":"p2-coldpull-harbor-pull"}]' '[{"name":"p2-coldpull-harbor-pull"}]'; R=$T/r9; go $S link $R; rc=$?
check "09 ALREADY_PRESENT stops, no patch" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
go $S revert $R; rc=$?
check "09 revert keeps pre-existing refs" $([ "$(npatch $S)" = 0 ] && eq "$(pulls $S transaction-api-sa)$(pulls $S fds-engine-sa)" '["p2-coldpull-harbor-pull"]["p2-coldpull-harbor-pull"]' && echo 0 || echo 1)
# 10 SA가 같은 이름으로 재생성(UID 변경) → revert 거부·삭제 0
S=$T/s10; base_state $S; R=$T/r10; go $S link $R
edit $S 'st["sas"]["transaction-api-sa"]["metadata"]["uid"]="tx-uid-NEW"'; n=$(npatch $S); go $S revert $R; rc=$?
check "10 SA UID changed: revert refused" $([ $rc != 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)
# 11 RUN 폴더 재사용 → link 거부(원 snapshot 보존)
S=$T/s11; base_state $S; R=$T/r11; mkdir $R; echo keep >$R/before-transaction-api-sa.json; go $S link $R; rc=$?
check "11 existing RUN dir refused" $([ $rc != 0 ] && [ "$(cat $R/before-transaction-api-sa.json)" = keep ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 12 다른 클러스터/namespace에서 revert → 거부
S=$T/s12; base_state $S; R=$T/r12; go $S link $R
edit $S 'st["ns_uid"]="ns-OTHER"'; n=$(npatch $S); go $S revert $R; rc=$?
check "12 target differs: revert refused" $([ $rc != 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)
# 13 automount가 false가 아니면 link 거부
S=$T/s13; base_state $S; edit $S 'st["sas"]["fds-engine-sa"]["automountServiceAccountToken"]=True'; R=$T/r13; go $S link $R; rc=$?
check "13 automount not false: stop before that patch" $([ $rc != 0 ] && [ ! -e $R/ack-fds-engine-sa.json ] && echo 0 || echo 1)
# 14 revert patch 응답 유실 → rc≠0, 재실행 시 재삭제 시도 없음
S=$T/s14; base_state $S; R=$T/r14; go $S link $R
edit $S 'st["fail"]={"patch_after:transaction-api-sa":1}'; go $S revert $R; rc1=$?
edit $S 'st["fail"]={}'; n=$(npatch $S); go $S revert $R; rc2=$?
check "14 revert lost response: no second delete" $([ $rc1 != 0 ] && [ $rc2 != 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)

# ---- R3: 승인 대상 결속 ----
# 15 리뷰 재현: 현재 context가 다른 클러스터(같은 ns·SA2·Secret 이름, ns-OTHER/sec-OTHER)를 가리킴 → 양쪽 patch 0, rc≠0
S=$T/s15; base_state $S; add_other $S; edit $S 'st["kube"]={"current":"rosa-ctx","contexts":{"rosa-ctx":"other","other-ctx":"other"},"clusters":{"rosa":"https://api.mock:443","other":"https://api.other.invalid:443"}}'
R=$T/r15; go $S link $R; rc=$?
check "15 context points to other cluster: patch 0 (both), rc≠0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 16 잘못된 EXPECTED_API(승인 API가 context의 server와 다름) → patch 0
S=$T/s16; base_state $S; add_other $S; R=$T/r16; E_API=https://api.other.invalid:443 go $S link $R; rc=$?
check "16 wrong EXPECTED_API: patch 0, rc≠0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && echo 0 || echo 1)
# 17 잘못된 EXPECTED_USER → patch 0
S=$T/s17; base_state $S; R=$T/r17; E_USER=jaehwan go $S link $R; rc=$?
check "17 wrong EXPECTED_USER: patch 0, rc≠0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && grep -q 'target differs' $R/ledger.txt && echo 0 || echo 1)
# 18 잘못된 EXPECTED_NS_UID → patch 0
S=$T/s18; base_state $S; R=$T/r18; E_NS=ns-WRONG go $S link $R; rc=$?
check "18 wrong EXPECTED_NS_UID: patch 0, rc≠0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && grep -q 'target differs' $R/ledger.txt && echo 0 || echo 1)
# 19 잘못된 EXPECTED_SECRET_UID(같은 이름 다른 Secret) → patch 0, snapshot 전 STOP
S=$T/s19; base_state $S; R=$T/r19; E_SEC=sec-WRONG go $S link $R; rc=$?
check "19 wrong EXPECTED_SECRET_UID: patch 0, rc≠0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && [ ! -e $R/before-transaction-api-sa.json ] && echo 0 || echo 1)
# 20 EXPECTED_* 하나라도 없음 → rc 2, RUN 폴더·API 호출 0
S=$T/s20; base_state $S; R=$T/r20; E_CTX= go $S link $R; rc=$?
check "20 missing EXPECTED_CONTEXT: rc2, no RUN, no call" $([ $rc = 2 ] && [ ! -e $R ] && [ "$(npatch $S)" = 0 ] && "$PY" -c 'import json,sys; sys.exit(0 if not json.load(open(sys.argv[1])).get("calls") else 1)' $S && echo 0 || echo 1)
# 21 조회 뒤 다른 셸이 current-context를 다른 클러스터로 전환 → 고정 대상(api.mock)만 호출, 다른 클러스터 변경 0
S=$T/s21; base_state $S; add_other $S; edit $S 'st["switch_current_after_reads"]=1'; R=$T/r21; go $S link $R; rc=$?
check "21 current-context switched mid-run: pinned target only" $([ $rc = 0 ] && [ "$(npatch_srv $S https://api.mock:443)" = 2 ] && [ "$(npatch_srv $S https://api.other.invalid:443)" = 0 ] && [ "$(unpinned $S)" = 0 ] && echo 0 || echo 1)
# 22 조회 뒤 승인 context 이름 자체가 다른 클러스터로 재지정 → patch 직전 STOP, patch 0
S=$T/s22; base_state $S; add_other $S; edit $S 'st["repoint_after_reads"]=2'; R=$T/r22; go $S link $R; rc=$?
check "22 approved context re-pointed after lookup: STOP before patch, patch 0" $([ $rc != 0 ] && [ "$(npatch $S)" = 0 ] && [ ! -e $R/intent-transaction-api-sa.json ] && grep -q 'context→server changed' $R/ledger.txt && echo 0 || echo 1)
# 23 정상 link 뒤 current-context 전환 상태에서 revert → 고정 대상만 원복, 모든 호출 고정
S=$T/s23; base_state $S; add_other $S; R=$T/r23; go $S link $R; edit $S 'st["kube"]["current"]="other-ctx"'; go $S revert $R; rc=$?
check "23 revert with switched current-context: pinned target restored" $([ $rc = 0 ] && eq "$(pulls $S transaction-api-sa)$(pulls $S fds-engine-sa)" '["transaction-api-sa-dockercfg-abc"][]' && [ "$(npatch_srv $S https://api.other.invalid:443)" = 0 ] && [ "$(unpinned $S)" = 0 ] && echo 0 || echo 1)
# 24 revert를 다른 EXPECTED_SECRET_UID로 실행 → ACK와 불일치 STOP, revert patch 0
S=$T/s24; base_state $S; R=$T/r24; go $S link $R; n=$(npatch $S); E_SEC=sec-WRONG go $S revert $R; rc=$?
check "24 revert with wrong EXPECTED_SECRET_UID: refused" $([ $rc != 0 ] && [ "$(npatch $S)" = "$n" ] && echo 0 || echo 1)
# 25 전체 정상 경로의 모든 API 호출이 고정 context·server·TLS 검증으로 나감
check "25 all calls pinned in normal link+revert (case 01)" $([ "$(unpinned $T/s1)" = 0 ] && echo 0 || echo 1)

[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAIL"
exit $fail
