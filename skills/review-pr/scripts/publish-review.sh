#!/usr/bin/env bash
# Publishes one review-pr pass as a PR comment, enforcing freshness and
# idempotency so an unattended reviewer can never post a stale or
# duplicate review.
#
# Exit codes:
#   0  posted — marker JSON printed to stdout, human status to stderr
#   3  stale — current snapshot no longer matches <expected-fingerprint>;
#      nothing posted. Caller should recapture a fresh snapshot and restart
#      the review.
#   4  duplicate — a review-pr:v1 marker for this exact fingerprint already
#      exists on the PR; nothing posted. This is the idempotent-rerun path,
#      not an error.
#  other nonzero — genuine script error (bad args, gh failure, etc).
#
# Usage: publish-review.sh <pr-number> <issue-number> <expected-fingerprint> <PASS|BLOCKING> <body-file>
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: publish-review.sh <pr-number> <issue-number> <expected-fingerprint> <PASS|BLOCKING> <body-file>" >&2
  exit 1
fi

pr_number="$1"
issue_number="$2"
expected_fingerprint="$3"
verdict="$4"
body_file="$5"

case "$verdict" in
  PASS|BLOCKING) ;;
  *) echo "invalid verdict: $verdict (must be PASS or BLOCKING)" >&2; exit 1 ;;
esac

if [ ! -f "$body_file" ]; then
  echo "body file not found: $body_file" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/gh.sh"
source "$script_dir/lib/marker.sh"
source "$script_dir/lib/snapshot.sh"

current="$(compute_snapshot_json "$pr_number" "$issue_number")"
current_fingerprint="$(printf '%s' "$current" | jq -r .fingerprint)"

if [ "$current_fingerprint" != "$expected_fingerprint" ]; then
  echo "STALE: snapshot changed since capture (expected $expected_fingerprint, now $current_fingerprint)" >&2
  exit 3
fi

head_sha="$(printf '%s' "$current" | jq -r .head)"
base_sha="$(printf '%s' "$current" | jq -r .base)"
issue_updated_at="$(printf '%s' "$current" | jq -r .issueUpdatedAt)"
pr_updated_at="$(printf '%s' "$current" | jq -r .prUpdatedAt)"

comments_text="$(GH pr view "$pr_number" --json comments -q '.comments[].body')"
existing_markers="$(extract_markers "$comments_text" "$MARKER_TAG_REVIEW")"

pass_count=0
already_published=0
if [ -n "$existing_markers" ]; then
  while IFS= read -r marker_json; do
    [ -n "$marker_json" ] || continue
    pass_count=$((pass_count + 1))
    marker_fp="$(printf '%s' "$marker_json" | jq -r .fingerprint)"
    if [ "$marker_fp" = "$current_fingerprint" ]; then
      already_published=1
    fi
  done <<< "$existing_markers"
fi

if [ "$already_published" -eq 1 ]; then
  echo "DUPLICATE: pass already published for fingerprint $current_fingerprint" >&2
  exit 4
fi

pass_number=$((pass_count + 1))

marker_json="$(jq -nc \
  --arg fp "$current_fingerprint" --arg head "$head_sha" --arg base "$base_sha" \
  --arg issueUpdatedAt "$issue_updated_at" --arg prUpdatedAt "$pr_updated_at" \
  --argjson issue "$issue_number" --argjson pr "$pr_number" --argjson pass "$pass_number" \
  --arg verdict "$verdict" \
  '{fingerprint: $fp, head: $head, base: $base, issueUpdatedAt: $issueUpdatedAt, prUpdatedAt: $prUpdatedAt,
    issue: $issue, pr: $pr, pass: $pass, verdict: $verdict}')"
marker="$(marker_line "$MARKER_TAG_REVIEW" "$marker_json")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat "$body_file" > "$tmp"
printf '\n\n%s\n' "$marker" >> "$tmp"

GH pr comment "$pr_number" --body-file "$tmp"

echo "PUBLISHED: pass $pass_number, verdict $verdict, fingerprint $current_fingerprint" >&2
printf '%s\n' "$marker_json"
