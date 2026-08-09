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
GIT_AUTH -C "$WORKSPACE" fetch origin

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

# --- All guards passed: delete only the two session artifacts recorded by
#     Phase 3. Matching tracked files and unrecorded files are preserved. ---
git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
case "$git_common_dir" in
  /*) ;;
  *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
esac
artifact_manifest="$git_common_dir/github-issue/artifacts/pr-${pr_number}.paths"

declare -a session_artifacts=()
declare -A session_artifact_set=()
if [ -f "$artifact_manifest" ] && [ ! -L "$artifact_manifest" ]; then
  mapfile -t session_artifacts < "$artifact_manifest"
  if [ "${#session_artifacts[@]}" -ne 2 ]; then
    echo "Artifact manifest must contain exactly one design and one plan path" >&2
    exit 1
  fi

  for artifact_path in "${session_artifacts[@]}"; do
    case "$artifact_path" in
      docs/superpowers/specs/*-design.md) artifact_parent='docs/superpowers/specs' ;;
      docs/superpowers/plans/*.md) artifact_parent='docs/superpowers/plans' ;;
      *) printf 'Invalid artifact manifest path: %q\n' "$artifact_path" >&2; exit 1 ;;
    esac
    artifact_basename="${artifact_path##*/}"
    if [ "$artifact_path" != "$artifact_parent/$artifact_basename" ]; then
      printf 'Invalid artifact manifest path: %q\n' "$artifact_path" >&2
      exit 1
    fi
    if [ -n "${session_artifact_set["$artifact_path"]+present}" ]; then
      printf 'Duplicate artifact manifest path: %q\n' "$artifact_path" >&2
      exit 1
    fi
    session_artifact_set["$artifact_path"]=1

    if [ ! -f "$ISSUE_WORKTREE/$artifact_path" ] || [ -L "$ISSUE_WORKTREE/$artifact_path" ]; then
      printf 'Recorded artifact is missing or not a regular file: %q\n' "$artifact_path" >&2
      exit 1
    fi
    if git -C "$ISSUE_WORKTREE" ls-files --error-unmatch -- "$artifact_path" >/dev/null 2>&1; then
      printf 'Recorded artifact is tracked and will be preserved: %q\n' "$artifact_path" >&2
      exit 1
    fi
    if ! git -C "$ISSUE_WORKTREE" check-ignore -q -- "$artifact_path"; then
      printf 'Recorded artifact is not ignored: %q\n' "$artifact_path" >&2
      exit 1
    fi
  done
elif [ -e "$artifact_manifest" ] || [ -L "$artifact_manifest" ]; then
  echo "Artifact manifest is not a regular file: $artifact_manifest" >&2
  exit 1
fi

shopt -s nullglob
for candidate in \
  "$ISSUE_WORKTREE"/docs/superpowers/specs/*-design.md \
  "$ISSUE_WORKTREE"/docs/superpowers/plans/*.md; do
  candidate_path="${candidate#"$ISSUE_WORKTREE/"}"
  if git -C "$ISSUE_WORKTREE" ls-files --error-unmatch -- "$candidate_path" >/dev/null 2>&1; then
    continue
  fi
  if [ -z "${session_artifact_set["$candidate_path"]+present}" ]; then
    printf 'Unrecorded cleanup candidate: %q; move/remove it manually\n' "$candidate_path" >&2
    exit 1
  fi
done
shopt -u nullglob

# --- Remove validated artifacts, then continue the existing cleanup flow.
#     delete the local and (if present) remote branch. `cd` into
#     $WORKSPACE first — this may be running from inside $ISSUE_WORKTREE,
#     about to disappear out from under the process's cwd. ---
cd "$WORKSPACE"
for artifact_path in "${session_artifacts[@]}"; do
  rm -- "$ISSUE_WORKTREE/$artifact_path"
done
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
if GIT_AUTH ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  GIT_AUTH push origin --delete "$BRANCH"
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

if [ -f "$artifact_manifest" ] && [ ! -L "$artifact_manifest" ]; then
  rm -- "$artifact_manifest"
fi
