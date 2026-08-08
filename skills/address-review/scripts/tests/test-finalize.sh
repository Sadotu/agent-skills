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
  jq -n --arg status "${1:-success}" --arg command "npm test" --arg result "42 tests passed" \
    '{status:$status,command:$command,result:$result}' > "$BASE/verification.json"
}

run_case() {
  local name="$1"; shift
  : > "$LOG"
  (cd "$WT" && PATH="$BIN:$PATH" REAL_GIT="$REAL_GIT" ACTION_LOG="$LOG" "$FINALIZE" "$@") \
    >"$BASE/$name.out" 2>"$BASE/$name.err"
  CASE_RC=$?
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

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
