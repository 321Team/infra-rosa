#!/usr/bin/env bash
# issue_receipt() 단위 시험(오프라인, jq 불필요). 하나라도 FAIL 이면 rc1.
# bootstrap-session.sh 의 실제 sha_of·issue_receipt 를 그대로 추출해, receipt 의 4번 쓰기를 하나씩 실패시킨다.
# 리뷰 5542174606 R3: 첫/중간/마지막 쓰기 실패 각각 rc1 + receipt·tmp 없음, 정상은 완성 receipt.
# 'b' 대조는 && 를 뺀 수정 전 묶음이 앞쪽 실패를 덮어 완료 receipt 를 만들었음을 보여 준다.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# 실제 함수 추출: sha_of() 부터 issue_receipt() 가 닫히는 '}' 까지
awk '/^sha_of\(\) \{/ { on = 1 } on { print } on && /^issue_receipt\(\) \{/ { inr = 1 } inr && /^\}/ { exit }' \
  "$HERE/bootstrap-session.sh" >"$T/fn.sh"
grep -q '^issue_receipt() {' "$T/fn.sh" || { echo "FAIL: issue_receipt 추출 실패"; exit 1; }
# 수정 전 사본: 묶음 안 줄 끝의 && 제거
perl -pe 's/^(    printf .*) &&$/$1/' "$T/fn.sh" >"$T/fn-old.sh"
fail=0
cmp -s "$T/fn.sh" "$T/fn-old.sh" && { echo "FAIL: 대조 사본이 원본과 같음(치환 실패)"; fail=1; }

run() { # name fnfile fail_key expect_rc expect_receipt(yes|no)
  local name=$1 fn=$2 key=$3 erc=$4 erec=$5
  local ev="$T/$name"; mkdir -p "$ev/10b-inventory"
  echo k >"$ev/kubeconfig"; echo t >"$ev/00-target.env"; echo u >"$ev/05-ns-uid.txt"
  echo s >"$ev/10b-inventory/SHA256SUMS"; echo r >"$ev/10b-path-review.tsv"
  local rc
  (
    log() { echo "$*" >&2; }
    # 지정한 receipt 줄의 printf 만 실패(rc42). sha_of 등 다른 printf 는 그대로.
    printf() { if [[ -n "$FAIL_KEY" && "${1:-}" == "$FAIL_KEY"* ]]; then return 42; fi; builtin printf "$@"; }
    FAIL_KEY=$key EV=$ev KUBECONFIG=$ev/kubeconfig CLUSTER_ID=mock-id API_URL=https://api.mock:443 U=hayeoung
    source "$fn"
    issue_receipt 0
  ) 2>"$T/$name.err"
  rc=$?
  local rec=no; [[ -e "$ev/99-receipt.env" ]] && rec=yes
  local tmp=no; [[ -e "$ev/99-receipt.env.tmp" ]] && tmp=yes
  local lines=0; [[ $rec == yes ]] && lines=$(grep -c '=' "$ev/99-receipt.env")
  local ok=PASS
  [[ $rc == "$erc" && $rec == "$erec" && $tmp == no ]] || ok=FAIL
  [[ $erec == yes && $rec == yes && $lines != 12 && $erc == 0 && -z "$key" ]] && ok=FAIL   # 정상 receipt 는 12개 항목
  [[ "$ok" == PASS ]] || fail=1
  printf '%-28s rc=%-2s expect=%-2s receipt=%-3s tmp_left=%-3s lines=%-2s => %s\n' "$name" "$rc" "$erc" "$rec" "$tmp" "$lines" "$ok"
}

echo "bash $BASH_VERSION / $(uname -s)"
run R0_normal          "$T/fn.sh"     ""                    0 yes
run R1_write1_fail     "$T/fn.sh"     "RECEIPT_VERSION"     1 no
run R2_write2_fail     "$T/fn.sh"     "CLUSTER_ID="         1 no
run R3_write3_fail     "$T/fn.sh"     "OLD_KUBECONFIG"      1 no
run R4_write4_fail     "$T/fn.sh"     "INVENTORY_SUMS"      1 no
# 대조: 수정 전에는 앞쪽 3개 실패가 덮여 rc0·불완전 receipt 확정, 마지막 실패만 멈춤
run R1b_old_write1     "$T/fn-old.sh" "RECEIPT_VERSION"     0 yes
run R2b_old_write2     "$T/fn-old.sh" "CLUSTER_ID="         0 yes
run R3b_old_write3     "$T/fn-old.sh" "OLD_KUBECONFIG"      0 yes
run R4b_old_write4     "$T/fn-old.sh" "INVENTORY_SUMS"      1 no
exit "$fail"
