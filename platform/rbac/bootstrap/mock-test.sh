#!/usr/bin/env bash
# bootstrap-session.sh MOCK 시험 — 가짜 rosa/oc 로 클라우드·비밀 파일 조작 없이 제어 흐름만 확인.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat >"$T/bin/rosa" <<'EOF'
#!/usr/bin/env bash
echo "rosa $*" >>"$MOCK_LOG"
case "$1 $2" in
  "grant user")  exit 0 ;;
  "revoke user") exit "${MOCK_REVOKE_RC:-0}" ;;
  "list users")  [[ "${MOCK_STILL_ADMIN:-0}" == 1 ]] && echo "hayeoung  cluster-admins"; exit 0 ;;
esac
exit 0
EOF
cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
echo "oc $*" >>"$MOCK_LOG"
[[ "$1 $2" == "auth can-i" ]] && exit "${MOCK_CANI_RC:-1}"   # 1 = no
exit 0
EOF
chmod +x "$T/bin/rosa" "$T/bin/oc"

mk_steps() { # $1 name, $2 body
  printf 'run_steps() {\n%s\n}\n' "$2" >"$T/$1.sh"
}
mk_steps normal   'echo STEP1 >>"$MOCK_LOG"; echo STEP2 >>"$MOCK_LOG"'
mk_steps fail     'echo STEP1 >>"$MOCK_LOG"; false; echo STEP2_AFTER_FAIL >>"$MOCK_LOG"'
mk_steps int      'echo STEP1 >>"$MOCK_LOG"; kill -INT $$; sleep 1; echo STEP2_AFTER_INT >>"$MOCK_LOG"'
mk_steps term     'echo STEP1 >>"$MOCK_LOG"; kill -TERM $$; sleep 1; echo STEP2_AFTER_TERM >>"$MOCK_LOG"'
mk_steps deadline 'echo STEP1 >>"$MOCK_LOG"; for i in 1 2 3 4 5 6; do sleep 1; done; echo STEP2_AFTER_DEADLINE >>"$MOCK_LOG"'

run_case() { # name steps expect_rc [env...]
  local name=$1 steps=$2 expect=$3; shift 3
  local log="$T/$name.log"; : >"$log"
  local dl=$(( $(date +%s) + 600 ))
  [[ "$steps" == deadline ]] && dl=$(( $(date +%s) + 2 ))
  env PATH="$T/bin:$PATH" MOCK_LOG="$log" HOME="$T/home-$name" \
      CLUSTER_ID=mock-id API_URL=https://api.mock:443 DEADLINE_EPOCH="$dl" \
      VERIFY_TRIES=2 VERIFY_INTERVAL=0 "$@" \
      bash "$HERE/bootstrap-session.sh" "$T/$steps.sh" 2>"$T/$name.err"
  local rc=$?
  local after; after=$(grep -c '_AFTER_' "$log" || true)
  local revoked; revoked=$(grep -c '^rosa revoke' "$log" || true)
  local cr; cr=$(grep -c 'CLEANUP_REQUIRED' "$T/$name.err" || true)
  local perm; perm=$(stat -c '%a' "$T/home-$name/rosa-idp" 2>/dev/null || echo NA)
  local ok=PASS; [[ $rc == "$expect" && $after == 0 && $revoked == 1 ]] || ok=FAIL
  printf '%-22s rc=%-3s expect=%-3s after_step_runs=%s revoke_calls=%s CLEANUP_REQUIRED=%s dir_perm=%s => %s\n' \
    "$name" "$rc" "$expect" "$after" "$revoked" "$cr" "$perm" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s)"
run_case 1_normal          normal   0
run_case 2_step_fail       fail     1
run_case 3_int             int      130
run_case 4_term            term     143
run_case 5_deadline        deadline 143
run_case 6_revoke_fail     normal   1 MOCK_REVOKE_RC=42
run_case 7_verify_timeout  normal   1 MOCK_STILL_ADMIN=1
run_case 8_verify_cani_yes normal   1 MOCK_CANI_RC=0
run_case 9_int_and_revoke_fail int  1 MOCK_REVOKE_RC=42

# 10: 로그를 파이프(tee)로 받을 때 watchdog 가 파이프를 붙잡지 않는지(마감 600초인데 즉시 끝나야 함)
: >"$T/10.log"; start=$(date +%s)
env PATH="$T/bin:$PATH" MOCK_LOG="$T/10.log" HOME="$T/home-10" CLUSTER_ID=mock-id API_URL=https://api.mock:443 \
    DEADLINE_EPOCH=$(( $(date +%s) + 600 )) VERIFY_TRIES=2 VERIFY_INTERVAL=0 \
    bash "$HERE/bootstrap-session.sh" "$T/normal.sh" 2>&1 | tee "$T/10.out" >/dev/null
rc=${PIPESTATUS[0]}; el=$(( $(date +%s) - start ))
printf '%-22s rc=%-3s elapsed=%ss (deadline 600s) => %s\n' 10_pipe_no_hang "$rc" "$el" \
  "$([[ $rc == 0 && $el -lt 20 ]] && echo PASS || echo FAIL)"
