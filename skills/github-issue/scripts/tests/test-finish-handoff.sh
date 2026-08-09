#!/usr/bin/env bash
# Tests for scripts/finish-handoff.sh (Phase 6 label-driven handoff).
#
# Self-contained: stubs `gh` on PATH, logs every invocation to $GH_LOG,
# asserts exit code and the exact set of gh calls made. No test framework,
# no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF="$SCRIPT_DIR/../finish-handoff.sh"
SENTINEL='ghs_SENTINEL_APP_TOKEN_MUST_NOT_LEAK'

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
if [ "${GH_TOKEN-}" != "$SENTINEL_TOKEN" ]; then exit 4; fi
if [ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]]; then
  exit 1
fi
case "$1 $2" in
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
  (cd "$REPO_DIR" && PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" \
    GH_APP_TOKEN_HELPER="$APP_TOKEN_HELPER" SENTINEL_TOKEN="$SENTINEL" \
    STUB_ISSUE_LABELS="${STUB_ISSUE_LABELS:-}" STUB_PR_LABELS="${STUB_PR_LABELS:-}" \
    FAIL_ON="${FAIL_ON:-}" \
    "$HANDOFF" "$pr" "$issue")
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  REPO_DIR="$BASE/repo"
  APP_TOKEN_HELPER="$BASE/gh-app-token.sh"
  mkdir -p "$STUBBIN"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" remote add origin https://github.com/testowner/testrepo.git
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$SENTINEL_TOKEN"' > "$APP_TOKEN_HELPER"
  chmod +x "$APP_TOKEN_HELPER"
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

# --- Case 1c: manual run with unrelated labels already present — proves
# the manual branch is genuinely label-blind (makes zero label calls),
# not just untested in the presence of labels. ---
test_case1c_manual_with_labels_present() {
  new_fixture
  STUB_ISSUE_LABELS="bug,agent-implementing" run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case1c: exits zero on manual path" 0 "$rc"
  assert_contains "case1c: pr ready called" "$GH_LOG" "pr ready 30"
  assert_not_contains "case1c: no add-label calls" "$GH_LOG" "add-label"
  assert_not_contains "case1c: no remove-label calls" "$GH_LOG" "remove-label"
}

test_case1c_manual_with_labels_present

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

# --- Case 2c: managed run, issue has an unrelated non-agent-* label — the
# stray-removal loop must leave it alone; only agent-* phase labels (other
# than agent-running/agent-review) are strays. ---
test_case2c_leaves_unrelated_label_alone() {
  new_fixture
  STUB_ISSUE_LABELS="agent-running,agent-implementing,bug" STUB_PR_LABELS="" \
    run_handoff 31 31 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case2c: exits zero on managed path" 0 "$rc"
  assert_contains "case2c: agent-* stray still removed from issue" "$GH_LOG" "issue edit 31 --remove-label agent-implementing"
  assert_not_contains "case2c: unrelated non-agent-* label left alone" "$GH_LOG" "remove-label bug"
}

test_case2c_leaves_unrelated_label_alone

test_case3_managed_pr_stray_label

# --- Case 4: rerun — running the managed path twice is safe and repeats
# the same calls (gh's label add/remove are idempotent, so no bespoke
# state tracking is needed in the script itself). ---
test_case4_rerun() {
  new_fixture
  STUB_ISSUE_LABELS="agent-running,agent-implementing" STUB_PR_LABELS="" \
    run_handoff 33 33 >"$BASE/out1.log" 2>&1
  local rc1=$?
  : > "$GH_LOG"
  STUB_ISSUE_LABELS="agent-running,agent-review" STUB_PR_LABELS="agent-running,agent-review" \
    run_handoff 33 33 >"$BASE/out2.log" 2>&1
  local rc2=$?
  assert_eq "case4: first run exits zero" 0 "$rc1"
  assert_eq "case4: rerun exits zero" 0 "$rc2"
  assert_contains "case4: rerun still adds agent-review to issue" "$GH_LOG" "issue edit 33 --add-label agent-review"
  assert_contains "case4: rerun still adds agent-review to PR" "$GH_LOG" "pr edit 33 --add-label agent-review"
  assert_not_contains "case4: rerun issues no remove-label calls (nothing stray on a converged rerun)" "$GH_LOG" "remove-label"
}

test_case4_rerun

# --- Case 5: partial failure — first call fails mid-way (simulated PR
# edit failure), script exits nonzero without reaching pr ready; rerun
# with the fault cleared completes cleanly. ---
test_case5_partial_failure() {
  new_fixture
  FAIL_ON="pr edit 34 --add-label agent-running" STUB_ISSUE_LABELS="agent-running" STUB_PR_LABELS="" \
    run_handoff 34 34 >"$BASE/out1.log" 2>&1
  local rc1=$?
  assert_eq "case5: first run fails at the injected fault" 1 "$rc1"
  assert_contains "case5: issue-side edit completes before the fault" "$GH_LOG" "issue edit 34 --add-label agent-review"
  assert_not_contains "case5: agent-review never added to PR before the fault clears" "$GH_LOG" "pr edit 34 --add-label agent-review"

  : > "$GH_LOG"
  STUB_ISSUE_LABELS="agent-running" STUB_PR_LABELS="" \
    run_handoff 34 34 >"$BASE/out2.log" 2>&1
  local rc2=$?
  assert_eq "case5: rerun with fault cleared exits zero" 0 "$rc2"
  assert_contains "case5: rerun completes agent-review on issue" "$GH_LOG" "issue edit 34 --add-label agent-review"
  assert_contains "case5: rerun completes agent-review on PR" "$GH_LOG" "pr edit 34 --add-label agent-review"
}

test_case5_partial_failure

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
