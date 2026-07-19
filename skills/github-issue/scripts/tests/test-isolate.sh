#!/usr/bin/env bash
# Tests for scripts/isolate.sh (Phase 2: "Synchronize and Isolate").
#
# Self-contained: builds disposable temp git repos (a bare "origin" plus a
# working clone standing in for the primary worktree) per case, runs
# isolate.sh against them with a stubbed `gh`, and asserts exit code /
# stderr / resulting repo state. No test framework, no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISOLATE="$SCRIPT_DIR/../isolate.sh"

PASS=0
FAIL=0
TMP_DIRS=()

cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "ok - $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "not ok - $1"
}

assert_true() {
  # assert_true <description> <command...>
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

assert_eq() {
  # assert_eq <description> <expected> <actual>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$desc"
  else
    fail "$desc (expected [$expected], got [$actual])"
  fi
}

write_gh_shim() {
  # write_gh_shim <path> — a fake `gh` that logs its invocation to $GH_LOG
  # and returns canned output. Never touches the network.
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    printf '{"state":"%s","headRefName":"%s"}\n' \
      "${STUB_PR_STATE:-OPEN}" "${STUB_PR_HEAD_REF:-agent/0-x}"
    ;;
  "pr create")
    echo "https://example.invalid/pr/1"
    ;;
  "issue view")
    echo "${STUB_ISSUE_STATE:-OPEN}"
    ;;
  "issue close")
    :
    ;;
  *)
    :
    ;;
esac
SHIM
  chmod +x "$1"
}

# new_fixture sets: BASE ORIGIN CLONE STUBBIN GH_LOG APP_DIR_STUB
# CLONE stands in for the primary worktree, checked out on main, clean,
# in sync with ORIGIN.
new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  ORIGIN="$BASE/origin.git"
  CLONE="$BASE/clone"
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  APP_DIR_STUB="$BASE/no-app-creds"
  : > "$GH_LOG"

  git init -q --bare "$ORIGIN"
  git init -q "$CLONE"
  git -C "$CLONE" checkout -q -b main
  git -C "$CLONE" config user.email test@example.com
  git -C "$CLONE" config user.name "Test User"
  # This host's global git config wires a pre-push hook that blocks direct
  # pushes to main as a safety net for the real repo. It has no business
  # running against these disposable fixture repos, so disable it here.
  mkdir -p "$BASE/no-hooks"
  git -C "$CLONE" config core.hooksPath "$BASE/no-hooks"
  git -C "$CLONE" remote add origin "$ORIGIN"
  git -C "$CLONE" commit -q --allow-empty -m "initial commit"
  git -C "$CLONE" push -q -u origin main

  mkdir -p "$STUBBIN"
  write_gh_shim "$STUBBIN/gh"
}

# run_isolate <issue> <slug> <worktree-path> <pr-title>
# Invokes isolate.sh with cwd = $CLONE (the primary worktree), a stubbed
# `gh` ahead on PATH, and no real GitHub App credentials reachable (so the
# devcontainer token-mint path fails locally instead of hitting the network).
run_isolate() {
  (
    cd "$CLONE" || exit 99
    PATH="$STUBBIN:$PATH" \
    GH_LOG="$GH_LOG" \
    GITHUB_APP_DIR="$APP_DIR_STUB" \
    STUB_REPO="testowner/testrepo" \
    "$ISOLATE" "$@"
  )
}

# --- Case 1: dirty primary tree -> refuse, no worktree, nothing pushed ---
test_case1_dirty_primary_tree() {
  new_fixture
  echo "uncommitted" > "$CLONE/dirty.txt"
  local wt="$BASE/wt"

  run_isolate 1 dirty-tree "$wt" "Title" >"$BASE/out.log" 2>&1
  local rc=$?

  [ "$rc" -ne 0 ] && ok "case1: nonzero exit on dirty primary tree" \
    || fail "case1: nonzero exit on dirty primary tree (got rc=$rc)"
  assert_true "case1: no worktree directory created" [ ! -e "$wt" ]
  assert_true "case1: branch not pushed to origin" \
    bash -c "! git -C '$ORIGIN' show-ref --verify --quiet refs/heads/agent/1-dirty-tree"
}

# --- Case 2: local main diverged from origin/main -> refuse ---
test_case2_diverged_main() {
  new_fixture
  # Commit locally without pushing.
  git -C "$CLONE" commit -q --allow-empty -m "local-only commit"
  # Advance the fake origin independently via a second clone.
  local other="$BASE/other-clone"
  git clone -q "$ORIGIN" "$other"
  git -C "$other" config user.email test@example.com
  git -C "$other" config user.name "Test User"
  git -C "$other" config core.hooksPath "$BASE/no-hooks"
  git -C "$other" commit -q --allow-empty -m "origin-only commit"
  git -C "$other" push -q origin main
  local wt="$BASE/wt"

  run_isolate 2 diverged "$wt" "Title" >"$BASE/out.log" 2>&1
  local rc=$?

  [ "$rc" -ne 0 ] && ok "case2: nonzero exit when main has diverged from origin/main" \
    || fail "case2: nonzero exit when main has diverged from origin/main (got rc=$rc)"
  assert_true "case2: no worktree directory created" [ ! -e "$wt" ]
  assert_true "case2: branch not pushed to origin" \
    bash -c "! git -C '$ORIGIN' show-ref --verify --quiet refs/heads/agent/2-diverged"
}

# --- Case 3: current branch isn't main -> refuse ---
test_case3_not_on_main() {
  new_fixture
  git -C "$CLONE" checkout -q -b some-other-branch
  local wt="$BASE/wt"

  run_isolate 3 wrong-branch "$wt" "Title" >"$BASE/out.log" 2>&1
  local rc=$?

  [ "$rc" -ne 0 ] && ok "case3: nonzero exit when primary isn't on main" \
    || fail "case3: nonzero exit when primary isn't on main (got rc=$rc)"
  assert_true "case3: no worktree directory created" [ ! -e "$wt" ]
}

# --- Case 4: clean and ancestor -> full happy path ---
test_case4_happy_path() {
  new_fixture
  local wt="$BASE/wt"

  run_isolate 7 my-cool-slug "$wt" "My PR Title" >"$BASE/out.log" 2>&1
  local rc=$?

  assert_eq "case4: exits zero" 0 "$rc"
  assert_true "case4: local main fast-forwarded to origin/main" \
    bash -c "[ \"\$(git -C '$CLONE' rev-parse main)\" = \"\$(git -C '$CLONE' rev-parse origin/main)\" ]"
  assert_true "case4: worktree created at target path" [ -d "$wt" ]
  assert_true "case4: worktree is on branch agent/7-my-cool-slug" \
    bash -c "[ \"\$(git -C '$wt' branch --show-current)\" = agent/7-my-cool-slug ]"
  assert_eq "case4: worktree exactly one commit ahead of origin/main" 1 \
    "$(git -C "$wt" rev-list --count origin/main..HEAD)"
  assert_eq "case4: seed commit subject" "Start work on #7" \
    "$(git -C "$wt" log -1 --format=%s)"
  assert_true "case4: branch pushed to fake origin" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/agent/7-my-cool-slug"
  assert_true "case4: gh pr create was invoked" \
    bash -c "grep -q 'pr create' '$GH_LOG'"
  assert_true "case4: PR body contains the exact closing reference" \
    bash -c "grep -q 'Closes #7' '$GH_LOG'"
  assert_true "case4: PR title passed through" \
    bash -c "grep -q 'My PR Title' '$GH_LOG'"
}

test_case1_dirty_primary_tree
test_case2_diverged_main
test_case3_not_on_main
test_case4_happy_path

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
