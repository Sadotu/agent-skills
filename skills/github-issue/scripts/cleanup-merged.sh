#!/usr/bin/env bash
# Phase 7 ("Post-Merge Cleanup") for skills/github-issue/SKILL.md.
#
# Only ever cleans up once the PR is MERGED, its branch is under agent/*,
# that branch has actually landed in origin/main (as a true merge commit,
# or proven via patch-id equivalence for a squash merge -- see MERGE_MODE
# below; rebase merges are a documented dead end that stops and asks a
# human), and its worktree is clean. Any guard failure stops and reports
# without touching anything. Never uses forced worktree removal, reset,
# clean, or force-push. Uses `git branch -D` only via the proven-squash
# path; never on unproven state.
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
PR_JSON="$(GH pr view "$pr_number" --json state,headRefName,mergeCommit)"
test "$(printf '%s' "$PR_JSON" | jq -r .state)" = MERGED
BRANCH="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
case "$BRANCH" in agent/*) ;; *) echo "Refusing to delete non-agent branch: $BRANCH"; exit 1 ;; esac

# --- Guard: branch's work actually landed in origin/main. Invariant:
#     MERGE_MODE=regular iff the branch tip is an ancestor of origin/main;
#     MERGE_MODE=squash iff not, but the branch diff and mergeCommit diff
#     are proven patch-id equivalent; anything else refuses and asks a
#     human. Known limitation: patch-id hashes diff context lines, so
#     unrelated commits shifting that context can produce a false
#     negative even for a clean squash -- fails safe, left as-is. ---
git -C "$WORKSPACE" fetch origin

if git -C "$WORKSPACE" merge-base --is-ancestor "$BRANCH" origin/main; then
  MERGE_MODE=regular
else
  MERGE_SHA="$(printf '%s' "$PR_JSON" | jq -r .mergeCommit.oid)"
  HEAD_SHA="$(git -C "$WORKSPACE" rev-parse "refs/heads/$BRANCH")"

  if [ -n "$MERGE_SHA" ] && [ "$MERGE_SHA" != null ] \
    && git -C "$WORKSPACE" merge-base --is-ancestor "$MERGE_SHA" origin/main; then
    MERGE_PARENT="$(git -C "$WORKSPACE" rev-parse "$MERGE_SHA^")"
    FEATURE_BASE="$(git -C "$WORKSPACE" merge-base "$HEAD_SHA" "$MERGE_PARENT")"
    FEATURE_PATCH_ID="$(git -C "$WORKSPACE" diff "$FEATURE_BASE" "$HEAD_SHA" | git patch-id --verbatim | awk '{print $1}')"
    SQUASH_PATCH_ID="$(git -C "$WORKSPACE" diff "$MERGE_PARENT" "$MERGE_SHA" | git patch-id --verbatim | awk '{print $1}')"
    if [ -n "$FEATURE_PATCH_ID" ] && [ "$FEATURE_PATCH_ID" = "$SQUASH_PATCH_ID" ]; then
      MERGE_MODE=squash
    fi
  fi

  if [ -z "${MERGE_MODE:-}" ]; then
    echo "Cannot prove $BRANCH landed in origin/main (not an ancestor, not a provable squash). Refusing automatic cleanup -- verify manually." >&2
    exit 1
  fi
fi

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
if [ "$MERGE_MODE" = regular ]; then
  git branch -d "$BRANCH"
else
  # MERGE_MODE=squash only: reachable exclusively via the guard stack
  # above (PR MERGED + agent/* + clean worktree + proven patch-id
  # equivalence). `branch -d` would refuse here since the tip genuinely
  # isn't an ancestor by git's own definition; `-D` bypasses that check.
  # Never use -D on any other path; never loosen this gate.
  git branch -D "$BRANCH"
fi
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
