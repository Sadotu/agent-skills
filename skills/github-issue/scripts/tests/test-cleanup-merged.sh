#!/usr/bin/env bash
# Tests for scripts/cleanup-merged.sh (Phase 7: "Post-Merge Cleanup").
#
# Self-contained: builds disposable temp git repos (a bare "origin", a
# primary clone standing in for $WORKSPACE, and a linked worktree standing
# in for the issue's worktree) per case, runs cleanup-merged.sh against
# them with a stubbed `gh`, and asserts exit code / stderr / resulting
# repo state. No test framework, no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$SCRIPT_DIR/../cleanup-merged.sh"
REAL_GIT="$(command -v git)"
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

assert_false() {
  # assert_false <description> <command...>
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$desc"
  else
    ok "$desc"
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

assert_record() {
  # assert_record <description> <field> <expected> — reads the single JSON
  # record the script writes to stdout.
  local desc="$1" field="$2" expected="$3" actual
  actual="$(jq -r --arg k "$field" '.[$k] // "null"' "$BASE/stdout.log" 2>/dev/null)"
  assert_eq "$desc" "$expected" "$actual"
}

assert_single_record() {
  # assert_single_record <description> — stdout carries exactly one line.
  assert_eq "$1" 1 "$(wc -l < "$BASE/stdout.log" | tr -d ' ')"
}

# Git invocations this workflow must never issue, whatever the state.
FORBIDDEN_GIT_PATTERNS=(
  'worktree remove .*(--force|-f)( |$)'
  '(^| )reset( |$)'
  '(^| )clean( |$)'
  'push .*(--force|--force-with-lease)( |$)'
  'push .* -f( |$)'
  'push .*\+refs'
  'branch .*-[dD] (main|master|develop|release/|hotfix/)'
  'push .*--delete (main|master|develop|release/|hotfix/)'
  'branch .*-[dD] [^ ]*\*'
  'push .*--delete [^ ]*\*'
)

assert_no_forbidden_git() {
  # assert_no_forbidden_git <description> — scans every git invocation the
  # script made in this fixture.
  local desc="$1" pattern hit=""
  for pattern in "${FORBIDDEN_GIT_PATTERNS[@]}"; do
    if grep -Eq -- "$pattern" "$GIT_CMD_LOG" 2>/dev/null; then
      hit="$pattern"
      break
    fi
  done
  if [ -z "$hit" ]; then
    ok "$desc"
  else
    fail "$desc (matched forbidden pattern [$hit])"
  fi
}

journal_path() {
  # journal_path <pr-number> — durable cleanup evidence for that PR.
  local pr="$1" common
  common="$(git -C "$CLONE" rev-parse --git-common-dir)"
  case "$common" in
    /*) ;;
    *) common="$CLONE/$common" ;;
  esac
  printf '%s\n' "$common/github-issue/cleanup/pr-${pr}.state"
}

write_gh_shim() {
  # write_gh_shim <path> — a fake `gh` that logs its invocation to $GH_LOG
  # and returns canned output. Never touches the network. Fails on demand
  # via $GH_FAIL_MATCH so tests can crash a run at a chosen boundary.
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ "${GH_TOKEN-}" != "$SENTINEL_TOKEN" ]; then
  echo "stub gh requires the expected App token" >&2
  exit 4
fi
if [ -n "${GH_FAIL_MATCH-}" ] && [[ "$*" == *"$GH_FAIL_MATCH"* ]]; then
  echo "injected gh failure" >&2
  exit 1
fi
case "$1 $2" in
  "pr view")
    printf '{"state":"%s","headRefName":"%s","mergeCommit":{"oid":"%s"}}\n' \
      "${STUB_PR_STATE:-OPEN}" "${STUB_PR_HEAD_REF:-agent/0-x}" "${STUB_PR_MERGE_COMMIT:-}"
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

# new_fixture sets: BASE ORIGIN CLONE STUBBIN GH_LOG APP_TOKEN_HELPER BRANCH WT
# CLONE stands in for $WORKSPACE (the primary worktree), on main, in sync
# with ORIGIN. WT is a linked worktree checked out on $BRANCH, with one
# commit ahead of origin/main and pushed to the fake origin — not yet
# merged into origin/main.
new_fixture() {
  local content=0 historical_docs=0
  while [ "${1:-}" = "--content" ] || [ "${1:-}" = "--historical-docs" ]; do
    case "$1" in
      --content) content=1 ;;
      --historical-docs) historical_docs=1 ;;
    esac
    shift
  done
  local issue="$1" slug="$2"
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  ORIGIN="$BASE/origin.git"
  CLONE="$BASE/clone"
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  GIT_NETWORK_LOG="$BASE/git-network.log"
  GIT_CMD_LOG="$BASE/git-cmd.log"
  APP_TOKEN_HELPER="$BASE/gh-app-token.sh"
  BRANCH="agent/${issue}-${slug}"
  WT="$BASE/wt"
  : > "$GH_LOG"
  : > "$GIT_NETWORK_LOG"
  : > "$GIT_CMD_LOG"

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
  if [ "$historical_docs" -eq 1 ]; then
    mkdir -p "$CLONE/docs/superpowers/specs" "$CLONE/docs/superpowers/plans"
    echo "historical design" > "$CLONE/docs/superpowers/specs/2025-01-01-historical-design.md"
    echo "historical plan" > "$CLONE/docs/superpowers/plans/2025-01-01-historical.md"
    git -C "$CLONE" add docs
    git -C "$CLONE" commit -q -m "preserve historical docs"
  fi
  git -C "$CLONE" push -q -u origin main

  git -C "$CLONE" worktree add -q -b "$BRANCH" "$WT" origin/main
  git -C "$WT" config user.email test@example.com
  git -C "$WT" config user.name "Test User"
  if [ "$content" -eq 1 ]; then
    echo "feature line" > "$WT/feature.txt"
    git -C "$WT" add feature.txt
    git -C "$WT" commit -q -m "Start work on #${issue}"
  else
    git -C "$WT" commit -q --allow-empty -m "Start work on #${issue}"
  fi
  git -C "$WT" push -q -u origin "$BRANCH"

  mkdir -p "$STUBBIN"
  write_gh_shim "$STUBBIN/gh"
  cat > "$STUBBIN/git" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-} ${2:-} ${3:-}" = "remote get-url origin" ]; then
  echo https://github.com/testowner/testrepo.git
  exit 0
fi
echo "$*" >> "$GIT_CMD_LOG"
if [ -n "${GIT_FAIL_MATCH-}" ] && [[ "$*" == *"$GIT_FAIL_MATCH"* ]]; then
  echo "injected git failure" >&2
  exit 1
fi
for arg in "$@"; do
  if [ "$arg" = fetch ] || [ "$arg" = push ] || [ "$arg" = ls-remote ]; then
    printf '%s:%s\n' "$arg" "${GIT_APP_TOKEN-}" >> "$GIT_NETWORK_LOG"
    break
  fi
done
rewritten=()
for arg in "$@"; do
  case "$arg" in
    https://github.com/testowner/testrepo.git) rewritten+=("$TEST_REMOTE_URL") ;;
    *) rewritten+=("$arg") ;;
  esac
done
unset GIT_ALLOW_PROTOCOL
exec "$REAL_GIT" "${rewritten[@]}"
SHIM
  chmod +x "$STUBBIN/git"
  cat > "$APP_TOKEN_HELPER" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$SENTINEL_TOKEN"
SHIM
  chmod +x "$APP_TOKEN_HELPER"
}

# merge_branch_into_origin_main fast-forwards local + remote main to
# include $BRANCH's tip, simulating the PR having actually landed.
merge_branch_into_origin_main() {
  git -C "$CLONE" fetch -q origin
  git -C "$CLONE" merge -q --ff-only "$BRANCH"
  git -C "$CLONE" push -q origin main
}

# push_direct_commit_to_main <file> <content> — commits <content> to
# <file> directly onto CLONE's main, bypassing any merge with $BRANCH,
# and pushes. Simulates a squash/rebase merge commit landing on
# origin/main without the branch tip ever becoming its ancestor. Echoes
# the new commit's SHA on stdout.
push_direct_commit_to_main() {
  local file="$1" content="$2"
  git -C "$CLONE" fetch -q origin
  git -C "$CLONE" checkout -q main
  git -C "$CLONE" merge -q --ff-only origin/main
  echo "$content" > "$CLONE/$file"
  git -C "$CLONE" add "$file"
  git -C "$CLONE" commit -q -m "squash landing"
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" rev-parse HEAD
}

# run_cleanup <cwd> <pr-number> <issue-number>
# Invokes cleanup-merged.sh with the given cwd, a stubbed `gh` ahead on
# PATH, and a hermetic stub GitHub App token helper. Keeps stdout (the
# machine-readable record) and stderr (human diagnostics) in separate
# files, then replays both so existing `>out.log 2>&1` call sites still
# see everything.
run_cleanup() {
  local cwd="$1" pr="$2" issue="$3" rc
  (
    cd "$cwd" || exit 99
    PATH="$STUBBIN:$PATH" \
    REAL_GIT="$REAL_GIT" \
    GH_LOG="$GH_LOG" \
    GIT_NETWORK_LOG="$GIT_NETWORK_LOG" \
    GIT_CMD_LOG="$GIT_CMD_LOG" \
    TEST_REMOTE_URL="$ORIGIN" \
    GH_APP_TOKEN_HELPER="$APP_TOKEN_HELPER" \
    SENTINEL_TOKEN="$SENTINEL" \
    "$CLEANUP" "$pr" "$issue"
  ) >"$BASE/stdout.log" 2>"$BASE/stderr.log"
  rc=$?
  cat "$BASE/stdout.log"
  cat "$BASE/stderr.log" >&2
  return "$rc"
}

# land_branch_on_origin_only pushes $BRANCH's tip onto the fake origin's
# main without advancing CLONE's main, leaving the primary worktree behind
# origin/main so the fast-forward step has real work to do.
land_branch_on_origin_only() {
  git -C "$WT" push -q origin "$BRANCH:main"
}

manifest_path() {
  # manifest_path <pr-number> — Phase 3's recorded artifact manifest.
  local pr="$1" manifest
  manifest="$(git -C "$CLONE" rev-parse --git-common-dir)/github-issue/artifacts/pr-${pr}.paths"
  case "$manifest" in
    /*) ;;
    *) manifest="$CLONE/$manifest" ;;
  esac
  printf '%s\n' "$manifest"
}

record_artifacts() {
  local pr="$1" manifest
  shift
  manifest="$(git -C "$WT" rev-parse --git-common-dir)/github-issue/artifacts/pr-${pr}.paths"
  case "$manifest" in
    /*) ;;
    *) manifest="$WT/$manifest" ;;
  esac
  mkdir -p "$(dirname "$manifest")"
  printf '%s\n' "$@" > "$manifest"
}

# setup_artifact_fixture <issue> <slug> — a fixture whose worktree carries
# the two manifest-recorded session artifacts Phase 3 writes.
setup_artifact_fixture() {
  local issue="$1" slug="$2"
  new_fixture "$issue" "$slug"
  mkdir -p "$WT/docs/superpowers/specs" "$WT/docs/superpowers/plans"
  printf 'docs/superpowers/\n' >> "$(git -C "$WT" rev-parse --git-path info/exclude)"
  echo "session design" > "$WT/docs/superpowers/specs/2026-08-15-${slug}-design.md"
  echo "session plan" > "$WT/docs/superpowers/plans/2026-08-15-${slug}.md"
  record_artifacts "$issue" \
    "docs/superpowers/specs/2026-08-15-${slug}-design.md" \
    "docs/superpowers/plans/2026-08-15-${slug}.md"
}

# assert_fully_cleaned <description-prefix> <number> — every Phase 7 step
# has landed, whether in one run or across a restart.
assert_fully_cleaned() {
  local p="$1" n="$2"
  assert_true "$p: worktree removed" [ ! -e "$WT" ]
  assert_false "$p: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_false "$p: remote branch deleted" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "$p: local main fast-forwarded to origin/main" \
    bash -c "[ \"\$(git -C '$CLONE' rev-parse main)\" = \"\$(git -C '$CLONE' rev-parse origin/main)\" ]"
  assert_true "$p: issue closed" bash -c "grep -q 'issue close $n' '$GH_LOG'"
  assert_true "$p: manifest removed" [ ! -e "$(manifest_path "$n")" ]
  assert_true "$p: journal records completion" \
    grep -qx 'status=cleaned' "$(journal_path "$n")"
}

# restart_boundary_case <number> <slug> <git-fail-match> <gh-fail-match> <expected-done-step>
# Crashes a real run at one mutation boundary, then reruns it clean and
# asserts the second run converges instead of tripping over the state the
# first run already changed.
restart_boundary_case() {
  local n="$1" slug="$2" gitfail="$3" ghfail="$4" expect_done="$5" rc
  setup_artifact_fixture "$n" "$slug"
  land_branch_on_origin_only

  GIT_FAIL_MATCH="$gitfail" GH_FAIL_MATCH="$ghfail" \
  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" "$n" "$n" >"$BASE/out.log" 2>&1
  rc=$?
  unset GIT_FAIL_MATCH GH_FAIL_MATCH STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "$slug: interrupted run reports a retryable failure" 30 "$rc"
  assert_record "$slug: interrupted run status" status retry
  assert_true "$slug: journal records the steps that completed" \
    grep -qx "done=$expect_done" "$(journal_path "$n")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" "$n" "$n" >"$BASE/out.log" 2>&1
  rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "$slug: restart converges" 0 "$rc"
  assert_record "$slug: restart status" status cleaned
  assert_fully_cleaned "$slug" "$n"
  assert_no_forbidden_git "$slug: no forbidden git command issued"
}

# --- Case 1: PR state != MERGED -> refuse, no deletion ---
test_case1_not_merged() {
  new_fixture 10 not-merged
  STUB_PR_STATE="OPEN" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 10 10 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case1: waiting exit code when PR isn't MERGED" 10 "$rc"
  assert_single_record "case1: exactly one record on stdout"
  assert_record "case1: status is waiting" status waiting
  assert_record "case1: reason names the open PR" reason pr-open
  assert_record "case1: record carries the PR number" pr 10
  assert_record "case1: record carries the issue number" issue 10
  assert_record "case1: merge mode is unknown" merge_mode null
  assert_true "case1: worktree left in place" [ -d "$WT" ]
  assert_true "case1: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case1: remote branch still present" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 2: headRefName not under agent/* -> refuse, no deletion ---
test_case2_non_agent_branch() {
  new_fixture 11 non-agent
  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="feature/not-agent" \
    run_cleanup "$CLONE" 11 11 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case2: blocked exit code when headRefName isn't agent/*" 20 "$rc"
  assert_record "case2: status is blocked" status blocked
  assert_record "case2: reason names the branch prefix" reason branch-not-agent
  assert_record "case2: record carries the refused branch" branch feature/not-agent
  assert_true "case2: unrelated worktree left in place" [ -d "$WT" ]
  assert_true "case2: unrelated local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 3: branch tip not an ancestor of origin/main -> refuse ---
test_case3_not_ancestor() {
  new_fixture 12 unlanded
  # Deliberately do NOT merge $BRANCH into origin/main.
  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 12 12 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case3: blocked exit code when branch tip isn't an ancestor of origin/main" 20 "$rc"
  assert_record "case3: status is blocked" status blocked
  assert_record "case3: reason names the unprovable merge" reason merge-unprovable
  assert_true "case3: worktree left in place" [ -d "$WT" ]
  assert_true "case3: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 4: worktree has uncommitted change -> refuse, worktree untouched ---
test_case4_dirty_worktree() {
  new_fixture 13 dirty-wt
  merge_branch_into_origin_main
  echo "uncommitted" > "$WT/dirty.txt"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 13 13 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case4: blocked exit code when the worktree is dirty" 20 "$rc"
  assert_record "case4: status is blocked" status blocked
  assert_record "case4: reason names the dirty worktree" reason worktree-dirty
  assert_true "case4: worktree left in place" [ -d "$WT" ]
  assert_true "case4: dirty file untouched" [ -f "$WT/dirty.txt" ]
  assert_true "case4: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 5: invoked with cwd inside the worktree being cleaned up ---
# This exercises the WORKSPACE-derivation fix: WORKSPACE must resolve to
# the primary worktree (git worktree list's first entry) even though the
# process starts inside the worktree about to be deleted, not via
# `git rev-parse --show-toplevel` (which would return $WT itself).
test_case5_cwd_inside_worktree_being_removed() {
  new_fixture 14 cwd-inside
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$WT" 14 14 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case5: exits zero when invoked from inside the doomed worktree" 0 "$rc"
  assert_true "case5: worktree removed" [ ! -e "$WT" ]
  assert_false "case5: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 6: all clean and MERGED, invoked from the primary workspace ---
test_case6_happy_path() {
  new_fixture 15 happy
  merge_branch_into_origin_main

  # 6a: issue not yet closed -> gh issue close is invoked.
  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 15 15 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case6a: exits zero on the full happy path" 0 "$rc"
  assert_single_record "case6a: exactly one record on stdout"
  assert_record "case6a: status is cleaned" status cleaned
  assert_record "case6a: reason names a completed cleanup" reason cleanup-complete
  assert_record "case6a: record carries the branch" branch "$BRANCH"
  assert_record "case6a: record carries the merge mode" merge_mode regular
  assert_no_forbidden_git "case6a: no forbidden git command issued"
  assert_true "case6a: initial fetch uses App-scoped Git" \
    bash -c "grep -q '^fetch:$SENTINEL$' '$GIT_NETWORK_LOG'"
  assert_true "case6a: worktree removed" [ ! -e "$WT" ]
  assert_false "case6a: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_false "case6a: remote branch deleted" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case6a: local main fast-forwarded to origin/main" \
    bash -c "[ \"\$(git -C '$CLONE' rev-parse main)\" = \"\$(git -C '$CLONE' rev-parse origin/main)\" ]"
  assert_true "case6a: gh issue close invoked (issue was open)" \
    bash -c "grep -q 'issue close 15' '$GH_LOG'"

  # 6b: issue already closed -> gh issue close must NOT be invoked.
  new_fixture 16 already-closed
  merge_branch_into_origin_main
  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 16 16 >"$BASE/out.log" 2>&1
  rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case6b: exits zero" 0 "$rc"
  assert_false "case6b: gh issue close NOT invoked (issue already closed)" \
    bash -c "grep -q 'issue close 16' '$GH_LOG'"
}

# --- Case 7: clean squash (patch-id equivalent) -> MERGE_MODE=squash, cleanup proceeds ---
test_case7_clean_squash() {
  new_fixture --content 17 clean-squash
  local merge_sha
  merge_sha="$(push_direct_commit_to_main feature.txt "feature line")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_PR_MERGE_COMMIT="$merge_sha" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 17 17 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_PR_MERGE_COMMIT STUB_ISSUE_STATE

  assert_eq "case7: exits zero on a clean squash (patch-id equivalent)" 0 "$rc"
  assert_record "case7: status is cleaned" status cleaned
  assert_record "case7: record reports the squash merge mode" merge_mode squash
  assert_no_forbidden_git "case7: no forbidden git command issued"
  assert_true "case7: worktree removed" [ ! -e "$WT" ]
  assert_false "case7: local branch deleted (via -D, tip is not an ancestor)" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 8: squash whose diff was altered by conflict resolution -> refuse ---
test_case8_squash_conflict_resolution() {
  new_fixture --content 18 squash-conflict
  local merge_sha
  merge_sha="$(push_direct_commit_to_main feature.txt "feature line, resolved differently")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_PR_MERGE_COMMIT="$merge_sha" \
    run_cleanup "$CLONE" 18 18 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_PR_MERGE_COMMIT

  assert_eq "case8: blocked exit code when the squash diff was altered by conflict resolution" 20 "$rc"
  assert_record "case8: status is blocked" status blocked
  assert_record "case8: reason names the unprovable merge" reason merge-unprovable
  assert_true "case8: worktree left in place" [ -d "$WT" ]
  assert_true "case8: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 9: rebase merge (mergeCommit is only the last replayed commit) -> refuse ---
test_case9_rebase_merge() {
  new_fixture --content 19 rebase-merge
  echo "second line" >> "$WT/other.txt"
  git -C "$WT" add other.txt
  git -C "$WT" commit -q -m "second commit"
  git -C "$WT" push -q origin "$BRANCH"

  local merge_sha
  merge_sha="$(push_direct_commit_to_main other.txt "second line")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_PR_MERGE_COMMIT="$merge_sha" \
    run_cleanup "$CLONE" 19 19 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_PR_MERGE_COMMIT

  assert_eq "case9: blocked exit code on a rebase merge (last-commit-only diff never matches the whole feature)" 20 "$rc"
  assert_record "case9: status is blocked" status blocked
  assert_record "case9: reason names the unprovable merge" reason merge-unprovable
  assert_true "case9: worktree left in place" [ -d "$WT" ]
  assert_true "case9: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 10: squash diff differs from the feature branch only by leading
# whitespace -> must NOT patch-match (--verbatim), refuse cleanup. Regression
# test for git patch-id --stable/--unstable stripping whitespace, which would
# let a whitespace-only divergence (e.g. significant Python indentation)
# false-positive into a proven squash and reach `git branch -D`. ---
test_case10_whitespace_only_squash_diff() {
  new_fixture 20 whitespace-squash
  echo "    feature line" > "$WT/feature.txt"
  git -C "$WT" add feature.txt
  git -C "$WT" commit -q -m "add indented feature line"
  git -C "$WT" push -q origin "$BRANCH"

  local merge_sha
  merge_sha="$(push_direct_commit_to_main feature.txt "feature line")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_PR_MERGE_COMMIT="$merge_sha" \
    run_cleanup "$CLONE" 20 20 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_PR_MERGE_COMMIT

  assert_eq "case10: blocked exit code when the squash diff differs only by leading whitespace" 20 "$rc"
  assert_record "case10: status is blocked" status blocked
  assert_record "case10: reason names the unprovable merge" reason merge-unprovable
  assert_true "case10: worktree left in place" [ -d "$WT" ]
  assert_true "case10: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 11: tracked history and recorded session artifacts can coexist. ---
test_case11_preserves_tracked_documents() {
  new_fixture --historical-docs 21 mixed-docs
  mkdir -p "$WT/docs/superpowers/specs" "$WT/docs/superpowers/plans"
  printf 'docs/superpowers/\n' >> "$(git -C "$WT" rev-parse --git-path info/exclude)"
  echo "session design" > "$WT/docs/superpowers/specs/2026-08-02-mixed-docs-design.md"
  echo "session plan" > "$WT/docs/superpowers/plans/2026-08-02-mixed-docs.md"
  record_artifacts 21 \
    docs/superpowers/specs/2026-08-02-mixed-docs-design.md \
    docs/superpowers/plans/2026-08-02-mixed-docs.md
  local design_blob plan_blob
  design_blob="$(git -C "$WT" rev-parse HEAD:docs/superpowers/specs/2025-01-01-historical-design.md)"
  plan_blob="$(git -C "$WT" rev-parse HEAD:docs/superpowers/plans/2025-01-01-historical.md)"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 21 21 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case11: cleanup succeeds" 0 "$rc"
  assert_eq "case11: historical design content survives" "historical design" \
    "$(git -C "$CLONE" show main:docs/superpowers/specs/2025-01-01-historical-design.md)"
  assert_eq "case11: historical plan content survives" "historical plan" \
    "$(git -C "$CLONE" show main:docs/superpowers/plans/2025-01-01-historical.md)"
  assert_eq "case11: historical design blob is unchanged" "$design_blob" \
    "$(git -C "$CLONE" rev-parse main:docs/superpowers/specs/2025-01-01-historical-design.md)"
  assert_eq "case11: historical plan blob is unchanged" "$plan_blob" \
    "$(git -C "$CLONE" rev-parse main:docs/superpowers/plans/2025-01-01-historical.md)"
  assert_true "case11: worktree removed" [ ! -e "$WT" ]
  assert_false "case11: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_false "case11: remote branch deleted" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case11: local main matches origin/main" \
    bash -c "[ \"\$(git -C '$CLONE' rev-parse main)\" = \"\$(git -C '$CLONE' rev-parse origin/main)\" ]"
}

# --- Case 12: an unrecorded matching file is ambiguous and preserved. ---
test_case12_preserves_unrecorded_candidate() {
  new_fixture 22 ambiguous-doc
  mkdir -p "$WT/docs/superpowers/specs" "$WT/docs/superpowers/plans"
  printf 'docs/superpowers/\n' >> "$(git -C "$WT" rev-parse --git-path info/exclude)"
  echo "session design" > "$WT/docs/superpowers/specs/2026-08-02-ambiguous-doc-design.md"
  echo "session plan" > "$WT/docs/superpowers/plans/2026-08-02-ambiguous-doc.md"
  echo "keep me" > "$WT/docs/superpowers/specs/unrecorded-design.md"
  record_artifacts 22 \
    docs/superpowers/specs/2026-08-02-ambiguous-doc-design.md \
    docs/superpowers/plans/2026-08-02-ambiguous-doc.md
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 22 22 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case12: blocked exit code on an unrecorded candidate" 20 "$rc"
  assert_record "case12: status is blocked" status blocked
  assert_record "case12: reason names the unrecorded artifact" reason unrecorded-artifact
  assert_true "case12: candidate is named on stderr, not in the record" \
    grep -q 'unrecorded-design.md' "$BASE/stderr.log"
  assert_true "case12: output identifies candidate" \
    grep -q 'unrecorded-design.md' "$BASE/out.log"
  assert_eq "case12: candidate content is unchanged" "keep me" \
    "$(cat "$WT/docs/superpowers/specs/unrecorded-design.md")"
  assert_true "case12: worktree preserved" [ -d "$WT" ]
  assert_true "case12: local branch preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 13: PR closed without merging -> blocked, never waiting ---
test_case13_closed_unmerged() {
  new_fixture 23 closed-unmerged
  STUB_PR_STATE="CLOSED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 23 23 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case13: blocked exit code on a CLOSED unmerged PR" 20 "$rc"
  assert_record "case13: status is blocked" status blocked
  assert_record "case13: reason names the closed unmerged PR" reason pr-closed-unmerged
  assert_true "case13: worktree left in place" [ -d "$WT" ]
  assert_true "case13: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 14: an immediate rerun is a provable no-op ---
test_case14_rerun_already_clean() {
  setup_artifact_fixture 24 rerun-clean
  land_branch_on_origin_only

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 24 24 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE
  assert_eq "case14: first run exits zero" 0 "$rc"
  assert_record "case14: first run reports cleaned" status cleaned

  local main_before close_calls
  main_before="$(git -C "$CLONE" rev-parse main)"
  close_calls="$(grep -c 'issue close 24' "$GH_LOG")"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 24 24 >"$BASE/out.log" 2>&1
  rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case14: rerun exits zero" 0 "$rc"
  assert_record "case14: rerun reports already-clean" status already-clean
  assert_record "case14: rerun reason names the converged state" reason nothing-to-clean
  assert_record "case14: rerun still reports the merge mode from the journal" merge_mode regular
  assert_eq "case14: rerun leaves main untouched" "$main_before" "$(git -C "$CLONE" rev-parse main)"
  assert_eq "case14: rerun does not close the issue again" "$close_calls" \
    "$(grep -c 'issue close 24' "$GH_LOG")"
  assert_no_forbidden_git "case14: no forbidden git command issued"
}

# --- Cases 15-19: crash at each mutation boundary, then converge ---
test_case15_restart_after_artifacts() {
  restart_boundary_case 25 restart-artifacts "worktree remove" "" artifacts
}

test_case16_restart_after_worktree() {
  restart_boundary_case 26 restart-worktree "branch -d" "" worktree
}

test_case17_restart_after_local_branch() {
  restart_boundary_case 27 restart-local-branch "--delete" "" local-branch
}

test_case18_restart_after_remote_branch() {
  restart_boundary_case 28 restart-remote-branch "merge --ff-only" "" remote-branch
}

test_case19_restart_after_main_fast_forward() {
  restart_boundary_case 29 restart-main-ff "" "issue close" main
}

# --- Case 20: crash between the last step and the journal finalize ---
test_case20_restart_before_journal_finalize() {
  setup_artifact_fixture 30 restart-finalize
  land_branch_on_origin_only

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE
  assert_eq "case20: first run exits zero" 0 "$rc"

  # Rewind the journal to the state a crash between the manifest removal
  # and the finalizing write would have left behind.
  local journal
  journal="$(journal_path 30)"
  sed -i 's/^status=cleaned$/status=in-progress/' "$journal"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 30 30 >"$BASE/out.log" 2>&1
  rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case20: restart exits zero" 0 "$rc"
  assert_record "case20: restart reports already-clean" status already-clean
  assert_true "case20: restart finalizes the journal" \
    grep -qx 'status=cleaned' "$journal"
  assert_no_forbidden_git "case20: no forbidden git command issued"
}

# --- Case 26: crash between closing the issue and removing the manifest ---
test_case26_restart_before_manifest_removal() {
  setup_artifact_fixture 35 restart-manifest
  land_branch_on_origin_only

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="OPEN" \
    run_cleanup "$CLONE" 35 35 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE
  assert_eq "case26: first run exits zero" 0 "$rc"

  # Rewind to the state a crash after `gh issue close` and before the
  # manifest removal would have left behind.
  local journal manifest
  journal="$(journal_path 35)"
  manifest="$(manifest_path 35)"
  mkdir -p "$(dirname "$manifest")"
  printf '%s\n' \
    docs/superpowers/specs/2026-08-15-restart-manifest-design.md \
    docs/superpowers/plans/2026-08-15-restart-manifest.md > "$manifest"
  sed -i -e '/^done=manifest$/d' -e 's/^status=cleaned$/status=in-progress/' "$journal"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 35 35 >"$BASE/out.log" 2>&1
  rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case26: restart exits zero" 0 "$rc"
  assert_record "case26: restart reports cleaned" status cleaned
  assert_true "case26: manifest removed" [ ! -e "$manifest" ]
  assert_true "case26: journal records completion" grep -qx 'status=cleaned' "$journal"
  assert_no_forbidden_git "case26: no forbidden git command issued"
}

# --- Case 21: worktree gone with no journal proving why -> blocked ---
test_case21_worktree_missing_without_evidence() {
  new_fixture 31 worktree-missing
  merge_branch_into_origin_main
  git -C "$CLONE" worktree remove "$WT"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 31 31 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case21: blocked exit code when the worktree vanished unprovably" 20 "$rc"
  assert_record "case21: status is blocked" status blocked
  assert_record "case21: reason names the missing worktree" reason worktree-missing
  assert_true "case21: local branch preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case21: remote branch preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 22: local branch gone with no journal proving why -> blocked ---
test_case22_local_branch_missing_without_evidence() {
  new_fixture 32 branch-missing
  merge_branch_into_origin_main
  git -C "$CLONE" worktree remove "$WT"
  git -C "$CLONE" branch -q -d "$BRANCH"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 32 32 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case22: blocked exit code when the local branch vanished unprovably" 20 "$rc"
  assert_record "case22: status is blocked" status blocked
  assert_record "case22: reason names the missing local branch" reason local-branch-missing
  assert_true "case22: remote branch preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 23: dirty primary worktree while main still needs the fast-forward ---
test_case23_dirty_primary_main() {
  new_fixture --historical-docs 33 dirty-main
  land_branch_on_origin_only
  echo "local edit" >> "$CLONE/docs/superpowers/plans/2025-01-01-historical.md"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 33 33 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case23: blocked exit code on a dirty primary worktree" 20 "$rc"
  assert_record "case23: status is blocked" status blocked
  assert_record "case23: reason names the dirty primary worktree" reason primary-worktree-dirty
  assert_true "case23: refuses before any mutation - worktree kept" [ -d "$WT" ]
  assert_true "case23: local branch preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case23: remote branch preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_eq "case23: local edit untouched" "local edit" \
    "$(tail -1 "$CLONE/docs/superpowers/plans/2025-01-01-historical.md")"
  assert_true "case23: no journal written" [ ! -e "$(journal_path 33)" ]
}

# --- Case 24: local main diverged from origin/main -> blocked, no mutation ---
test_case24_diverged_main() {
  new_fixture 34 diverged-main
  land_branch_on_origin_only
  git -C "$CLONE" commit -q --allow-empty -m "local-only commit"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 34 34 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  assert_eq "case24: blocked exit code when local main diverged" 20 "$rc"
  assert_record "case24: status is blocked" status blocked
  assert_record "case24: reason names the diverged main" reason main-diverged
  assert_true "case24: refuses before any mutation - worktree kept" [ -d "$WT" ]
  assert_true "case24: local branch preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case24: no journal written" [ ! -e "$(journal_path 34)" ]
}

# --- Case 25: the script itself never spells a forbidden Git command ---
test_case25_no_forbidden_git_in_source() {
  local pattern desc hit=""
  local -a forbidden=(
    'reset[[:space:]]+--hard'
    'git[[:space:]]+clean'
    'push[[:space:]].*--force'
    'push[[:space:]].*--force-with-lease'
    'worktree[[:space:]]+remove[[:space:]].*(--force|-f)'
    'branch[[:space:]]+-[dD][[:space:]]+(main|master|develop)'
  )
  for pattern in "${forbidden[@]}"; do
    if grep -Eq -- "$pattern" "$CLEANUP"; then
      hit="$pattern"
      break
    fi
  done
  if [ -z "$hit" ]; then
    ok "case25: cleanup script contains no forbidden Git command"
  else
    fail "case25: cleanup script contains a forbidden Git command (matched [$hit])"
  fi
}

test_case1_not_merged
test_case2_non_agent_branch
test_case3_not_ancestor
test_case4_dirty_worktree
test_case5_cwd_inside_worktree_being_removed
test_case6_happy_path
test_case7_clean_squash
test_case8_squash_conflict_resolution
test_case9_rebase_merge
test_case10_whitespace_only_squash_diff
test_case11_preserves_tracked_documents
test_case12_preserves_unrecorded_candidate
test_case13_closed_unmerged
test_case14_rerun_already_clean
test_case15_restart_after_artifacts
test_case16_restart_after_worktree
test_case17_restart_after_local_branch
test_case18_restart_after_remote_branch
test_case19_restart_after_main_fast_forward
test_case20_restart_before_journal_finalize
test_case26_restart_before_manifest_removal
test_case21_worktree_missing_without_evidence
test_case22_local_branch_missing_without_evidence
test_case23_dirty_primary_main
test_case24_diverged_main
test_case25_no_forbidden_git_in_source

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
