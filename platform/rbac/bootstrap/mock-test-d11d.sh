#!/usr/bin/env bash
# README D-11d Bash 예시 시험(오프라인, 가짜 oc, jq 불필요). 하나라도 FAIL 이면 rc1.
# PR#43 리뷰 5566384887 B1: 실행 전 KUBECONFIG 상태(있음/없음)·기존 파일이 보존되고, 이번 임시 파일·폴더만 정리되는지.
# README 의 <!-- d11d-bash:start/end --> 사이 코드를 그대로 꺼내 실행한다(사본을 따로 두지 않음).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

awk '/<!-- d11d-bash:start -->/ { on = 1; next } /<!-- d11d-bash:end -->/ { on = 0 } on && !/^   ```/ { sub(/^   /, ""); print }' \
  "$HERE/README.md" | sed -e 's#<승인 API_URL>#https://api.mock:443#' -e 's#<본인 id>#gwonuk#' >"$T/d11d.sh"
grep -q 'check_can_i' "$T/d11d.sh" || { echo "FAIL: README 에서 D-11d 블록을 찾지 못함"; exit 1; }

cat >"$T/bin/oc" <<'EOF'
#!/usr/bin/env bash
m="${MOCK_D11D:-ok}"
case "$*" in
  "login "*)   [[ $m == loginfail ]] && { echo "error: login failed" >&2; exit 1; }
               echo "mock" >"$KUBECONFIG"; exit 0 ;;     # 실제 oc login 처럼 지정된 KUBECONFIG 에 기록
  "whoami")    [[ $m == wronguser ]] && { echo other; exit 0; }; echo gwonuk ;;
  "whoami --show-server") [[ $m == wrongserver ]] && { echo https://api.other:443; exit 0; }; echo https://api.mock:443 ;;
  "auth can-i get pods -n fds-app") echo yes ;;
  "auth can-i list nodes") [[ $m == canibad ]] && { echo yes; exit 0; }; echo no; exit 1 ;;
  "auth can-i "*) echo no; exit 1 ;;
  "logout") exit 0 ;;
esac
EOF
chmod +x "$T/bin/oc"

fail=0
run() { # name mode expect_rc prior(set|unset)
  local name=$1 mode=$2 erc=$3 prior=$4
  local tmpd="$T/tmp-$name"; mkdir -p "$tmpd"
  local p1="$T/p1-$name.kubeconfig"; echo "phase1-context" >"$p1"
  local before; before=$(sha256sum "$p1" | cut -d' ' -f1)
  local out
  out=$(
    export PATH="$T/bin:$PATH" TMPDIR="$tmpd" MOCK_D11D="$mode"
    if [[ $prior == set ]]; then export KUBECONFIG="$p1"; else unset KUBECONFIG; fi
    eval "$(cat "$T/d11d.sh")" >"$T/$name.out" 2>&1
    printf '%s|%s' "$(grep -o 'D-11d rc=[0-9]*' "$T/$name.out" | tail -1 | cut -d= -f2)" "${KUBECONFIG-UNSET}"
  )
  local rc=${out%%|*} after=${out#*|}
  local want_after; [[ $prior == set ]] && want_after="$p1" || want_after=UNSET
  local left; left=$(find "$tmpd" -mindepth 1 | wc -l)
  local p1ok=no; [[ "$(sha256sum "$p1" | cut -d' ' -f1)" == "$before" ]] && p1ok=yes
  local ok=PASS
  [[ $rc == "$erc" && $after == "$want_after" && $left == 0 && $p1ok == yes ]] || { ok=FAIL; fail=1; }
  printf '%-30s rc=%-2s expect=%-2s KUBECONFIG_after=%-7s tmp_left=%s phase1_file_unchanged=%s => %s\n' \
    "$name" "$rc" "$erc" "$([[ $after == UNSET ]] && echo UNSET || echo kept)" "$left" "$p1ok" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s)"
for prior in set unset; do
  run "B1_${prior}_normal"       ok          0 "$prior"
  run "B2_${prior}_login_fail"   loginfail   1 "$prior"
  run "B3_${prior}_wrong_user"   wronguser   1 "$prior"
  run "B4_${prior}_wrong_server" wrongserver 1 "$prior"
  run "B5_${prior}_cani_mismatch" canibad    1 "$prior"
done
exit "$fail"
