#!/usr/bin/env bash
# Validate and publish a completed managed repair.
# Usage: finalize.sh <issue> <pr> <inspected-head> <branch> <worktree> <verification-json>
set -euo pipefail

die() { echo "$1" >&2; exit 1; }

[ "$#" -eq 6 ] || die "usage: finalize.sh <issue> <pr> <inspected-head> <branch> <worktree> <verification-json>"
issue="$1"; pr="$2"; inspected_head="$3"; branch="$4"; worktree="$5"; evidence="$6"
case "$issue" in ''|*[!0-9]*) die "invalid issue-number: $issue" ;; esac
case "$pr" in ''|*[!0-9]*) die "invalid pr-number: $pr" ;; esac

[ -d "$worktree" ] || die "worktree does not exist: $worktree"
[ "$(pwd -P)" = "$(cd "$worktree" && pwd -P)" ] || die "finalizer must run from exact worktree: $worktree"

worktree_matches="$(git worktree list --porcelain | awk -v path="$worktree" -v ref="refs/heads/$branch" '
  /^worktree / { current=substr($0,10); matches_path=(current == path); next }
  /^branch / { if (matches_path && $0 == "branch " ref) found++ }
  END { print found+0 }
')"
[ "$worktree_matches" -eq 1 ] || die "worktree/branch identity does not match $worktree and $branch"
[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "$branch" ] \
  || die "current branch does not match inspected branch: $branch"

pr_branch="$(gh pr view "$pr" --json headRefName | jq -r .headRefName)"
[ "$pr_branch" = "$branch" ] || die "PR #$pr head branch changed: expected $branch, found $pr_branch"

git cat-file -e "$inspected_head^{commit}" 2>/dev/null || die "inspected head is not a commit: $inspected_head"
current_head="$(git rev-parse HEAD)"
[ "$current_head" != "$(git rev-parse "$inspected_head^{commit}")" ] \
  || die "repair must contain at least one new commit beyond inspected head"
git merge-base --is-ancestor "$inspected_head" "$current_head" \
  || die "inspected head is not an ancestor of repair head"

[ -f "$evidence" ] || die "verification evidence file does not exist: $evidence"
jq -e '.status == "success" and (.command | type == "string" and length > 0) and (.result | type == "string" and length > 0)' \
  "$evidence" >/dev/null 2>&1 || die "verification evidence must record success with nonempty command and result"

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "tracked worktree changes must be clean before finalization"

if git push origin "$current_head:refs/heads/$branch"; then
  echo "pushed $current_head to refs/heads/$branch for issue #$issue PR #$pr"
else
  rc=$?
  echo "failed to push repair branch $branch for PR #$pr" >&2
  exit "$rc"
fi
