#!/usr/bin/env bash
# Shared setup for skills/github-issue scripts. Sourced, not executed.
#
# Re-derives what SKILL.md's top-level interactive Setup block computes —
# a script runs as its own process and cannot inherit that block's shell
# variables or the GH() function.

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"

# Do NOT use `git rev-parse --show-toplevel` here: it returns whichever
# worktree the caller's cwd happens to be in, which is wrong when
# cleanup-merged.sh runs from inside the issue worktree it's about to
# delete. `git worktree list --porcelain`'s first entry is always the
# primary worktree, regardless of the caller's cwd.
WORKSPACE="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"

if [ -x /opt/agent-devcontainer/gh-app-token.sh ]; then
  # devcontainer: mint a short-lived GitHub App token per call
  GH() { GH_TOKEN="$(GITHUB_APP_REPO=$REPO /opt/agent-devcontainer/gh-app-token.sh)" gh "$@" --repo "$REPO"; }
else
  # elsewhere: use your own authenticated gh (run `gh auth login` first)
  GH() { gh "$@" --repo "$REPO"; }
fi
