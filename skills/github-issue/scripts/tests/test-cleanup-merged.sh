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

# new_fixture sets: BASE ORIGIN CLONE STUBBIN GH_LOG APP_DIR_STUB BRANCH WT
# CLONE stands in for $WORKSPACE (the primary worktree), on main, in sync
# with ORIGIN. WT is a linked worktree checked out on $BRANCH, with one
# commit ahead of origin/main and pushed to the fake origin — not yet
# merged into origin/main.
new_fixture() {
  local content=0 cleanup_docs=0
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --content) content=1 ;;
      --cleanup-docs) cleanup_docs=1 ;;
      *) echo "unknown fixture option: $1" >&2; return 2 ;;
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
  APP_DIR_STUB="$BASE/no-app-creds"
  BRANCH="agent/${issue}-${slug}"
  WT="$BASE/wt"
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
  if [ "$cleanup_docs" -eq 1 ]; then
    mkdir -p "$CLONE/docs/superpowers/specs" "$CLONE/docs/superpowers/plans"
    printf '%s\n' "historical design content" > "$CLONE/docs/superpowers/specs/historical-design.md"
    printf '%s\n' "historical plan content" > "$CLONE/docs/superpowers/plans/historical.md"
    cat > "$CLONE/.gitignore" <<'EOF'
docs/superpowers/specs/session-*.md
docs/superpowers/plans/session-*.md
EOF
    git -C "$CLONE" add .gitignore docs/superpowers
    git -C "$CLONE" commit -q -m "add historical cleanup documents"
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
}

# record_artifacts <pr-number> <repository-relative-path>...
# Writes the cleanup provenance manifest into the shared Git directory. Git
# may report that directory relative to WT, so normalize it before writing.
record_artifacts() {
  local pr="$1" common_dir
  shift
  if [ "$#" -eq 0 ]; then
    echo "record_artifacts requires at least one path" >&2
    return 2
  fi
  common_dir="$(git -C "$WT" rev-parse --git-common-dir)"
  case "$common_dir" in
    /*) ;;
    *) common_dir="$WT/$common_dir" ;;
  esac
  mkdir -p "$common_dir/github-issue/artifacts"
  printf '%s\0' "$@" > "$common_dir/github-issue/artifacts/pr-${pr}.paths"
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
# PATH, and no real GitHub App credentials reachable (so the devcontainer
# token-mint path fails locally instead of hitting the network).
run_cleanup() {
  local cwd="$1" pr="$2" issue="$3"
  (
    cd "$cwd" || exit 99
    PATH="$STUBBIN:$PATH" \
    GH_LOG="$GH_LOG" \
    GITHUB_APP_DIR="$APP_DIR_STUB" \
    STUB_REPO="testowner/testrepo" \
    "$CLEANUP" "$pr" "$issue"
  )
}

# --- Case 1: PR state != MERGED -> refuse, no deletion ---
test_case1_not_merged() {
  new_fixture 10 not-merged
  STUB_PR_STATE="OPEN" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 10 10 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  [ "$rc" -ne 0 ] && ok "case1: nonzero exit when PR isn't MERGED" \
    || fail "case1: nonzero exit when PR isn't MERGED (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case2: nonzero exit when headRefName isn't agent/*" \
    || fail "case2: nonzero exit when headRefName isn't agent/* (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case3: nonzero exit when branch tip isn't an ancestor of origin/main" \
    || fail "case3: nonzero exit when branch tip isn't an ancestor of origin/main (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case4: nonzero exit when the worktree is dirty" \
    || fail "case4: nonzero exit when the worktree is dirty (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case8: nonzero exit when the squash diff was altered by conflict resolution" \
    || fail "case8: nonzero exit when the squash diff was altered by conflict resolution (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case9: nonzero exit on a rebase merge (last-commit-only diff never matches the whole feature)" \
    || fail "case9: nonzero exit on a rebase merge (got rc=$rc)"
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

  [ "$rc" -ne 0 ] && ok "case10: nonzero exit when the squash diff differs only by leading whitespace" \
    || fail "case10: nonzero exit when the squash diff differs only by leading whitespace (got rc=$rc)"
  assert_true "case10: worktree left in place" [ -d "$WT" ]
  assert_true "case10: local branch still present" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 11: cleanup removes only the PR-recorded ignored artifacts and
# preserves tracked historical documents that happen to match their names. ---
test_case11_mixed_tracked_and_recorded_artifacts() {
  new_fixture --cleanup-docs 21 mixed-ownership
  local historical_design="docs/superpowers/specs/historical-design.md"
  local historical_plan="docs/superpowers/plans/historical.md"
  local session_design="docs/superpowers/specs/session-21-design.md"
  local session_plan="docs/superpowers/plans/session-21.md"
  local design_blob plan_blob
  design_blob="$(git -C "$WT" rev-parse "HEAD:$historical_design")"
  plan_blob="$(git -C "$WT" rev-parse "HEAD:$historical_plan")"

  printf '%s\n' "session design" > "$WT/$session_design"
  printf '%s\n' "session plan" > "$WT/$session_plan"
  record_artifacts 21 "$session_design" "$session_plan"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 21 21 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case11: exits zero for recorded ignored artifacts" 0 "$rc"
  assert_eq "case11: historical design content survives" "historical design content" \
    "$(git -C "$CLONE" show "main:$historical_design")"
  assert_eq "case11: historical plan content survives" "historical plan content" \
    "$(git -C "$CLONE" show "main:$historical_plan")"
  assert_eq "case11: historical design blob is unchanged" "$design_blob" \
    "$(git -C "$CLONE" rev-parse "main:$historical_design")"
  assert_eq "case11: historical plan blob is unchanged" "$plan_blob" \
    "$(git -C "$CLONE" rev-parse "main:$historical_plan")"
  assert_true "case11: worktree and its session artifacts are removed together" \
    bash -c "[ ! -e '$WT' ] && [ ! -e '$WT/$session_design' ] && [ ! -e '$WT/$session_plan' ]"
  assert_false "case11: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_false "case11: remote branch deleted" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case11: local main exactly matches origin/main" \
    bash -c "[ \"\$(git -C '$CLONE' rev-parse main)\" = \"\$(git -C '$CLONE' rev-parse origin/main)\" ]"
}

# --- Case 12: an ignored cleanup candidate absent from the PR manifest is
# ambiguous; refuse before deleting either candidate or branch state. ---
test_case12_unrecorded_artifact_is_ambiguous() {
  new_fixture 22 ambiguous-artifact
  local recorded_design="docs/superpowers/specs/session-22-design.md"
  local recorded_plan="docs/superpowers/plans/session-22.md"
  local unrecorded="docs/superpowers/specs/session-unrecorded-design.md"
  local recorded_design_content="recorded design for PR 22"
  local recorded_plan_content="recorded plan for PR 22"
  local unrecorded_content="unrecorded candidate owned elsewhere"
  mkdir -p "$WT/docs/superpowers/specs" "$WT/docs/superpowers/plans"
  printf '%s\n' "$recorded_design_content" > "$WT/$recorded_design"
  printf '%s\n' "$recorded_plan_content" > "$WT/$recorded_plan"
  printf '%s\n' "$unrecorded_content" > "$WT/$unrecorded"
  printf '%s\n' \
    'docs/superpowers/specs/session-*.md' \
    'docs/superpowers/plans/session-*.md' > "$BASE/session-artifacts.exclude"
  git -C "$WT" config core.excludesFile "$BASE/session-artifacts.exclude"
  record_artifacts 22 "$recorded_design" "$recorded_plan"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 22 22 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  [ "$rc" -ne 0 ] && ok "case12: nonzero exit for an unrecorded cleanup candidate" \
    || fail "case12: nonzero exit for an unrecorded cleanup candidate (got rc=$rc)"
  assert_true "case12: output identifies actionable ambiguity" \
    bash -c "grep -Fq 'record it in the PR artifact manifest or move/remove it manually' '$BASE/out.log' && grep -Fq '$unrecorded' '$BASE/out.log'"
  assert_eq "case12: recorded design content is unchanged" "$recorded_design_content" \
    "$(cat "$WT/$recorded_design" 2>/dev/null)"
  assert_eq "case12: recorded plan content is unchanged" "$recorded_plan_content" \
    "$(cat "$WT/$recorded_plan" 2>/dev/null)"
  assert_eq "case12: unrecorded candidate content is unchanged" "$unrecorded_content" \
    "$(cat "$WT/$unrecorded" 2>/dev/null)"
  assert_true "case12: worktree is preserved" [ -d "$WT" ]
  assert_true "case12: local branch is preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case12: remote branch is preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 13: ignored files outside the cleanup filename patterns are not
# cleanup candidates and do not require provenance records. ---
test_case13_unrelated_ignored_file_does_not_block() {
  new_fixture 23 unrelated-ignored
  local unrelated="docs/superpowers/specs/notes.txt"
  mkdir -p "$WT/docs/superpowers/specs"
  printf '%s\n' "unrelated ignored notes" > "$WT/$unrelated"
  printf '%s\n' "$unrelated" > "$BASE/unrelated.exclude"
  git -C "$WT" config core.excludesFile "$BASE/unrelated.exclude"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" STUB_ISSUE_STATE="CLOSED" \
    run_cleanup "$CLONE" 23 23 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF STUB_ISSUE_STATE

  assert_eq "case13: unrelated ignored file does not block artifact-free cleanup" 0 "$rc"
  assert_true "case13: normal worktree removal removes the unrelated ignored file" [ ! -e "$WT" ]
  assert_false "case13: local branch deleted" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 14: matching ignored non-regular entries are ambiguous candidates.
# They cannot be provenance-validated as disposable regular files, so cleanup
# must stop before mutating either entry or branch state. ---
test_case14_matching_non_regular_entries_are_ambiguous() {
  new_fixture 24 non-regular-artifacts
  local matching_symlink="docs/superpowers/specs/session-link-design.md"
  local matching_directory="docs/superpowers/plans/session-directory.md"
  mkdir -p "$WT/docs/superpowers/specs" "$WT/$matching_directory"
  ln -s ../plans "$WT/$matching_symlink"
  printf '%s\n' \
    'docs/superpowers/specs/session-*.md' \
    'docs/superpowers/plans/session-*.md' > "$BASE/non-regular.exclude"
  git -C "$WT" config core.excludesFile "$BASE/non-regular.exclude"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 24 24 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  [ "$rc" -ne 0 ] && ok "case14: nonzero exit for matching non-regular candidates" \
    || fail "case14: nonzero exit for matching non-regular candidates (got rc=$rc)"
  assert_true "case14: output identifies a matching non-regular ambiguity" \
    bash -c "grep -Fq 'record it in the PR artifact manifest or move/remove it manually' '$BASE/out.log' && { grep -Fq '$matching_symlink' '$BASE/out.log' || grep -Fq '$matching_directory' '$BASE/out.log'; }"
  assert_true "case14: matching symlink is preserved" [ -L "$WT/$matching_symlink" ]
  assert_true "case14: matching directory is preserved" [ -d "$WT/$matching_directory" ]
  assert_true "case14: worktree is preserved" [ -d "$WT" ]
  assert_true "case14: local branch is preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case14: remote branch is preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 15: discovery failure after partial output must fail closed. ---
test_case15_partial_discovery_failure_preserves_everything() {
  new_fixture 25 discovery-failure
  local artifact="docs/superpowers/specs/session-25-design.md"
  mkdir -p "$WT/docs/superpowers/specs"
  printf '%s\n' "recorded artifact" > "$WT/$artifact"
  printf '%s\n' 'docs/superpowers/specs/session-*.md' > "$BASE/discovery.exclude"
  git -C "$WT" config core.excludesFile "$BASE/discovery.exclude"
  record_artifacts 25 "$artifact"
  merge_branch_into_origin_main

  cat > "$STUBBIN/find" <<'SHIM'
#!/usr/bin/env bash
printf '%s\0' "$FIND_PARTIAL_PATH"
exit 1
SHIM
  chmod +x "$STUBBIN/find"
  export FIND_PARTIAL_PATH="$WT/$artifact"

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 25 25 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF FIND_PARTIAL_PATH

  [ "$rc" -ne 0 ] && ok "case15: nonzero exit when artifact discovery fails" \
    || fail "case15: nonzero exit when artifact discovery fails (got rc=$rc)"
  assert_true "case15: output reports artifact discovery failure" \
    bash -c "grep -Fq 'Artifact discovery failed' '$BASE/out.log'"
  assert_eq "case15: recorded artifact is preserved" "recorded artifact" \
    "$(cat "$WT/$artifact" 2>/dev/null)"
  assert_true "case15: worktree is preserved" [ -d "$WT" ]
  assert_true "case15: local branch is preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
  assert_true "case15: remote branch is preserved" \
    bash -c "git -C '$ORIGIN' show-ref --verify --quiet refs/heads/$BRANCH"
}

# --- Case 16: an artifact parent that is already a symlink is never used as
# a deletion anchor, and same-name external content remains untouched. ---
test_case16_symlinked_artifact_parent_is_refused() {
  new_fixture 26 symlinked-parent
  local artifact="docs/superpowers/specs/session-26-design.md"
  local external="$BASE/external-specs"
  mkdir -p "$WT/docs/superpowers" "$external"
  printf '%s\n' "external content" > "$external/session-26-design.md"
  ln -s "$external" "$WT/docs/superpowers/specs"
  printf '%s\n' 'docs/superpowers/specs/session-*.md' > "$BASE/symlink-parent.exclude"
  git -C "$WT" config core.excludesFile "$BASE/symlink-parent.exclude"
  record_artifacts 26 "$artifact"
  merge_branch_into_origin_main

  STUB_PR_STATE="MERGED" STUB_PR_HEAD_REF="$BRANCH" \
    run_cleanup "$CLONE" 26 26 >"$BASE/out.log" 2>&1
  local rc=$?
  unset STUB_PR_STATE STUB_PR_HEAD_REF

  [ "$rc" -ne 0 ] && ok "case16: nonzero exit for a symlinked artifact parent" \
    || fail "case16: nonzero exit for a symlinked artifact parent (got rc=$rc)"
  assert_eq "case16: external same-name content is unchanged" "external content" \
    "$(cat "$external/session-26-design.md")"
  assert_true "case16: symlinked parent is preserved" [ -L "$WT/docs/superpowers/specs" ]
  assert_true "case16: worktree is preserved" [ -d "$WT" ]
  assert_true "case16: local branch is preserved" \
    bash -c "git -C '$CLONE' show-ref --verify --quiet refs/heads/$BRANCH"
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
test_case11_mixed_tracked_and_recorded_artifacts
test_case12_unrecorded_artifact_is_ambiguous
test_case13_unrelated_ignored_file_does_not_block
test_case14_matching_non_regular_entries_are_ambiguous
test_case15_partial_discovery_failure_preserves_everything
test_case16_symlinked_artifact_parent_is_refused

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
