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

# --- All guards passed: validate exact ownership of session-local artifacts
#     before deleting anything. The PR-specific manifest is NUL-delimited so
#     repository paths are never split on whitespace or newlines. ---
case "$pr_number" in
  ''|*[!0-9]*)
    echo "Invalid PR number for artifact manifest: $pr_number" >&2
    exit 1
    ;;
esac

git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
case "$git_common_dir" in
  /*) ;;
  *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
esac
git_common_dir="$(cd "$git_common_dir" && pwd -P)"
artifact_manifest="$git_common_dir/github-issue/artifacts/pr-${pr_number}.paths"

declare -a recorded_artifacts=()
declare -A recorded_artifact_set=()
declare -A artifact_parent_identity=()
artifact_manifest_present=0
if [ -e "$artifact_manifest" ] || [ -L "$artifact_manifest" ]; then
  artifact_manifest_present=1
  if [ ! -f "$artifact_manifest" ] || [ -L "$artifact_manifest" ]; then
    echo "Artifact manifest is not a regular file: $artifact_manifest" >&2
    exit 1
  fi

  while :; do
    artifact_path=''
    if IFS= read -r -d '' artifact_path; then
      case "$artifact_path" in
        docs/superpowers/specs/*-design.md)
          artifact_basename="${artifact_path#docs/superpowers/specs/}"
          ;;
        docs/superpowers/plans/*.md)
          artifact_basename="${artifact_path#docs/superpowers/plans/}"
          ;;
        *)
          printf 'Artifact manifest contains an invalid path: %q\n' "$artifact_path" >&2
          exit 1
          ;;
      esac
      case "$artifact_basename" in
        ''|.|..|*/*)
          printf 'Artifact manifest contains an invalid path: %q\n' "$artifact_path" >&2
          exit 1
          ;;
      esac
      if [ -n "${recorded_artifact_set["$artifact_path"]+present}" ]; then
        printf 'Artifact manifest contains a duplicate path: %q\n' "$artifact_path" >&2
        exit 1
      fi
      recorded_artifact_set["$artifact_path"]=1
      recorded_artifacts+=("$artifact_path")
    else
      if [ -n "$artifact_path" ]; then
        echo "Artifact manifest has trailing data that is not NUL-terminated: $artifact_manifest" >&2
        exit 1
      fi
      break
    fi
  done < "$artifact_manifest"
fi

for artifact_path in "${recorded_artifacts[@]}"; do
  artifact_parent="${artifact_path%/*}"
  if [ ! -d "$ISSUE_WORKTREE/$artifact_parent" ] || [ -L "$ISSUE_WORKTREE/$artifact_parent" ]; then
    printf 'Recorded artifact parent is not a real directory: %q\n' "$artifact_parent" >&2
    exit 1
  fi
  if [ -z "${artifact_parent_identity["$artifact_parent"]+present}" ]; then
    if ! parent_identity="$(stat -Lc '%d:%i' -- "$ISSUE_WORKTREE/$artifact_parent")"; then
      printf 'Cannot identify recorded artifact parent: %q\n' "$artifact_parent" >&2
      exit 1
    fi
    artifact_parent_identity["$artifact_parent"]="$parent_identity"
  fi
  if [ ! -f "$ISSUE_WORKTREE/$artifact_path" ] || [ -L "$ISSUE_WORKTREE/$artifact_path" ]; then
    printf 'Recorded artifact is missing or is not a regular file: %q\n' "$artifact_path" >&2
    exit 1
  fi
  if git -C "$ISSUE_WORKTREE" ls-files --error-unmatch -- "$artifact_path" >/dev/null 2>&1; then
    printf 'Recorded artifact is tracked and will not be deleted: %q\n' "$artifact_path" >&2
    exit 1
  fi
  if ! git -C "$ISSUE_WORKTREE" check-ignore -q -- "$artifact_path"; then
    printf 'Recorded artifact is not ignored: %q\n' "$artifact_path" >&2
    exit 1
  fi
done

artifact_discovery_file="$(mktemp "${TMPDIR:-/tmp}/cleanup-merged-artifacts.XXXXXX")"
cleanup_artifact_discovery_file() {
  if [ -e "$artifact_discovery_file" ]; then
    rm -- "$artifact_discovery_file"
  fi
}
trap cleanup_artifact_discovery_file EXIT

for artifact_discovery in \
  'docs/superpowers/specs:*-design.md' \
  'docs/superpowers/plans:*.md'; do
  artifact_dir="${artifact_discovery%%:*}"
  artifact_pattern="${artifact_discovery#*:}"
  [ -d "$ISSUE_WORKTREE/$artifact_dir" ] || continue
  if ! find "$ISSUE_WORKTREE/$artifact_dir" -mindepth 1 -maxdepth 1 \
    -name "$artifact_pattern" -print0 >> "$artifact_discovery_file"; then
    printf 'Artifact discovery failed in: %q\n' "$artifact_dir" >&2
    exit 1
  fi
done

while IFS= read -r -d '' artifact_file; do
  case "$artifact_file" in
    "$ISSUE_WORKTREE/docs/superpowers/specs/"*) artifact_dir='docs/superpowers/specs' ;;
    "$ISSUE_WORKTREE/docs/superpowers/plans/"*) artifact_dir='docs/superpowers/plans' ;;
    *)
      printf 'Artifact discovery returned an unexpected path: %q\n' "$artifact_file" >&2
      exit 1
      ;;
  esac
  artifact_path="$artifact_dir/${artifact_file##*/}"
  if git -C "$ISSUE_WORKTREE" ls-files --error-unmatch -- "$artifact_path" >/dev/null 2>&1; then
    continue
  fi
  if git -C "$ISSUE_WORKTREE" check-ignore -q -- "$artifact_path" \
    && [ -z "${recorded_artifact_set["$artifact_path"]+present}" ]; then
    printf 'Unrecorded cleanup artifact: %q; record it in the PR artifact manifest or move/remove it manually\n' \
      "$artifact_path" >&2
    exit 1
  fi
done < "$artifact_discovery_file"

# --- Delete only provenance-validated artifacts, remove worktree, delete the
#     local and (if present) remote branch. `cd` into
#     $WORKSPACE first — this may be running from inside $ISSUE_WORKTREE,
#     about to disappear out from under the process's cwd. ---
cd "$WORKSPACE"
for artifact_parent in "${!artifact_parent_identity[@]}"; do
  if ! parent_identity="$(
    cd -P -- "$ISSUE_WORKTREE/$artifact_parent" \
      && stat -Lc '%d:%i' .
  )" || [ "$parent_identity" != "${artifact_parent_identity["$artifact_parent"]}" ]; then
    printf 'Recorded artifact parent changed before deletion: %q\n' "$artifact_parent" >&2
    exit 1
  fi
done
for artifact_path in "${recorded_artifacts[@]}"; do
  artifact_parent="${artifact_path%/*}"
  artifact_basename="${artifact_path##*/}"
  if ! (
    cd -P -- "$ISSUE_WORKTREE/$artifact_parent" \
      && [ "$(stat -Lc '%d:%i' .)" = "${artifact_parent_identity["$artifact_parent"]}" ] \
      && rm -- "./$artifact_basename"
  ); then
    printf 'Recorded artifact parent changed before deletion: %q\n' "$artifact_parent" >&2
    exit 1
  fi
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

if [ "$artifact_manifest_present" -eq 1 ]; then
  rm -- "$artifact_manifest"
  rmdir -- "$git_common_dir/github-issue/artifacts" "$git_common_dir/github-issue" 2>/dev/null || true
fi
