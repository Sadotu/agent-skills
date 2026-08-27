#!/usr/bin/env bash
# Phase 6 handoff for skills/github-issue/SKILL.md.
#
# Both managed and manual runs finish implementation the same way: the PR
# leaves WIP state and receives the existing owner-review label. This helper
# does not start an automated review, repair, approval, or merge phase.
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

title="$(GH pr view "$pr_number" --json title -q .title)"
title="${title#WIP: }"
GH label create user-merge-review --force || :
GH pr edit "$pr_number" --title "$title" --add-label user-merge-review
echo "implementation complete: PR #$pr_number labeled for owner review (issue #$issue_number)" >&2
