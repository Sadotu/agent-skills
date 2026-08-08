#!/usr/bin/env bash
# Resolves the exact prior trusted review-pr:v1 PASS marker that an
# integration-mode review claims to build on. Read-only: it fetches PR
# comments and prints the matching marker payload — it never posts,
# edits, or mutates anything.
#
# Exit codes:
#   0  resolved — the prior marker payload (one line of JSON) on stdout
#   5  the prior PASS could not be trusted or resolved; the caller must
#      stop and request a full review instead of an integration pass
#  other nonzero — genuine script error (bad args, gh failure, etc).
#
# Usage: resolve-previous-review.sh <pr-number> <issue-number> <previous-fingerprint>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: resolve-previous-review.sh <pr-number> <issue-number> <previous-fingerprint>" >&2
  exit 1
fi

pr_number="$1"
issue_number="$2"
previous_fingerprint="$3"

case "$pr_number" in
  ''|*[!0-9]*) echo "invalid pr-number: $pr_number" >&2; exit 1 ;;
esac
case "$issue_number" in
  ''|*[!0-9]*) echo "invalid issue-number: $issue_number" >&2; exit 1 ;;
esac
if [ -z "$previous_fingerprint" ]; then
  echo "invalid previous-fingerprint: must not be empty" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"
source "$script_dir/lib/marker.sh"

comments_json="$(GH pr view "$pr_number" --json comments)"

if ! payload="$(resolve_trusted_review_marker \
  "$comments_json" "$previous_fingerprint" "$issue_number" "$pr_number" PASS)"; then
  echo "UNTRUSTED: cannot build an integration review on fingerprint $previous_fingerprint — run a full review" >&2
  exit 5
fi

echo "RESOLVED: prior PASS for fingerprint $previous_fingerprint" >&2
printf '%s\n' "$payload"
