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

case "$target_pr" in
  ''|*[!0-9]*) echo "invalid target-pr-number: $target_pr" >&2; exit 1 ;;
esac
case "$origin_pr" in
  ''|*[!0-9]*) echo "invalid origin-pr-number: $origin_pr" >&2; exit 1 ;;
esac
case "$origin_issue" in
  ''|*[!0-9]*) echo "invalid origin-issue-number: $origin_issue" >&2; exit 1 ;;
esac

if [ "$target_pr" = "$origin_pr" ]; then
  echo "target PR cannot be the same as the origin PR" >&2
  exit 1
fi

if [ ! -f "$finding_file" ]; then
  echo "finding file not found: $finding_file" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"
source "$script_dir/lib/marker.sh"

finding_body="$(cat "$finding_file")"
fingerprint="$(compute_fingerprint "$origin_pr" "$origin_issue" "$target_pr" "$finding_body")"

comments_json="$(GH pr view "$target_pr" --json comments)"
existing_fps="$(marker_own_fingerprints "$comments_json" "$MARKER_TAG_CROSSLINK")"

if printf '%s\n' "$existing_fps" | grep -qxF "$fingerprint"; then
  echo "DUPLICATE: finding already cross-linked to PR #$target_pr" >&2
  exit 4
fi

marker_json_body="$(jq -nc \
  --arg fp "$fingerprint" --argjson originPr "$origin_pr" --argjson originIssue "$origin_issue" \
  --argjson targetPr "$target_pr" \
  '{fingerprint: $fp, originPr: $originPr, originIssue: $originIssue, targetPr: $targetPr}')"
marker="$(marker_line "$MARKER_TAG_CROSSLINK" "$marker_json_body")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
  printf 'Cross-linked finding from review of PR #%s (issue #%s):\n\n' "$origin_pr" "$origin_issue"
  cat "$finding_file"
  printf '\n\n%s\n' "$marker"
} > "$tmp"

# `gh pr comment` prints the created comment's URL to stdout — capture it
# instead of letting it leak onto our own stdout, which must stay a single
# line of marker JSON for the caller to parse programmatically.
comment_url="$(GH pr comment "$target_pr" --body-file "$tmp")"

marker_json="$(printf '%s' "$marker_json_body" | jq -c --arg url "$comment_url" '. + {url: $url}')"

echo "PUBLISHED: cross-linked to PR #$target_pr, fingerprint $fingerprint" >&2
printf '%s\n' "$marker_json"
