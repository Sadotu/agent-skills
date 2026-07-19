#!/usr/bin/env bash
# Phase 2 ("Synchronize and Isolate") for skills/github-issue/SKILL.md.
#
# Guards that the primary worktree is clean and on an unstale `main`, then
# branches from freshly-fetched origin/main into an isolated worktree,
# seeds a commit, pushes, and opens the draft PR. Any guard failure aborts
# before any mutation — never commits issue work on a dirty or diverged
# main.
#
# Usage: isolate.sh <issue-number> <slug> <worktree-path> <pr-title>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: isolate.sh <issue-number> <slug> <worktree-path> <pr-title>" >&2
  exit 1
fi

issue_number="$1"
slug="$2"
worktree_path="$3"
pr_title="$4"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"

branch="agent/${issue_number}-${slug}"

# --- Guards: primary worktree must be clean, on main, and not diverged ---
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain)"
git fetch origin
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"

# --- Isolate: branch from origin/main into its own worktree ---
git worktree add -b "$branch" "$worktree_path" origin/main

# --- Open the PR now, as a draft: seed a commit, push, open immediately ---
cd "$worktree_path"
git commit --allow-empty -m "Start work on #${issue_number}"
git push -u origin "$branch"
GH pr create --draft \
  --title "$pr_title" \
  --body "$(cat <<EOF
Closes #${issue_number}

## Design Decisions
_In progress — filled in once design work completes._
EOF
)"
