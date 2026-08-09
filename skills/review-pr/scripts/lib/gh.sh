#!/usr/bin/env bash
# Shared setup for skills/review-pr scripts. Sourced, not executed.
#
# Re-derives what SKILL.md's top-level interactive Setup block computes —
# a script runs as its own process and cannot inherit that block's shell
# variables or the GH() function.

origin="$(git remote get-url origin 2>/dev/null)" || {
  echo "invalid GitHub origin: unable to read git remote origin" >&2
  return 1 2>/dev/null || exit 1
}
case "$origin" in
  https://github.com/*) repo_path="${origin#https://github.com/}" ;;
  git@github.com:*) repo_path="${origin#git@github.com:}" ;;
  ssh://git@github.com/*) repo_path="${origin#ssh://git@github.com/}" ;;
  *)
    echo "invalid GitHub origin: expected owner/repo on github.com" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
repo_path="${repo_path%/}"
repo_path="${repo_path%.git}"
owner="${repo_path%%/*}"
repo="${repo_path#*/}"
if [ -z "$owner" ] || [ -z "$repo" ] || [ "$repo" = "$repo_path" ] || [[ "$repo" = */* ]]; then
  echo "invalid GitHub origin: expected exactly owner/repo" >&2
  return 1 2>/dev/null || exit 1
fi
REPO="$owner/$repo"

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
  local token rc
  token="$(GITHUB_APP_REPO=$REPO "$GH_APP_TOKEN_HELPER")" || {
    rc=$?
    echo "failed to mint GitHub App token; run /setup to repair App authentication" >&2
    return "$rc"
  }
  if [ -z "$token" ]; then
    echo "GitHub App token helper returned an empty token; run /setup to repair App authentication" >&2
    return 1
  fi
  if [ "${1:-}" = api ]; then
    GH_TOKEN="$token" gh "$@"
  else
    GH_TOKEN="$token" gh "$@" --repo "$REPO"
  fi
}
