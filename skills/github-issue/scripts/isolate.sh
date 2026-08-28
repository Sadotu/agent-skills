#!/usr/bin/env bash
# Phase 2 ("Synchronize and Isolate") for skills/github-issue/SKILL.md.
#
# Guards that the primary worktree is clean and on an unstale `main`, then
# branches from freshly-fetched origin/main into an isolated worktree,
# seeds a commit, pushes, and opens the PR. Wrong-branch, dirty-tree,
# and unsafe-base checks finish before the fast-forward. Fetch updates remote
# refs, and failures after the fast-forward may leave local main synchronized.
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

# Idempotent: strip any pre-existing leading "WIP: " (case-insensitive,
# possibly repeated) so a caller-supplied WIP prefix can't double up with
# the one this script adds below.
while [[ "$pr_title" =~ ^[Ww][Ii][Pp]:[[:space:]]* ]]; do
  pr_title="${pr_title:${#BASH_REMATCH[0]}}"
done

# --- Guards: primary worktree must be clean, on main, and not diverged ---
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain)"
GIT_AUTH fetch origin '+refs/heads/*:refs/remotes/origin/*'
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"

# --- Isolate: branch from origin/main into its own worktree ---
git worktree add -b "$branch" "$worktree_path" origin/main

# --- Open the PR now: seed a commit, push, open immediately ---
cd "$worktree_path"
git commit --allow-empty -m "Start work on #${issue_number}"
GIT_AUTH push origin "$branch:refs/heads/$branch"
git update-ref "refs/remotes/origin/$branch" "$branch"
git config "branch.$branch.remote" origin
git config "branch.$branch.merge" "refs/heads/$branch"
GH pr create \
  --title "WIP: $pr_title" \
  --body "$(cat <<EOF
Closes #${issue_number}

## Summary
_In progress — filled in once design work completes._

## Design Decisions
_In progress — filled in once design work completes._
EOF
)"
