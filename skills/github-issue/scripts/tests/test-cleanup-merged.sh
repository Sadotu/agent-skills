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

write_gh_shim() {
  # write_gh_shim <path> — a fake `gh` that logs its invocation to $GH_LOG
  # and returns canned output. Never touches the network.
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ "${GH_TOKEN-}" != "$SENTINEL_TOKEN" ]; then
  echo "stub gh requires the expected App token" >&2
  exit 4
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
  APP_TOKEN_HELPER="$BASE/gh-app-token.sh"
  BRANCH="agent/${issue}-${slug}"
  WT="$BASE/wt"
  : > "$GH_LOG"
  : > "$GIT_NETWORK_LOG"

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
for arg in "$@"; do
  if [ "$arg" = fetch ] || [ "$arg" = push ] || [ "$arg" = ls-remote ]; then
    printf '%s:%s\n' "$arg" "${GIT_APP_TOKEN-}" >> "$GIT_NETWORK_LOG"
    break
  fi
done
rewritten=()
for arg in "$@"; do
  case "$arg" in
    remote.origin.url=https://github.com/*|remote.origin.pushurl=https://github.com/*)
      rewritten+=("${arg%%=*}=$TEST_REMOTE_URL") ;;
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
# PATH, and a hermetic stub GitHub App token helper.
run_cleanup() {
  local cwd="$1" pr="$2" issue="$3"
  (
    cd "$cwd" || exit 99
    PATH="$STUBBIN:$PATH" \
    REAL_GIT="$REAL_GIT" \
    GH_LOG="$GH_LOG" \
    GIT_NETWORK_LOG="$GIT_NETWORK_LOG" \
    TEST_REMOTE_URL="$ORIGIN" \
    GH_APP_TOKEN_HELPER="$APP_TOKEN_HELPER" \
    SENTINEL_TOKEN="$SENTINEL" \
    "$CLEANUP" "$pr" "$issue"
  )
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

  [ "$rc" -ne 0 ] && ok "case12: cleanup refuses unrecorded candidate" \
    || fail "case12: cleanup refuses unrecorded candidate"
  assert_true "case12: output identifies candidate" \
    grep -q 'unrecorded-design.md' "$BASE/out.log"
  assert_eq "case12: candidate content is unchanged" "keep me" \
    "$(cat "$WT/docs/superpowers/specs/unrecorded-design.md")"
  assert_true "case12: worktree preserved" [ -d "$WT" ]
  assert_true "case12: local branch preserved" \
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
test_case11_preserves_tracked_documents
test_case12_preserves_unrecorded_candidate

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
