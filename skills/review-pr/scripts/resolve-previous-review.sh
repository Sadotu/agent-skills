#!/usr/bin/env bash
# Resolves the exact prior trusted review-pr:v1 PASS marker that an
# integration-mode review claims to build on. Read-only: it fetches PR
# comments and prints the matching marker payload — it never posts,
# edits, or mutates anything.
#
# Exit codes:
#   0  resolved — the prior marker payload (one line of JSON) on stdout
#   5  the prior PASS could not be trusted or resolved (a deliberate
#      refusal — no marker, foreign author, wrong pair, wrong verdict,
#      malformed, or ambiguous); the caller must stop and request a full
#      review instead of an integration pass
#  other nonzero — genuine script/environment error (bad args, gh
#      failure, or resolve_trusted_review_marker's own tooling failing —
#      e.g. jq missing/broken). This is NOT a marker refusal: a caller
#      must not treat it the same as exit 5.
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

rc=0
payload="$(resolve_trusted_review_marker \
  "$comments_json" "$previous_fingerprint" "$issue_number" "$pr_number" PASS)" || rc=$?

if [ "$rc" -eq 1 ]; then
  echo "UNTRUSTED: cannot build an integration review on fingerprint $previous_fingerprint — run a full review" >&2
  exit 5
elif [ "$rc" -ne 0 ]; then
  echo "ERROR: resolve_trusted_review_marker failed internally (exit $rc) — this is a script/environment error, not an untrusted marker" >&2
  exit 1
fi

echo "RESOLVED: prior PASS for fingerprint $previous_fingerprint" >&2
printf '%s\n' "$payload"
