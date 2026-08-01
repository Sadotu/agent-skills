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

if printf '%s\n' "$issue_labels" | grep -qxF 'agent-running'; then
  echo "managed run (issue #$issue_number carries agent-running) — not implemented yet" >&2
  exit 1
else
  GH pr ready "$pr_number"
fi
