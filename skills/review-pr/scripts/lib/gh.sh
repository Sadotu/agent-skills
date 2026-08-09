#!/usr/bin/env bash
# Shared setup for skills/review-pr scripts. Sourced, not executed.
#
# Re-derives what SKILL.md's top-level interactive Setup block computes —
# a script runs as its own process and cannot inherit that block's shell
# variables or the GH() function.

REPO="$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"

# `git worktree list --porcelain`'s first entry is always the primary
# worktree, regardless of the caller's cwd — unlike `git rev-parse
# --show-toplevel`, which returns whichever worktree the caller happens to
# be running in.
WORKSPACE="$(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"

# Overridable only so tests can exercise both authentication environments
# without mutating the machine; unset means the devcontainer's real helper.
GH_APP_TOKEN_HELPER="${GH_APP_TOKEN_HELPER:-/opt/agent-devcontainer/gh-app-token.sh}"

if [ ! -x "$GH_APP_TOKEN_HELPER" ]; then
  echo "GitHub App token helper is unavailable or not executable: $GH_APP_TOKEN_HELPER. Run /setup to configure GitHub App authentication." >&2
  return 1 2>/dev/null || exit 1
fi

# Mint a short-lived GitHub App token per call.
GH() {
  if [ "${1:-}" = api ]; then
    GH_TOKEN="$(GITHUB_APP_REPO=$REPO "$GH_APP_TOKEN_HELPER")" gh "$@"
  else
    GH_TOKEN="$(GITHUB_APP_REPO=$REPO "$GH_APP_TOKEN_HELPER")" gh "$@" --repo "$REPO"
  fi
}
