#!/usr/bin/env bash
# Self-contained TAP-style tests for finalize.sh. No network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINALIZE="$SCRIPT_DIR/../finalize.sh"
REAL_GIT="$(command -v git)"
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
assert_contains() {
  if grep -qF "$3" "$2"; then ok "$1"; else fail "$1 (missing [$3])"; fi
}

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WT="$BASE/repair"; REMOTE="$BASE/remote.git"; BIN="$BASE/bin"; LOG="$BASE/actions.log"
mkdir -p "$REPO" "$BIN"
"$REAL_GIT" init -q --bare "$REMOTE"
"$REAL_GIT" -C "$REPO" init -q
"$REAL_GIT" -C "$REPO" config user.email test@example.com
"$REAL_GIT" -C "$REPO" config user.name Test
"$REAL_GIT" -C "$REPO" commit --allow-empty -qm init
"$REAL_GIT" -C "$REPO" branch -M main
"$REAL_GIT" -C "$REPO" remote add origin "$REMOTE"
"$REAL_GIT" -C "$REPO" worktree add -qb agent/26-repair "$WT"
INSPECTED_HEAD="$("$REAL_GIT" -C "$WT" rev-parse HEAD)"
printf 'repair\n' > "$WT/change.txt"
"$REAL_GIT" -C "$WT" add change.txt
"$REAL_GIT" -C "$WT" commit -qm repair
REPAIR_HEAD="$("$REAL_GIT" -C "$WT" rev-parse HEAD)"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$ACTION_LOG"
if [ "$1 $2 $3" = "pr view 44" ]; then
  jq -n --arg head "${STUB_BRANCH:-agent/26-repair}" '{headRefName:$head}'
else
  echo "unexpected gh call: $*" >&2
  exit 91
fi
SH
chmod +x "$BIN/gh"

cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = push ]; then
  printf 'git %s\n' "$*" >> "$ACTION_LOG"
  if [ "${FAIL_PUSH:-0}" = 1 ]; then echo "simulated push rejection" >&2; exit 42; fi
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$BIN/git"

write_evidence() {
  jq -n --arg status "${1:-success}" --arg command "${2-npm test}" --arg result "${3-42 tests passed}" \
    '{status:$status,command:$command,result:$result}' > "$BASE/verification.json"
}

run_case() {
  local name="$1"; shift
  : > "$LOG"
  (cd "${CASE_CWD:-$WT}" && PATH="$BIN:$PATH" REAL_GIT="$REAL_GIT" ACTION_LOG="$LOG" "$FINALIZE" "$@") \
    >"$BASE/$name.out" 2>"$BASE/$name.err"
  CASE_RC=$?
}

reject_case() {
  local name="$1" message="$2"; shift 2
  run_case "$name" "$@"
  assert_eq "$name: rejected" 1 "$CASE_RC"
  assert_contains "$name: useful error" "$BASE/$name.err" "$message"
  if grep -q '^git push ' "$LOG"; then fail "$name: no push"; else ok "$name: no push"; fi
  if grep -Eiq 'gh .*(create|edit|comment|label|ready|review|approve|merge)|git worktree (add|remove)' "$LOG"; then
    fail "$name: forbidden actions absent"
  else
    ok "$name: forbidden actions absent"
  fi
}

write_evidence success
run_case success 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "success: exits zero" 0 "$CASE_RC"
assert_eq "success: pushes repair head" "$REPAIR_HEAD" "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/agent/26-repair)"
assert_contains "success: reports pushed ref" "$BASE/success.out" "agent/26-repair"

write_evidence failure
run_case verification-failure 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "verification failure: nonzero" 1 "$CASE_RC"
assert_contains "verification failure: useful error" "$BASE/verification-failure.err" "verification evidence"
if grep -q '^git push ' "$LOG"; then fail "verification failure: no push"; else ok "verification failure: no push"; fi

write_evidence success
FAIL_PUSH=1 run_case push-failure 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "push failure: preserves exit status" 42 "$CASE_RC"
assert_contains "push failure: useful output" "$BASE/push-failure.err" "simulated push rejection"

if grep -Eiq 'gh .*(create|edit|comment|label|ready|review|approve|merge)|git worktree (add|remove)' "$LOG"; then
  fail "forbidden actions: absent"
else
  ok "forbidden actions: absent"
fi

reject_case bad-issue "invalid issue-number" nope 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
reject_case bad-pr "invalid pr-number" 26 nope "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
reject_case nonexistent-worktree "worktree does not exist" 26 44 "$INSPECTED_HEAD" agent/26-repair "$BASE/missing" "$BASE/verification.json"
reject_case wrong-branch "worktree/branch identity" 26 44 "$INSPECTED_HEAD" agent/26-other "$WT" "$BASE/verification.json"
CASE_CWD="$REPO" reject_case wrong-cwd "exact worktree" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
STUB_BRANCH=agent/26-changed reject_case changed-pr-branch "head branch changed" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
reject_case missing-inspected-head "inspected head is not a commit" 26 44 deadbeef agent/26-repair "$WT" "$BASE/verification.json"
reject_case same-inspected-head "at least one new commit" 26 44 "$REPAIR_HEAD" agent/26-repair "$WT" "$BASE/verification.json"

printf 'main advance\n' > "$REPO/main.txt"
"$REAL_GIT" -C "$REPO" add main.txt
"$REAL_GIT" -C "$REPO" commit -qm 'main advance'
NON_DESCENDANT="$("$REAL_GIT" -C "$REPO" rev-parse HEAD)"
reject_case non-descendant-head "not an ancestor" 26 44 "$NON_DESCENDANT" agent/26-repair "$WT" "$BASE/verification.json"

printf 'dirty\n' >> "$WT/change.txt"
reject_case dirty-tracked "tracked worktree changes" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
"$REAL_GIT" -C "$WT" restore change.txt

printf '{broken}\n' > "$BASE/verification.json"
reject_case malformed-evidence "verification evidence" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
write_evidence success '' '42 tests passed'
reject_case empty-command "verification evidence" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
write_evidence success 'npm test' ''
reject_case empty-result "verification evidence" 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
