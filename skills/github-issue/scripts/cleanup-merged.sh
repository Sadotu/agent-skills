#!/usr/bin/env bash
# Phase 7 ("Post-Merge Cleanup") for skills/github-issue/SKILL.md.
#
# Only ever cleans up once the PR is MERGED, its branch is under agent/*,
# that branch has actually landed in origin/main, and its worktree is
# clean. Any guard failure stops and reports without touching anything.
# Never uses forced worktree removal, `git branch -D`, reset, clean, or
# force-push.
#
# Usage: cleanup-merged.sh <pr-number> <issue-number>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: cleanup-merged.sh <pr-number> <issue-number>" >&2
  exit 1
fi

pr_number="$1"
issue_number="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"

# --- Guard: resolve the merged branch from the PR, enforce agent/* ---
PR_JSON="$(GH pr view "$pr_number" --json state,headRefName)"
test "$(printf '%s' "$PR_JSON" | jq -r .state)" = MERGED
BRANCH="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
case "$BRANCH" in agent/*) ;; *) echo "Refusing to delete non-agent branch: $BRANCH"; exit 1 ;; esac

# --- Guard: branch tip landed in origin/main, and its worktree is clean ---
git -C "$WORKSPACE" fetch origin
git -C "$WORKSPACE" merge-base --is-ancestor "$BRANCH" origin/main
ISSUE_WORKTREE="$(git -C "$WORKSPACE" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" '
  /^worktree / { wt=substr($0, 10) }
  $0 == "branch " ref { print wt }
')"
test -n "$ISSUE_WORKTREE"
test -z "$(git -C "$ISSUE_WORKTREE" status --porcelain)"

# --- All guards passed: delete session-local artifacts, remove worktree,
#     delete the local and (if present) remote branch. `cd` into
#     $WORKSPACE first — this may be running from inside $ISSUE_WORKTREE,
#     about to disappear out from under the process's cwd. ---
cd "$WORKSPACE"
rm -f "$ISSUE_WORKTREE"/docs/superpowers/specs/*-design.md \
      "$ISSUE_WORKTREE"/docs/superpowers/plans/*.md
git worktree remove "$ISSUE_WORKTREE"
git worktree prune
git branch -d "$BRANCH"
if git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  git push origin --delete "$BRANCH"
fi

# --- Fast-forward local main without resetting or cleaning user files ---
test "$(git branch --show-current)" = main
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"

# --- Confirm the issue closed; close it manually if GitHub didn't ---
ISSUE_STATE="$(GH issue view "$issue_number" --json state -q .state)"
if [ "$ISSUE_STATE" != CLOSED ]; then
  GH issue close "$issue_number"
fi
