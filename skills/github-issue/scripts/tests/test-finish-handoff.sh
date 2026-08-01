#!/usr/bin/env bash
# Tests for scripts/finish-handoff.sh (Phase 6 label-driven handoff).
#
# Self-contained: stubs `gh` on PATH, logs every invocation to $GH_LOG,
# asserts exit code and the exact set of gh calls made. No test framework,
# no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF="$SCRIPT_DIR/../finish-handoff.sh"

PASS=0
FAIL=0
TMP_DIRS=()

cleanup_tmp() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc (expected [$expected], got [$actual])"; fi
}

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then ok "$desc"; else fail "$desc (missing [$pattern] in $file)"; fi
}

assert_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then fail "$desc (unexpectedly found [$pattern] in $file)"; else ok "$desc"; fi
}

# write_gh_shim <path> — fake `gh` that logs `$*` to $GH_LOG and, for label
# queries, prints one label name per line (matching what the real `gh`'s
# `-q '.labels[].name'` jq filter would produce). STUB_ISSUE_LABELS /
# STUB_PR_LABELS are comma-separated label names. FAIL_ON, if set, is a
# substring of the invocation that should make this call exit 1 (simulates
# partial failure).
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]]; then
  exit 1
fi
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "issue view")
    IFS=',' read -ra labels <<< "${STUB_ISSUE_LABELS:-}"
    for l in "${labels[@]}"; do
      [ -n "$l" ] && echo "$l"
    done
    ;;
  "pr view")
    IFS=',' read -ra labels <<< "${STUB_PR_LABELS:-}"
    for l in "${labels[@]}"; do
      [ -n "$l" ] && echo "$l"
    done
    ;;
  *)
    :
    ;;
esac
SHIM
  chmod +x "$1"
}

# run_handoff <pr> <issue> — invokes finish-handoff.sh with the stubbed
# `gh` ahead on PATH.
run_handoff() {
  local pr="$1" issue="$2"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" STUB_REPO="testowner/testrepo" \
    STUB_ISSUE_LABELS="${STUB_ISSUE_LABELS:-}" STUB_PR_LABELS="${STUB_PR_LABELS:-}" \
    FAIL_ON="${FAIL_ON:-}" \
    "$HANDOFF" "$pr" "$issue"
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  write_gh_shim "$STUBBIN/gh"
}

# --- Case 1: manual run (no agent-running on the issue) ---
test_case1_manual() {
  new_fixture
  STUB_ISSUE_LABELS="" run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case1: exits zero on manual path" 0 "$rc"
  assert_contains "case1: pr ready called" "$GH_LOG" "pr ready 30"
  assert_not_contains "case1: no add-label calls" "$GH_LOG" "add-label"
  assert_not_contains "case1: no remove-label calls" "$GH_LOG" "remove-label"
}

test_case1_manual

# --- Case 1b: managed run (agent-running present on the issue) ---
# The managed branch is fully implemented and succeeds on a managed run, so
# this proves detection: the script must branch away from the manual path
# (exit zero, no `gh pr ready` call) rather than taking the manual path.
test_case1b_detects_managed_signal() {
  new_fixture
  STUB_ISSUE_LABELS="agent-running" run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case1b: exits zero on managed path" 0 "$rc"
  assert_not_contains "case1b: pr ready never called" "$GH_LOG" "pr ready"
}

test_case1b_detects_managed_signal

# --- Case 2: managed run (issue has agent-running + a stray phase label) ---
test_case2_managed() {
  new_fixture
  STUB_ISSUE_LABELS="agent-running,agent-implementing" STUB_PR_LABELS="" \
    run_handoff 31 31 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case2: exits zero on managed path" 0 "$rc"
  assert_not_contains "case2: pr ready never called" "$GH_LOG" "pr ready"
  assert_contains "case2: agent-review label ensured to exist" "$GH_LOG" "label create agent-review"
  assert_contains "case2: stray phase label removed from issue" "$GH_LOG" "issue edit 31 --remove-label agent-implementing"
  assert_contains "case2: agent-review added to issue" "$GH_LOG" "issue edit 31 --add-label agent-review"
  assert_not_contains "case2: agent-running never removed from issue" "$GH_LOG" "issue edit 31 --remove-label agent-running"
  assert_contains "case2: agent-running added to PR" "$GH_LOG" "pr edit 31 --add-label agent-running"
  assert_contains "case2: agent-review added to PR" "$GH_LOG" "pr edit 31 --add-label agent-review"
}

# --- Case 3: managed run, PR already carries a stray phase label too ---
test_case3_managed_pr_stray_label() {
  new_fixture
  STUB_ISSUE_LABELS="agent-running" STUB_PR_LABELS="agent-implementing" \
    run_handoff 32 32 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case3: exits zero" 0 "$rc"
  assert_contains "case3: stray phase label removed from PR" "$GH_LOG" "pr edit 32 --remove-label agent-implementing"
  assert_contains "case3: agent-review added to PR" "$GH_LOG" "pr edit 32 --add-label agent-review"
}

test_case2_managed
test_case3_managed_pr_stray_label

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
