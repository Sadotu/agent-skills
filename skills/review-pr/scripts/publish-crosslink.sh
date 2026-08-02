#!/usr/bin/env bash
# Cross-links a review-pr finding onto another PR when concrete evidence
# implicates it. Idempotent per (origin PR, origin issue, target PR,
# finding content) — rerunning the same pass doesn't duplicate the
# cross-link comment. Does not re-verify the origin snapshot's freshness;
# by the time cross-links are published, publish-review.sh has already
# confirmed freshness earlier in the same review pass.
#
# Exit codes:
#   0  posted — marker JSON printed to stdout, human status to stderr
#   4  duplicate — already cross-linked; nothing posted
#  other nonzero — genuine script error
#
# Usage: publish-crosslink.sh <target-pr-number> <origin-pr-number> <origin-issue-number> <finding-body-file>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: publish-crosslink.sh <target-pr-number> <origin-pr-number> <origin-issue-number> <finding-body-file>" >&2
  exit 1
fi

target_pr="$1"
origin_pr="$2"
origin_issue="$3"
finding_file="$4"

if [ ! -f "$finding_file" ]; then
  echo "finding file not found: $finding_file" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"
source "$script_dir/lib/marker.sh"

finding_body="$(cat "$finding_file")"
fingerprint="$(compute_fingerprint "$origin_pr" "$origin_issue" "$target_pr" "$finding_body")"

comments_text="$(GH pr view "$target_pr" --json comments -q '.comments[].body')"
existing_markers="$(extract_markers "$comments_text" "$MARKER_TAG_CROSSLINK")"

if [ -n "$existing_markers" ]; then
  while IFS= read -r marker_json; do
    [ -n "$marker_json" ] || continue
    marker_fp="$(printf '%s' "$marker_json" | jq -r .fingerprint)"
    if [ "$marker_fp" = "$fingerprint" ]; then
      echo "DUPLICATE: finding already cross-linked to PR #$target_pr" >&2
      exit 4
    fi
  done <<< "$existing_markers"
fi

marker_json="$(jq -nc \
  --arg fp "$fingerprint" --argjson originPr "$origin_pr" --argjson originIssue "$origin_issue" \
  --argjson targetPr "$target_pr" \
  '{fingerprint: $fp, originPr: $originPr, originIssue: $originIssue, targetPr: $targetPr}')"
marker="$(marker_line "$MARKER_TAG_CROSSLINK" "$marker_json")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  printf 'Cross-linked finding from review of PR #%s (issue #%s):\n\n' "$origin_pr" "$origin_issue"
  cat "$finding_file"
  printf '\n\n%s\n' "$marker"
} > "$tmp"

GH pr comment "$target_pr" --body-file "$tmp"

echo "PUBLISHED: cross-linked to PR #$target_pr, fingerprint $fingerprint" >&2
printf '%s\n' "$marker_json"
