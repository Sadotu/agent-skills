#!/usr/bin/env bash
# Phase 7 ("Post-Merge Cleanup") for skills/github-issue/SKILL.md.
#
# Only ever cleans up once the PR is MERGED, its branch is under agent/*,
# that branch has actually landed in origin/main (as a true merge commit,
# or proven via patch-id equivalence for a squash merge -- see MERGE_MODE
# below; rebase merges are a documented dead end that stops and asks a
# human), and its worktree is clean. Never uses forced worktree removal,
# reset, clean, or a force-push of content. Uses `git branch -D` only via
# the proven-squash path; never on unproven state. The one permitted force
# flag is `--force-with-lease=refs/heads/<branch>:<proven-sha>` on the
# remote deletion, where it constrains the delete to the proven tip rather
# than loosening it.
#
# Restart-safe: every knowable guard is evaluated before the first
# mutation, and a durable journal under the git common directory records
# each completed step so an interrupted run converges on the next
# invocation instead of tripping over the state it already changed.
#
# Machine-readable: exactly one JSON record is written to stdout for every
# outcome; human diagnostics go to stderr only.
#
#   {"status":"cleaned","pr":"40","issue":"28","branch":"agent/28-x",
#    "merge_mode":"regular","reason":"cleanup-complete"}
#
#   status         exit  meaning
#   cleaned          0   this run performed at least one cleanup step
#   already-clean    0   nothing was pending; this run mutated nothing
#   waiting         10   a normal precondition has not happened yet
#   blocked         20   dirty/diverged/ambiguous/unprovable; needs a human
#   retry           30   auth, GitHub, fetch or other operational failure
#
# Usage: cleanup-merged.sh <pr-number> <issue-number>
set -euo pipefail

pr_number=""
issue_number=""
BRANCH=""
MERGE_MODE=""
RECORD_EMITTED=0
ERR_LINE=""

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

json_field() {
  # json_field <name> <value> — an empty value is reported as JSON null so
  # the record keeps a stable shape no matter how early it is emitted.
  if [ -z "${2:-}" ]; then
    printf '"%s":null' "$1"
  else
    printf '"%s":"%s"' "$1" "$(json_escape "$2")"
  fi
}

emit_record() {
  # emit_record <status> <reason> — the single stdout record, at most once.
  if [ "$RECORD_EMITTED" -eq 1 ]; then return 0; fi
  RECORD_EMITTED=1
  printf '{%s,%s,%s,%s,%s,%s}\n' \
    "$(json_field status "$1")" \
    "$(json_field pr "$pr_number")" \
    "$(json_field issue "$issue_number")" \
    "$(json_field branch "$BRANCH")" \
    "$(json_field merge_mode "$MERGE_MODE")" \
    "$(json_field reason "$2")"
}

finish() {
  # finish <status> <reason> [human diagnostic...]
  local status="$1" reason="$2"
  shift 2
  if [ "$#" -gt 0 ]; then printf '%s\n' "$*" >&2; fi
  emit_record "$status" "$reason"
  case "$status" in
    cleaned | already-clean) exit 0 ;;
    waiting) exit 10 ;;
    blocked) exit 20 ;;
    *) exit 30 ;;
  esac
}

on_err() { ERR_LINE="$1"; }
trap 'on_err "$LINENO"' ERR

on_exit() {
  local rc=$?
  if [ "$RECORD_EMITTED" -eq 0 ]; then
    printf 'cleanup-merged: unexpected failure at line %s (exit %s); rerun to converge\n' \
      "${ERR_LINE:-unknown}" "$rc" >&2
    emit_record retry unexpected-failure
    exit 30
  fi
  exit "$rc"
}
trap on_exit EXIT

if [ "$#" -ne 2 ]; then
  finish blocked usage "usage: cleanup-merged.sh <pr-number> <issue-number>"
fi

pr_number="$1"
issue_number="$2"

command -v jq >/dev/null 2>&1 || finish blocked jq-missing "jq is required but not installed"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gh.sh
source "$script_dir/lib/gh.sh" \
  || finish blocked environment-unconfigured "unable to resolve the repository or App credentials"

# --- Guard: resolve the merged branch from the PR, enforce agent/* ---
PR_JSON="$(GH pr view "$pr_number" --json state,headRefName,mergeCommit)" \
  || finish retry pr-view-failed "unable to read PR #$pr_number from GitHub"
BRANCH="$(printf '%s' "$PR_JSON" | jq -r '.headRefName // empty')"
PR_STATE="$(printf '%s' "$PR_JSON" | jq -r '.state // empty')"
merge_sha="$(printf '%s' "$PR_JSON" | jq -r '.mergeCommit.oid // empty')"

case "$PR_STATE" in
  MERGED) ;;
  OPEN) finish waiting pr-open "PR #$pr_number is still open; nothing to clean up yet" ;;
  *) finish blocked pr-closed-unmerged "PR #$pr_number is $PR_STATE without being merged" ;;
esac

case "$BRANCH" in
  agent/*) ;;
  *) finish blocked branch-not-agent "Refusing to delete non-agent branch: $BRANCH" ;;
esac
case "$BRANCH" in
  main | master | develop | release/* | hotfix/*)
    finish blocked protected-branch "Refusing to delete protected branch: $BRANCH"
    ;;
esac

git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
case "$git_common_dir" in
  /*) ;;
  *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
esac
artifact_manifest="$git_common_dir/github-issue/artifacts/pr-${pr_number}.paths"
journal_file="$git_common_dir/github-issue/cleanup/pr-${pr_number}.state"

# --- Durable evidence: what a previous run already completed ---
STEPS=(artifacts worktree local-branch remote-branch main issue manifest)
declare -a done_steps=()
declare -a attempted_steps=()
declare -a journal_artifacts=()
journal_present=0
journal_status=""
journal_head_sha=""
journal_worktree=""

step_done() {
  local step="$1" done
  for done in "${done_steps[@]:-}"; do
    if [ "$done" = "$step" ]; then return 0; fi
  done
  return 1
}

# A step is "attempted" once its intent is durable but its completion is
# not: the mutation may have landed just before the process died. Seeing
# that step's post-state already satisfied is then evidence this workflow
# produced it, so the step converges instead of refusing.
step_attempted() {
  local step="$1" attempted
  for attempted in "${attempted_steps[@]:-}"; do
    if [ "$attempted" = "$step" ]; then return 0; fi
  done
  return 1
}

known_step() {
  local step="$1" candidate
  for candidate in "${STEPS[@]}"; do
    if [ "$candidate" = "$step" ]; then return 0; fi
  done
  return 1
}

if [ -L "$journal_file" ] || { [ -e "$journal_file" ] && [ ! -f "$journal_file" ]; }; then
  finish blocked journal-invalid "Cleanup journal is not a regular file: $journal_file"
fi

if [ -f "$journal_file" ]; then
  journal_present=1
  journal_pr=""
  journal_issue=""
  journal_branch=""
  journal_merge_mode=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then continue; fi
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      pr) journal_pr="$value" ;;
      issue) journal_issue="$value" ;;
      branch) journal_branch="$value" ;;
      merge_mode) journal_merge_mode="$value" ;;
      head_sha) journal_head_sha="$value" ;;
      merge_sha) : ;;
      worktree) journal_worktree="$value" ;;
      artifact) journal_artifacts+=("$value") ;;
      attempted)
        known_step "$value" || finish blocked journal-invalid "Unknown cleanup step in journal: $value"
        attempted_steps+=("$value")
        ;;
      done)
        known_step "$value" || finish blocked journal-invalid "Unknown cleanup step in journal: $value"
        done_steps+=("$value")
        ;;
      status) journal_status="$value" ;;
      *) finish blocked journal-invalid "Unknown key in cleanup journal: $key" ;;
    esac
  done < "$journal_file"

  if [ "$journal_pr" != "$pr_number" ] || [ "$journal_issue" != "$issue_number" ] \
    || [ "$journal_branch" != "$BRANCH" ]; then
    finish blocked journal-mismatch \
      "Cleanup journal describes a different run (pr=$journal_pr issue=$journal_issue branch=$journal_branch)"
  fi
  case "$journal_merge_mode" in
    regular | squash) MERGE_MODE="$journal_merge_mode" ;;
    *) finish blocked journal-invalid "Cleanup journal records no proven merge mode" ;;
  esac
  case "$journal_status" in
    in-progress | cleaned) ;;
    *) finish blocked journal-invalid "Cleanup journal records an unknown status: $journal_status" ;;
  esac
fi

# --- Read-only prep: refresh remote-tracking refs so the merge proof and
#     every later comparison sees current origin state. ---
GIT_AUTH -C "$WORKSPACE" fetch origin '+refs/heads/*:refs/remotes/origin/*' >&2 \
  || finish retry fetch-failed "unable to fetch from origin"

have_local_branch=0
head_sha=""
if git -C "$WORKSPACE" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  have_local_branch=1
  head_sha="$(git -C "$WORKSPACE" rev-parse "refs/heads/$BRANCH")"
fi

# --- Guard: branch's work actually landed in origin/main. Invariant:
#     MERGE_MODE=regular iff the branch tip is an ancestor of origin/main;
#     MERGE_MODE=squash iff not, but the branch diff and mergeCommit diff
#     are proven patch-id equivalent; anything else refuses and asks a
#     human. Known limitation: patch-id hashes diff context lines, so
#     unrelated commits shifting that context can produce a false
#     negative even for a clean squash -- fails safe, left as-is.
#     Once a journal exists the proof is already recorded: after the
#     branch refs are gone there is nothing left to re-derive it from. ---
if [ "$journal_present" -eq 0 ]; then
  if [ "$have_local_branch" -eq 0 ]; then
    finish blocked local-branch-missing \
      "Local branch $BRANCH is absent and no cleanup journal proves a prior cleanup"
  fi

  if git -C "$WORKSPACE" merge-base --is-ancestor "$BRANCH" origin/main; then
    MERGE_MODE=regular
  else
    if [ -n "$merge_sha" ] \
      && git -C "$WORKSPACE" merge-base --is-ancestor "$merge_sha" origin/main; then
      MERGE_PARENT="$(git -C "$WORKSPACE" rev-parse "$merge_sha^")"
      FEATURE_BASE="$(git -C "$WORKSPACE" merge-base "$head_sha" "$MERGE_PARENT")"
      FEATURE_PATCH_ID="$(git -C "$WORKSPACE" diff "$FEATURE_BASE" "$head_sha" | git patch-id --verbatim | awk '{print $1}')"
      SQUASH_PATCH_ID="$(git -C "$WORKSPACE" diff "$MERGE_PARENT" "$merge_sha" | git patch-id --verbatim | awk '{print $1}')"
      if [ -n "$FEATURE_PATCH_ID" ] && [ "$FEATURE_PATCH_ID" = "$SQUASH_PATCH_ID" ]; then
        MERGE_MODE=squash
      fi
    fi

    if [ -z "$MERGE_MODE" ]; then
      finish blocked merge-unprovable \
        "Cannot prove $BRANCH landed in origin/main (not an ancestor, not a provable squash). Refusing automatic cleanup -- verify manually."
    fi
  fi
fi
# --- Guard: the recorded proof only covers the commit it was made
#     against. A branch that moved since then carries work this run never
#     proved landed, so refuse rather than delete it. ---
if [ "$journal_present" -eq 1 ] && [ "$have_local_branch" -eq 1 ]; then
  if [ -z "$journal_head_sha" ]; then
    finish blocked head-sha-unknown \
      "Cleanup journal records no branch tip to re-verify $BRANCH against"
  fi
  if [ "$head_sha" != "$journal_head_sha" ]; then
    finish blocked branch-advanced \
      "Local branch $BRANCH is now $head_sha but cleanup proved $journal_head_sha; refusing to delete unproven work"
  fi
fi
if [ -z "$head_sha" ]; then head_sha="$journal_head_sha"; fi

# --- Plan: evaluate every knowable guard before the first mutation ---
pending_artifacts=0
pending_worktree=0
pending_local_branch=0
pending_remote_branch=0
pending_main=0
pending_issue=0
pending_manifest=0

registered_worktree="$(git -C "$WORKSPACE" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" '
  /^worktree / { wt=substr($0, 10) }
  $0 == "branch " ref { print wt }
')"
issue_worktree=""

if step_done worktree || { step_attempted worktree && [ -z "$registered_worktree" ]; }; then
  if [ -n "$registered_worktree" ]; then
    finish blocked worktree-recreated \
      "A worktree for $BRANCH exists again at $registered_worktree though cleanup already removed one"
  fi
  worktree_converged=1
else
  worktree_converged=0
  if [ -z "$registered_worktree" ]; then
    finish blocked worktree-missing \
      "No worktree is registered for $BRANCH and no cleanup journal proves a prior removal"
  fi
  if [ ! -d "$registered_worktree" ]; then
    finish blocked worktree-missing \
      "Worktree $registered_worktree is registered for $BRANCH but its directory is gone"
  fi
  worktree_status="$(git -C "$registered_worktree" status --porcelain)" \
    || finish retry worktree-status-failed "unable to read the status of $registered_worktree"
  if [ -n "$worktree_status" ]; then
    finish blocked worktree-dirty "Worktree $registered_worktree has uncommitted changes"
  fi
  issue_worktree="$registered_worktree"
  pending_worktree=1
fi

# --- Session artifacts: only the two paths Phase 3 recorded, and only
#     when they are still untracked, ignored, regular files. ---
declare -a session_artifacts=()
declare -A session_artifact_set=()

validate_artifact_paths() {
  local artifact_path artifact_parent artifact_basename
  if [ "${#session_artifacts[@]}" -ne 2 ]; then
    finish blocked manifest-invalid "Artifact manifest must contain exactly one design and one plan path"
  fi
  for artifact_path in "${session_artifacts[@]}"; do
    case "$artifact_path" in
      docs/superpowers/specs/*-design.md) artifact_parent='docs/superpowers/specs' ;;
      docs/superpowers/plans/*.md) artifact_parent='docs/superpowers/plans' ;;
      *) finish blocked manifest-invalid "$(printf 'Invalid artifact manifest path: %q' "$artifact_path")" ;;
    esac
    artifact_basename="${artifact_path##*/}"
    if [ "$artifact_path" != "$artifact_parent/$artifact_basename" ]; then
      finish blocked manifest-invalid "$(printf 'Invalid artifact manifest path: %q' "$artifact_path")"
    fi
    if [ -n "${session_artifact_set["$artifact_path"]+present}" ]; then
      finish blocked manifest-invalid "$(printf 'Duplicate artifact manifest path: %q' "$artifact_path")"
    fi
    session_artifact_set["$artifact_path"]=1
  done
}

if step_done artifacts || [ "$worktree_converged" -eq 1 ]; then
  # Either this run's predecessor removed them, or they went with the
  # worktree that predecessor already removed.
  pending_artifacts=0
else
  if [ -L "$artifact_manifest" ] || { [ -e "$artifact_manifest" ] && [ ! -f "$artifact_manifest" ]; }; then
    finish blocked manifest-invalid "Artifact manifest is not a regular file: $artifact_manifest"
  fi
  if [ -f "$artifact_manifest" ]; then
    mapfile -t session_artifacts < "$artifact_manifest"
    validate_artifact_paths
  elif [ "${#journal_artifacts[@]}" -gt 0 ]; then
    session_artifacts=("${journal_artifacts[@]}")
    validate_artifact_paths
  fi

  for artifact_path in "${session_artifacts[@]:-}"; do
    if [ -z "$artifact_path" ]; then continue; fi
    if [ ! -e "$issue_worktree/$artifact_path" ] && step_attempted artifacts; then
      continue
    fi
    if [ ! -f "$issue_worktree/$artifact_path" ] || [ -L "$issue_worktree/$artifact_path" ]; then
      finish blocked artifact-missing \
        "$(printf 'Recorded artifact is missing or not a regular file: %q' "$artifact_path")"
    fi
    if git -C "$issue_worktree" ls-files --error-unmatch -- "$artifact_path" >/dev/null 2>&1; then
      finish blocked artifact-tracked \
        "$(printf 'Recorded artifact is tracked and will be preserved: %q' "$artifact_path")"
    fi
    if ! git -C "$issue_worktree" check-ignore -q -- "$artifact_path"; then
      finish blocked artifact-not-ignored \
        "$(printf 'Recorded artifact is not ignored: %q' "$artifact_path")"
    fi
  done

  shopt -s nullglob
  for candidate in \
    "$issue_worktree"/docs/superpowers/specs/*-design.md \
    "$issue_worktree"/docs/superpowers/plans/*.md; do
    candidate_path="${candidate#"$issue_worktree/"}"
    if git -C "$issue_worktree" ls-files --error-unmatch -- "$candidate_path" >/dev/null 2>&1; then
      continue
    fi
    if [ -z "${session_artifact_set["$candidate_path"]+present}" ]; then
      shopt -u nullglob
      finish blocked unrecorded-artifact \
        "$(printf 'Unrecorded cleanup candidate: %q; move/remove it manually' "$candidate_path")"
    fi
  done
  shopt -u nullglob

  if [ "${#session_artifacts[@]}" -gt 0 ]; then pending_artifacts=1; fi
fi

if step_done local-branch || { step_attempted local-branch && [ "$have_local_branch" -eq 0 ]; }; then
  if [ "$have_local_branch" -eq 1 ]; then
    finish blocked local-branch-recreated \
      "Local branch $BRANCH exists again though cleanup already deleted it"
  fi
else
  if [ "$have_local_branch" -eq 0 ]; then
    finish blocked local-branch-missing \
      "Local branch $BRANCH is absent and no cleanup journal proves a prior deletion"
  fi
  pending_local_branch=1
fi

# --- Guard: the remote ref must still be the tip the merge proof covers.
#     Existence alone proves nothing -- the branch may have been advanced
#     with commits that never landed in main. ---
if ! step_done remote-branch; then
  if remote_ls="$(GIT_AUTH ls-remote --exit-code --heads origin "refs/heads/$BRANCH" 2>/dev/null)"; then
    remote_sha="$(printf '%s\n' "$remote_ls" | awk 'NR == 1 { print $1 }')"
    if [ -z "$head_sha" ] || [ -z "$remote_sha" ]; then
      finish blocked remote-branch-unverifiable \
        "Cannot re-verify origin/$BRANCH against the proven branch tip"
    fi
    if [ "$remote_sha" != "$head_sha" ]; then
      finish blocked remote-branch-advanced \
        "origin/$BRANCH is now $remote_sha but cleanup proved $head_sha; refusing to delete unproven work"
    fi
    pending_remote_branch=1
  else
    ls_remote_rc=$?
    case "$ls_remote_rc" in
      2) pending_remote_branch=0 ;;
      *) finish retry ls-remote-failed "unable to list origin's branches" ;;
    esac
  fi
fi

if ! step_done main; then
  main_sha="$(git -C "$WORKSPACE" rev-parse --verify --quiet refs/heads/main)" \
    || finish blocked main-missing "No local main branch to fast-forward"
  origin_main_sha="$(git -C "$WORKSPACE" rev-parse --verify --quiet refs/remotes/origin/main)" \
    || finish retry origin-main-missing "origin/main is unavailable after fetching"
  if [ "$main_sha" != "$origin_main_sha" ]; then
    if [ "$(git -C "$WORKSPACE" branch --show-current)" != main ]; then
      finish blocked primary-not-on-main "The primary worktree is not on main; cannot fast-forward it"
    fi
    if ! git -C "$WORKSPACE" merge-base --is-ancestor main origin/main; then
      finish blocked main-diverged "Local main has diverged from origin/main"
    fi
    if [ -n "$(git -C "$WORKSPACE" status --porcelain --untracked-files=no)" ]; then
      finish blocked primary-worktree-dirty \
        "The primary worktree has uncommitted changes; refusing to fast-forward main"
    fi
    pending_main=1
  fi
fi

if ! step_done issue; then
  issue_state="$(GH issue view "$issue_number" --json state -q .state)" \
    || finish retry issue-view-failed "unable to read issue #$issue_number from GitHub"
  if [ "$issue_state" != CLOSED ]; then pending_issue=1; fi
fi

if [ -f "$artifact_manifest" ]; then pending_manifest=1; fi

# --- Execute: every guard has passed; mutate in a convergent order and
#     record each completed step before moving on. ---
journal_write() {
  local status="$1" tmp step artifact
  mkdir -p "$(dirname "$journal_file")"
  tmp="$journal_file.tmp.$$"
  {
    printf 'pr=%s\n' "$pr_number"
    printf 'issue=%s\n' "$issue_number"
    printf 'branch=%s\n' "$BRANCH"
    printf 'merge_mode=%s\n' "$MERGE_MODE"
    printf 'head_sha=%s\n' "$head_sha"
    printf 'merge_sha=%s\n' "$merge_sha"
    printf 'worktree=%s\n' "${issue_worktree:-$journal_worktree}"
    for artifact in "${session_artifacts[@]:-}"; do
      if [ -n "$artifact" ]; then printf 'artifact=%s\n' "$artifact"; fi
    done
    for step in "${attempted_steps[@]:-}"; do
      if [ -n "$step" ]; then printf 'attempted=%s\n' "$step"; fi
    done
    for step in "${done_steps[@]:-}"; do
      if [ -n "$step" ]; then printf 'done=%s\n' "$step"; fi
    done
    printf 'status=%s\n' "$status"
  } > "$tmp"
  mv -- "$tmp" "$journal_file"
}

mark_attempted() {
  if ! step_attempted "$1"; then
    attempted_steps+=("$1")
    journal_write in-progress
  fi
}

mark_done() {
  done_steps+=("$1")
  journal_write in-progress
}

performed=0
if [ "$pending_artifacts" -eq 1 ] || [ "$pending_worktree" -eq 1 ] \
  || [ "$pending_local_branch" -eq 1 ] || [ "$pending_remote_branch" -eq 1 ] \
  || [ "$pending_main" -eq 1 ] || [ "$pending_issue" -eq 1 ] || [ "$pending_manifest" -eq 1 ]; then
  performed=1
fi

# `cd` into $WORKSPACE first — this may be running from inside the issue
# worktree, about to disappear out from under the process's cwd.
cd "$WORKSPACE"

if [ "$performed" -eq 1 ]; then
  journal_write in-progress
fi

# Each step runs only when the plan found it pending, and is recorded as
# done either way: a step that converged before this run started is just
# as complete as one this run performed.
if [ "$pending_artifacts" -eq 1 ]; then
  mark_attempted artifacts
  for artifact_path in "${session_artifacts[@]}"; do
    if [ -e "$issue_worktree/$artifact_path" ]; then rm -- "$issue_worktree/$artifact_path"; fi
  done
fi
if ! step_done artifacts; then
  mark_done artifacts
fi

if [ "$pending_worktree" -eq 1 ]; then
  mark_attempted worktree
  git worktree remove "$issue_worktree" >&2
  git worktree prune >&2
fi
if ! step_done worktree; then
  mark_done worktree
fi

if [ "$pending_local_branch" -eq 1 ]; then
  mark_attempted local-branch
  if [ "$MERGE_MODE" = regular ]; then
    git branch -d "$BRANCH" >&2
  else
    # MERGE_MODE=squash only: reachable exclusively via the guard stack
    # above (PR MERGED + agent/* + clean worktree + proven patch-id
    # equivalence). `branch -d` would refuse here since the tip genuinely
    # isn't an ancestor by git's own definition; `-D` bypasses that check.
    # Never use -D on any other path; never loosen this gate.
    git branch -D "$BRANCH" >&2
  fi
fi
if ! step_done local-branch; then
  mark_done local-branch
fi

if [ "$pending_remote_branch" -eq 1 ]; then
  # The plan-time SHA comparison goes stale: artifact, worktree and local
  # branch removal all happen between it and this push. The lease carries
  # the expected tip into the deletion itself, so origin rejects the push
  # if the ref moved in that window. Despite the option's name this is the
  # opposite of a force-push -- a plain `--delete` removes whatever the
  # ref points at now. This is the only permitted force flag, it is only
  # ever a deletion, and its expected value is always the proven tip.
  if ! GIT_AUTH push --force-with-lease="refs/heads/$BRANCH:$head_sha" origin --delete "$BRANCH" >&2; then
    if remote_ls="$(GIT_AUTH ls-remote --exit-code --heads origin "refs/heads/$BRANCH" 2>/dev/null)"; then
      ls_remote_rc=0
    else
      ls_remote_rc=$?
    fi
    case "$ls_remote_rc" in
      0)
        remote_sha="$(printf '%s\n' "$remote_ls" | awk 'NR == 1 { print $1 }')"
        if [ "$remote_sha" != "$head_sha" ]; then
          finish blocked remote-branch-advanced \
            "origin/$BRANCH moved to $remote_sha while cleanup was running; refusing to delete unproven work"
        fi
        finish retry remote-delete-failed "unable to delete origin/$BRANCH"
        ;;
      2) : ;; # already gone: the deletion goal is satisfied
      *) finish retry remote-delete-failed \
        "unable to confirm origin/$BRANCH after a failed delete" ;;
    esac
  fi
fi
if ! step_done remote-branch; then
  mark_done remote-branch
fi

# --- Fast-forward local main without resetting or cleaning user files ---
if [ "$pending_main" -eq 1 ]; then
  git merge --ff-only origin/main >&2
  test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
fi
if ! step_done main; then
  mark_done main
fi

# --- Confirm the issue closed; close it manually if GitHub didn't ---
if [ "$pending_issue" -eq 1 ]; then
  GH issue close "$issue_number" >&2 || finish retry issue-close-failed "unable to close issue #$issue_number"
fi
if ! step_done issue; then
  mark_done issue
fi

if [ "$pending_manifest" -eq 1 ]; then
  rm -- "$artifact_manifest"
fi
if ! step_done manifest; then
  mark_done manifest
fi

if [ "$performed" -eq 1 ] || [ "$journal_present" -eq 1 ]; then
  journal_write cleaned
fi

if [ "$performed" -eq 1 ]; then
  finish cleaned cleanup-complete
fi
finish already-clean nothing-to-clean
