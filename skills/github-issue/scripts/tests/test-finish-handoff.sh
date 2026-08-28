#!/usr/bin/env bash
# Tests for scripts/finish-handoff.sh.
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

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
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

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  PR_TITLE="$BASE/pr-title"
  PR_LABELS="$BASE/pr-labels"
  REPO_DIR="$BASE/repo"
  APP_TOKEN_HELPER="$BASE/gh-app-token.sh"
  mkdir -p "$STUBBIN"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" remote add origin https://github.com/testowner/testrepo.git
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$SENTINEL_TOKEN"' > "$APP_TOKEN_HELPER"
  chmod +x "$APP_TOKEN_HELPER"
  : > "$GH_LOG"
  printf '%s\n' 'WIP: Fix flaky handoff reports' > "$PR_TITLE"
  printf '%s\n' 'agent-running' 'bug' > "$PR_LABELS"
  cat > "$STUBBIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ "${GH_TOKEN-}" != "$SENTINEL_TOKEN" ]; then exit 4; fi

case "$1 $2" in
  "pr view")
    [ "${GH_PR_VIEW_FAIL-}" != 1 ] || exit 5
    cat "$PR_TITLE"
    ;;
  "label create")
    [ "${GH_LABEL_CREATE_FAIL-}" != 1 ] || exit 6
    ;;
  "pr edit")
    [ "${GH_PR_EDIT_FAIL-}" != 1 ] || exit 7
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --title) printf '%s\n' "$2" > "$PR_TITLE"; shift 2 ;;
        --add-label) grep -qxF "$2" "$PR_LABELS" || printf '%s\n' "$2" >> "$PR_LABELS"; shift 2 ;;
        *) shift ;;
      esac
    done
    ;;
esac
SHIM
  chmod +x "$STUBBIN/gh"
}

run_handoff() {
  local pr="$1" issue="$2"
  (cd "$REPO_DIR" && PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" \
    GH_APP_TOKEN_HELPER="$APP_TOKEN_HELPER" SENTINEL_TOKEN="$SENTINEL" \
    PR_TITLE="$PR_TITLE" PR_LABELS="$PR_LABELS" \
    GH_PR_VIEW_FAIL="${GH_PR_VIEW_FAIL-}" GH_LABEL_CREATE_FAIL="${GH_LABEL_CREATE_FAIL-}" \
    GH_PR_EDIT_FAIL="${GH_PR_EDIT_FAIL-}" \
    "$HANDOFF" "$pr" "$issue")
}

test_label_handoff() {
  new_fixture
  run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "handoff exits zero" 0 "$rc"
  assert_eq "handoff strips one WIP prefix" "Fix flaky handoff reports" "$(<"$PR_TITLE")"
  assert_eq "handoff preserves labels and adds user review" $'agent-running\nbug\nuser-merge-review' "$(<"$PR_LABELS")"
  assert_contains "handoff reads the PR title" "$GH_LOG" "pr view 30 --json title -q .title"
  assert_contains "handoff creates the review label" "$GH_LOG" "label create user-merge-review"
  assert_contains "handoff edits title and adds review label" "$GH_LOG" "pr edit 30 --title Fix flaky handoff reports --add-label user-merge-review"
  assert_not_contains "handoff never marks the PR ready" "$GH_LOG" "pr ready 30"
}

test_rerun() {
  new_fixture
  run_handoff 31 31 >"$BASE/out1.log" 2>&1
  local rc1=$?
  : > "$GH_LOG"
  run_handoff 31 31 >"$BASE/out2.log" 2>&1
  local rc2=$?
  assert_eq "first run exits zero" 0 "$rc1"
  assert_eq "rerun exits zero" 0 "$rc2"
  assert_eq "rerun leaves the stripped title unchanged" "Fix flaky handoff reports" "$(<"$PR_TITLE")"
  assert_eq "rerun leaves the review label state unchanged" $'agent-running\nbug\nuser-merge-review' "$(<"$PR_LABELS")"
  assert_not_contains "rerun never marks the PR ready" "$GH_LOG" "pr ready 31"
}

test_edit_failure_after_tolerated_label_create_failure() {
  new_fixture
  GH_LABEL_CREATE_FAIL=1 GH_PR_EDIT_FAIL=1 run_handoff 32 32 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "required PR edit failure is returned after tolerated label create failure" 7 "$rc"
  assert_contains "label create was attempted" "$GH_LOG" "label create user-merge-review"
  assert_contains "PR edit was attempted after label create failure" "$GH_LOG" "pr edit 32 --title Fix flaky handoff reports --add-label user-merge-review"
}

test_view_failure() {
  new_fixture
  GH_PR_VIEW_FAIL=1 run_handoff 33 33 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "required PR view failure is returned" 5 "$rc"
  assert_not_contains "PR edit is not attempted after view failure" "$GH_LOG" "pr edit 33"
}

test_strips_doubled_wip_prefix() {
  new_fixture
  printf '%s\n' 'WIP: WIP: Double prefixed title' > "$PR_TITLE"
  run_handoff 34 34 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "handoff exits zero" 0 "$rc"
  assert_eq "handoff strips both WIP prefixes" "Double prefixed title" "$(<"$PR_TITLE")"
  assert_contains "handoff edits with the fully stripped title" "$GH_LOG" "pr edit 34 --title Double prefixed title --add-label user-merge-review"
}

test_label_handoff
test_rerun
test_edit_failure_after_tolerated_label_create_failure
test_view_failure
test_strips_doubled_wip_prefix

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
