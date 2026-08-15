#!/usr/bin/env bash
# Phase 6 handoff for skills/github-issue/SKILL.md.
#
# Both managed and manual runs finish implementation the same way: the PR is
# marked ready for the repository owner. issue-orchestrator keeps
# `agent-running` on a managed issue while the worker is active and releases
# it after observing the ready PR. This helper does not start or label an
# automated review phase.
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

GH pr ready "$pr_number"
echo "implementation complete: PR #$pr_number marked ready for owner review (issue #$issue_number)" >&2
