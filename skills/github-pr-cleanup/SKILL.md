---
name: github-pr-cleanup
description: Use when manually cleaning the worktree and branch for one terminal GitHub pull request created by the github-issue workflow.
---

# GitHub PR Cleanup

Accept only:

/github-pr-cleanup <pr-number>

Require exactly one numeric PR number. Use the configured GitHub App token helper; never use a PAT, ambient `gh` authentication, another transport, or a fallback. Query the PR once for its state and `closingIssuesReferences`. Continue only for `MERGED` or `CLOSED` with exactly one linked closing issue. Invoke `scripts/cleanup.sh <pr-number> <issue-number>` exactly once and preserve its stdout, stderr, and exit status exactly. Treat `retry` / exit 30 as an error and never retry.

<!-- github-pr-cleanup-manual-entry:start -->
```bash
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
  echo "usage: /github-pr-cleanup <pr-number>" >&2
  exit 2
fi

pr_number="$1"
workspace="$(git rev-parse --show-toplevel)" || exit $?
skill_dir="$workspace/skills/github-pr-cleanup"
if [ ! -x "$skill_dir/scripts/cleanup.sh" ]; then
  echo "github-pr-cleanup is not installed in the current worktree" >&2
  exit 2
fi
origin="$(git remote get-url origin)" || exit $?
case "$origin" in
  https://github.com/*) repo="${origin#https://github.com/}" ;;
  git@github.com:*) repo="${origin#git@github.com:}" ;;
  ssh://git@github.com/*) repo="${origin#ssh://git@github.com/}" ;;
  *) echo "invalid GitHub origin: expected owner/repo on github.com" >&2; exit 2 ;;
esac
repo="${repo%/}"
repo="${repo%.git}"
owner="${repo%%/*}"
repository="${repo#*/}"
if [ -z "$owner" ] || [ -z "$repository" ] || [ "$repository" = "$repo" ] || [[ "$repository" = */* ]]; then
  echo "invalid GitHub origin: expected exactly owner/repo on github.com" >&2
  exit 2
fi

token_helper="${GH_APP_TOKEN_HELPER:-/opt/agent-devcontainer/gh-app-token.sh}"
if [ ! -x "$token_helper" ]; then
  echo "GitHub App token helper is unavailable; run /setup" >&2
  exit 2
fi
token="$(env -u GH_TOKEN -u GITHUB_TOKEN GITHUB_APP_REPO="$repo" "$token_helper")" || exit $?
if [ -z "$token" ]; then
  echo "GitHub App token helper returned an empty token; run /setup" >&2
  exit 2
fi

pr_data="$(GH_TOKEN="$token" GITHUB_TOKEN= gh pr view "$pr_number" --repo "$repo" \
  --json state,closingIssuesReferences \
  --jq '[.state, (.closingIssuesReferences | length), (.closingIssuesReferences[0].number // "")] | @tsv')" || exit $?
IFS=$'\t' read -r state issue_count issue_number extra <<< "$pr_data"
case "$state" in MERGED|CLOSED) ;; *) echo "PR #$pr_number is not terminal" >&2; exit 2 ;; esac
if [ "$issue_count" != 1 ] || ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [ -n "${extra:-}" ]; then
  echo "PR #$pr_number must have exactly one linked closing issue" >&2
  exit 2
fi

exec "$skill_dir/scripts/cleanup.sh" "$pr_number" "$issue_number"
```
<!-- github-pr-cleanup-manual-entry:end -->

## Worktree Warden interface

The automatic Worktree Warden calls `scripts/cleanup.sh <pr-number> <issue-number>` directly with two numeric identifiers. Do not add discovery, polling, scheduling, locking, wrappers, or retries.

Preserve the PR meanings: `MERGED` cleans merged work and may advance `main` and close the issue; `CLOSED` discards only owned PR state without advancing `main` or closing the issue; `OPEN` waits without cleanup. Preserve the script's one JSON stdout record, human stderr diagnostic, and status contract:

| status | exit | meaning |
| --- | ---: | --- |
| `cleaned` | 0 | Cleanup performed work. |
| `already-clean` | 0 | Nothing remained to mutate. |
| `waiting` | 10 | The PR is still open. |
| `blocked` | 20 | State needs human attention. |
| `retry` | 30 | An operational failure occurred; report it as an error and do not retry. |
