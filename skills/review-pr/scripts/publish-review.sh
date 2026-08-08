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
#   5  the prior trusted PASS named by --previous-fingerprint could not be
#      resolved; nothing posted. The caller must run a full review.
#  other nonzero — genuine script error (bad args, gh failure, etc).
#
# Usage: publish-review.sh <pr-number> <issue-number> <expected-fingerprint> <PASS|BLOCKING> <body-file> [--mode integration --previous-fingerprint <fingerprint>]
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: publish-review.sh <pr-number> <issue-number> <expected-fingerprint> <PASS|BLOCKING> <body-file> [--mode integration --previous-fingerprint <fingerprint>]" >&2
  exit 1
fi

pr_number="$1"
issue_number="$2"
expected_fingerprint="$3"
verdict="$4"
body_file="$5"
shift 5

# mode_seen/previous_fingerprint_seen track whether the flag was passed at
# all, distinct from whether its value ended up non-empty. This matters for
# fail-closed validation: `--mode ""` must be a usage error, not silently
# fall through to a full review just because $mode is empty (the same
# state as "flag never passed").
mode=""
previous_fingerprint=""
mode_seen=0
previous_fingerprint_seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      [ "$#" -ge 2 ] || { echo "--mode requires a value (only 'integration' is valid)" >&2; exit 1; }
      mode="$2"; mode_seen=1; shift 2 ;;
    --previous-fingerprint)
      [ "$#" -ge 2 ] || { echo "--previous-fingerprint requires a value" >&2; exit 1; }
      previous_fingerprint="$2"; previous_fingerprint_seen=1; shift 2 ;;
    *)
      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ "$mode_seen" -eq 1 ] && [ "$mode" != integration ]; then
  echo "invalid mode: $mode (only 'integration' is valid; omit --mode for a full review)" >&2
  exit 1
fi
if [ "$previous_fingerprint_seen" -eq 1 ] && [ -z "$previous_fingerprint" ]; then
  echo "invalid --previous-fingerprint: must not be empty" >&2
  exit 1
fi
if [ "$mode_seen" -eq 1 ] && [ "$previous_fingerprint_seen" -eq 0 ]; then
  echo "--mode integration requires --previous-fingerprint <fingerprint>" >&2
  exit 1
fi
if [ "$mode_seen" -eq 0 ] && [ "$previous_fingerprint_seen" -eq 1 ]; then
  echo "--previous-fingerprint requires --mode integration" >&2
  exit 1
fi

case "$pr_number" in
  ''|*[!0-9]*) echo "invalid pr-number: $pr_number" >&2; exit 1 ;;
esac
case "$issue_number" in
  ''|*[!0-9]*) echo "invalid issue-number: $issue_number" >&2; exit 1 ;;
esac

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

comments_json="$(GH pr view "$pr_number" --json comments)"

previous_marker=""
if [ -n "$mode" ]; then
  rc=0
  previous_marker="$(resolve_trusted_review_marker \
    "$comments_json" "$previous_fingerprint" "$issue_number" "$pr_number" PASS)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "UNTRUSTED: cannot publish an integration review on fingerprint $previous_fingerprint — run a full review" >&2
    exit 5
  elif [ "$rc" -ne 0 ]; then
    echo "ERROR: resolve_trusted_review_marker failed internally (exit $rc) — this is a script/environment error, not an untrusted marker" >&2
    exit 1
  fi
fi

existing_fps="$(marker_own_fingerprints "$comments_json" "$MARKER_TAG_REVIEW")"

pass_count="$(printf '%s\n' "$existing_fps" | grep -c . || true)"
already_published=0
if printf '%s\n' "$existing_fps" | grep -qxF "$current_fingerprint"; then
  already_published=1
fi

if [ "$already_published" -eq 1 ]; then
  echo "DUPLICATE: pass already published for fingerprint $current_fingerprint" >&2
  exit 4
fi

pass_number=$((pass_count + 1))

# The marker is posted before we know the comment's own URL (the URL is
# only known once `gh pr comment` returns it), so build the comment body
# with a placeholder-free marker first, post, then re-emit the marker JSON
# (stdout only, not the posted comment body) with the URL added.
marker_json_body="$(jq -nc \
  --arg fp "$current_fingerprint" --arg head "$head_sha" --arg base "$base_sha" \
  --arg issueUpdatedAt "$issue_updated_at" --arg prUpdatedAt "$pr_updated_at" \
  --argjson issue "$issue_number" --argjson pr "$pr_number" --argjson pass "$pass_number" \
  --arg verdict "$verdict" \
  '{fingerprint: $fp, head: $head, base: $base, issueUpdatedAt: $issueUpdatedAt, prUpdatedAt: $prUpdatedAt,
    issue: $issue, pr: $pr, pass: $pass, verdict: $verdict}')"

if [ -n "$mode" ]; then
  marker_json_body="$(printf '%s' "$marker_json_body" | jq -c \
    --arg mode "$mode" --arg prev "$previous_fingerprint" \
    '. + {mode: $mode, previousFingerprint: $prev}')"
fi

marker="$(marker_line "$MARKER_TAG_REVIEW" "$marker_json_body")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "$mode" ]; then
  # Generated, not authored: the acceptance contract requires every
  # integration comment to name its mode and both snapshots' head/base, so
  # it must not depend on the reviewer remembering to write them.
  previous_head="$(printf '%s' "$previous_marker" | jq -r '.head')"
  previous_base="$(printf '%s' "$previous_marker" | jq -r '.base')"
  {
    printf '**Integration review** — revalidating an earlier `PASS` against the current base.\n\n'
    printf -- '- Previous snapshot: head `%s`, base `%s` (fingerprint `%s`)\n' \
      "$previous_head" "$previous_base" "$previous_fingerprint"
    printf -- '- Current snapshot: head `%s`, base `%s` (fingerprint `%s`)\n\n' \
      "$head_sha" "$base_sha" "$current_fingerprint"
  } > "$tmp"
  cat "$body_file" >> "$tmp"
else
  cat "$body_file" > "$tmp"
fi
printf '\n\n%s\n' "$marker" >> "$tmp"

# `gh pr comment` prints the created comment's URL to stdout — capture it
# instead of letting it leak onto our own stdout, which must stay a single
# line of marker JSON for the caller to parse programmatically.
comment_url="$(GH pr comment "$pr_number" --body-file "$tmp")"

marker_json="$(printf '%s' "$marker_json_body" | jq -c --arg url "$comment_url" '. + {url: $url}')"

echo "PUBLISHED: pass $pass_number, verdict $verdict, fingerprint $current_fingerprint" >&2
printf '%s\n' "$marker_json"
