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
assert_not_contains() {
  if grep -qF "$3" "$2"; then fail "$1 (unexpected [$3])"; else ok "$1"; fi
}
# Compares a captured token without ever echoing it: a mismatch here can hold a
# real short-lived App token, which must not reach the test output.
assert_token() {
  local desc="$1" expected="$2" actual; actual="$(cat "$3")"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  elif [ -z "$actual" ]; then fail "$desc (no token delivered)"
  else fail "$desc (delivered token differs from the expected stub value; value redacted)"; fi
}

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WT="$BASE/repair"; REMOTE="$BASE/remote.git"; BIN="$BASE/bin"; LOG="$BASE/actions.log"
TOKEN_SINK="$BASE/token-sink"; HELPER_LOG="$BASE/helper.log"
# A token value distinctive enough that any leak into output is unambiguous.
SENTINEL='ghs_SENTINEL_APP_TOKEN_MUST_NOT_LEAK'
mkdir -p "$REPO" "$BIN"
"$REAL_GIT" init -q --bare "$REMOTE"
"$REAL_GIT" -C "$REPO" init -q
"$REAL_GIT" -C "$REPO" config user.email test@example.com
"$REAL_GIT" -C "$REPO" config user.name Test
"$REAL_GIT" -C "$REPO" commit --allow-empty -qm init
"$REAL_GIT" -C "$REPO" branch -M main
"$REAL_GIT" -C "$REPO" remote add origin https://github.com/test/repo.git
"$REAL_GIT" -C "$REPO" remote set-url --push origin "$REMOTE"
"$REAL_GIT" -C "$REPO" worktree add -qb agent/26-repair "$WT"
INSPECTED_HEAD="$("$REAL_GIT" -C "$WT" rev-parse HEAD)"
printf 'repair\n' > "$WT/change.txt"
"$REAL_GIT" -C "$WT" add change.txt
"$REAL_GIT" -C "$WT" commit -qm repair
REPAIR_HEAD="$("$REAL_GIT" -C "$WT" rev-parse HEAD)"

# Stub App-token helper: stands in for /opt/agent-devcontainer/gh-app-token.sh.
cat > "$BASE/gh-app-token.sh" <<'SH'
#!/usr/bin/env bash
printf 'GITHUB_APP_REPO=%s\n' "${GITHUB_APP_REPO-<unset>}" >> "$HELPER_LOG"
printf '%s\n' "$SENTINEL_TOKEN"
SH
chmod +x "$BASE/gh-app-token.sh"

cat > "$BASE/failing-helper.sh" <<'SH'
#!/usr/bin/env bash
exit 23
SH
chmod +x "$BASE/failing-helper.sh"

# Stub gh. `pr view` demands credentials the way real `gh` does — either a
# GH_TOKEN in its environment or a logged-in host — so an unauthenticated
# finalizer reproduces the reported failure instead of silently passing.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$ACTION_LOG"
printf '%s' "${GH_TOKEN-}" >> "$TOKEN_SINK"
if [ -z "${GH_TOKEN-}" ] && [ "${STUB_GH_LOGGED_IN:-0}" != 1 ]; then
  echo "To get started with GitHub CLI, please run: gh auth login" >&2
  exit 4
fi
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
  if [ "${ADVANCE_HEAD_AT_PUSH:-0}" = 1 ]; then
    "$REAL_GIT" commit --allow-empty -qm 'concurrent branch advance'
    "$REAL_GIT" rev-parse HEAD > "$ADVANCED_HEAD_FILE"
  fi
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$BIN/git"

write_evidence() {
  jq -n --arg status "${1:-success}" --arg command "${2-npm test}" --arg result "${3-42 tests passed}" \
    '{status:$status,command:$command,result:$result}' > "$BASE/verification.json"
}

# Cases default to the devcontainer environment: the App-token helper is
# present and the host has no `gh auth login`. CASE_HELPER/CASE_LOGGED_IN can
# simulate a missing helper and a logged-in user. The helper path is always set, so a test run
# never reaches the real /opt helper or mints a real token.
run_case() {
  local name="$1"; shift
  : > "$LOG"; : > "$TOKEN_SINK"; : > "$HELPER_LOG"
  (cd "${CASE_CWD:-$WT}" && PATH="$BIN:$PATH" REAL_GIT="$REAL_GIT" ACTION_LOG="$LOG" \
    TOKEN_SINK="$TOKEN_SINK" HELPER_LOG="$HELPER_LOG" SENTINEL_TOKEN="$SENTINEL" \
    GH_APP_TOKEN_HELPER="${CASE_HELPER:-$BASE/gh-app-token.sh}" \
    STUB_GH_LOGGED_IN="${CASE_LOGGED_IN:-0}" \
    "$FINALIZE" "$@") \
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

# --- success in the devcontainer: the App helper supplies the token, and the
# caller exports no GH_TOKEN of its own ---
write_evidence success
run_case success 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "success: exits zero" 0 "$CASE_RC"
assert_eq "success: pushes repair head" "$REPAIR_HEAD" "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/agent/26-repair)"
assert_contains "success: reports pushed ref" "$BASE/success.out" "agent/26-repair"
assert_token "success: gh receives the minted App token" "$SENTINEL" "$TOKEN_SINK"
assert_contains "success: helper is scoped to the repo" "$HELPER_LOG" "GITHUB_APP_REPO=test/repo"
assert_not_contains "success: token absent from stdout" "$BASE/success.out" "$SENTINEL"
assert_not_contains "success: token absent from stderr" "$BASE/success.err" "$SENTINEL"
assert_not_contains "success: token absent from action log" "$LOG" "$SENTINEL"

# --- helper mint failure stops before gh or push, even with logged-in gh ---
"$REAL_GIT" --git-dir="$REMOTE" update-ref -d refs/heads/agent/26-repair
write_evidence success
CASE_HELPER="$BASE/failing-helper.sh" CASE_LOGGED_IN=1 \
  run_case helper-failure 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "helper failure: preserves failure" 23 "$CASE_RC"
assert_contains "helper failure: useful error" "$BASE/helper-failure.err" "failed to mint"
assert_eq "helper failure: gh never invoked" "" "$(cat "$LOG")"
assert_token "helper failure: no token injected" "" "$TOKEN_SINK"
if "$REAL_GIT" --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/agent/26-repair; then
  fail "helper failure: no push"
else
  ok "helper failure: no push"
fi

# --- missing App helper fails closed even when the stub gh is logged in ---
write_evidence success
CASE_HELPER="$BASE/absent-helper.sh" CASE_LOGGED_IN=1 \
  run_case missing-helper-logged-in 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
assert_eq "missing helper logged in: exits nonzero" 1 "$CASE_RC"
assert_contains "missing helper logged in: directs user to setup" "$BASE/missing-helper-logged-in.err" "/setup"
assert_eq "missing helper logged in: gh never invoked" "" "$(cat "$LOG")"
assert_token "missing helper logged in: no token injected" "" "$TOKEN_SINK"
assert_eq "missing helper logged in: helper never invoked" "" "$(cat "$HELPER_LOG")"
if "$REAL_GIT" --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/agent/26-repair; then
  fail "missing helper logged in: no push"
else
  ok "missing helper logged in: no push"
fi

# --- neither credential available: fail loudly, never push a half-guarded repair ---
write_evidence success
CASE_HELPER="$BASE/absent-helper.sh" CASE_LOGGED_IN=0 \
  run_case unauthenticated 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
if [ "$CASE_RC" -ne 0 ]; then ok "unauthenticated: nonzero"; else fail "unauthenticated: nonzero"; fi
assert_contains "unauthenticated: directs user to setup" "$BASE/unauthenticated.err" "/setup"
assert_eq "unauthenticated: gh never invoked" "" "$(cat "$LOG")"
if grep -q '^git push ' "$LOG"; then fail "unauthenticated: no push"; else ok "unauthenticated: no push"; fi

write_evidence success
ADVANCE_HEAD_AT_PUSH=1 ADVANCED_HEAD_FILE="$BASE/advanced-head" \
  run_case concurrent-movement 26 44 "$INSPECTED_HEAD" agent/26-repair "$WT" "$BASE/verification.json"
ADVANCED_HEAD="$(cat "$BASE/advanced-head")"
assert_eq "concurrent movement: exits zero after publishing validated object" 0 "$CASE_RC"
assert_eq "concurrent movement: publishes validated object" "$REPAIR_HEAD" "$("$REAL_GIT" --git-dir="$REMOTE" rev-parse refs/heads/agent/26-repair)"
if [ "$ADVANCED_HEAD" != "$REPAIR_HEAD" ]; then ok "concurrent movement: test advanced branch"; else fail "concurrent movement: test did not advance branch"; fi
assert_contains "concurrent movement: reports published object" "$BASE/concurrent-movement.out" "$REPAIR_HEAD"
"$REAL_GIT" -C "$WT" reset -q --hard "$REPAIR_HEAD"

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
