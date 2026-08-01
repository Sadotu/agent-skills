#!/usr/bin/env bash
# Phase 6 label-driven handoff for skills/github-issue/SKILL.md.
#
# Reads the `agent-running` label on the linked issue as the sole signal
# that issue-orchestrator owns this run's lifecycle:
#
#   - Managed (issue has `agent-running`): keep the PR draft, add
#     `agent-running` to the PR, and replace any other `agent-*` phase
#     label on issue and PR with `agent-review`. `agent-running` on the
#     issue is never touched.
#   - Manual (issue has no `agent-running`): unchanged current behavior —
#     `gh pr ready`, no label mutation at all.
#
# Every mutation this script performs (gh label create --force, gh issue/pr
# edit --add-label/--remove-label, gh pr ready) is idempotent in `gh`
# itself, so rerunning after a partial failure simply reissues the same
# calls and converges — no bespoke state tracking needed.
#
# Usage: finish-handoff.sh <pr-number> <issue-number>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: finish-handoff.sh <pr-number> <issue-number>" >&2
  exit 1
fi

pr_number="$1"
issue_number="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"

issue_labels="$(GH issue view "$issue_number" --json labels -q '.labels[].name')"

is_stray_phase_label() {
  # Any agent-* label that isn't the durable agent-running marker or the
  # agent-review target label counts as "the phase label" to replace —
  # github-issue doesn't own the orchestrator's phase-label vocabulary,
  # so it can't hardcode a specific prior name.
  case "$1" in
    agent-running|agent-review) return 1 ;;
    agent-*) return 0 ;;
    *) return 1 ;;
  esac
}

if printf '%s\n' "$issue_labels" | grep -qxF 'agent-running'; then
  # Managed run: issue-orchestrator owns lifecycle. Leave the PR draft;
  # swap the phase label for agent-review on both issue and PR.
  GH label create agent-review --force >/dev/null 2>&1 || true

  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if is_stray_phase_label "$label"; then
      GH issue edit "$issue_number" --remove-label "$label"
    fi
  done <<< "$issue_labels"
  GH issue edit "$issue_number" --add-label agent-review

  GH pr edit "$pr_number" --add-label agent-running

  pr_labels="$(GH pr view "$pr_number" --json labels -q '.labels[].name')"
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if is_stray_phase_label "$label"; then
      GH pr edit "$pr_number" --remove-label "$label"
    fi
  done <<< "$pr_labels"
  GH pr edit "$pr_number" --add-label agent-review
else
  # Manual run: unchanged current behavior.
  GH pr ready "$pr_number"
fi
