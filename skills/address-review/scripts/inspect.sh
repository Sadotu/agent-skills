#!/usr/bin/env bash
# Validate and describe a managed repair for a blocking review snapshot.
# Usage: inspect.sh <issue-number> <pr-number> <review-fingerprint>
set -euo pipefail

die() { echo "$1" >&2; exit 1; }

[ "$#" -eq 3 ] || die "usage: inspect.sh <issue-number> <pr-number> <review-fingerprint>"
issue="$1"; pr="$2"; fingerprint="$3"
case "$issue" in ''|*[!0-9]*) die "invalid issue-number: $issue" ;; esac
case "$pr" in ''|*[!0-9]*) die "invalid pr-number: $pr" ;; esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
review_lib="$script_dir/../../review-pr/scripts/lib"
source "$review_lib/gh.sh"
source "$review_lib/marker.sh"
source "$review_lib/snapshot.sh"

issue_json="$(GH issue view "$issue" --json labels,body,updatedAt)"
printf '%s' "$issue_json" | jq -e '.labels | any(.name == "agent-running")' >/dev/null \
  || die "issue #$issue is not managed: missing agent-running label"

pr_json="$(GH pr view "$pr" --json body,headRefName,comments)"
pr_body="$(printf '%s' "$pr_json" | jq -r .body)"
branch="$(printf '%s' "$pr_json" | jq -r .headRefName)"
printf '%s\n' "$pr_body" | grep -Eiq "(^|[[:space:]])(close[sd]?|fix(e[sd])?|resolve[sd]?) #${issue}([^0-9]|$)" \
  || die "PR #$pr has no exact closing linkage to issue #$issue"
case "$branch" in "agent/$issue-"*) ;; *) die "PR head '$branch' is not a managed branch agent/$issue-*" ;; esac

worktrees="$(git worktree list --porcelain | awk -v ref="refs/heads/$branch" '
  /^worktree / { path=substr($0,10) }
  $0 == "branch " ref { print path }
')"
worktree_count="$(printf '%s\n' "$worktrees" | awk 'NF { n++ } END { print n+0 }')"
[ "$worktree_count" -eq 1 ] || die "expected exactly one worktree for branch $branch; found $worktree_count"
worktree="$(printf '%s\n' "$worktrees" | awk 'NF { print; exit }')"

trusted_encoded=""; marker_json=""; saw_own_tag=0; saw_fingerprint=0
while IFS= read -r encoded; do
  body="$(printf '%s' "$encoded" | base64 -d)"
  clean_body="$(printf '%s' "$body" | tr -d '\r')"
  tag_count="$(printf '%s\n' "$clean_body" | { grep -oF "<!-- $MARKER_TAG_REVIEW " || true; } | wc -l)"
  payloads="$(extract_markers "$clean_body" "$MARKER_TAG_REVIEW")"
  payload_count="$(printf '%s\n' "$payloads" | awk 'NF { n++ } END { print n+0 }')"
  if [ "$tag_count" -gt 0 ]; then saw_own_tag=1; fi
  [ "$tag_count" -eq "$payload_count" ] || die "trusted review marker is not well-formed"
  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
      die "trusted review marker is not well-formed JSON"
    fi
    payload_fp="$(printf '%s' "$payload" | jq -r '.fingerprint // empty')"
    [ "$payload_fp" = "$fingerprint" ] || continue
    saw_fingerprint=1
    payload_issue="$(printf '%s' "$payload" | jq -r '.issue // empty')"
    payload_pr="$(printf '%s' "$payload" | jq -r '.pr // empty')"
    [ "$payload_issue" = "$issue" ] && [ "$payload_pr" = "$pr" ] \
      || die "trusted review marker issue/pr does not match #$issue/PR #$pr"
    verdict="$(printf '%s' "$payload" | jq -r '.verdict // empty')"
    [ "$verdict" = BLOCKING ] || die "trusted review marker verdict must be BLOCKING"
    [ -z "$trusted_encoded" ] || die "found multiple trusted review markers for fingerprint $fingerprint"
    trusted_encoded="$encoded"
    marker_json="$payload"
  done <<< "$payloads"
done < <(printf '%s' "$pr_json" | jq -r '.comments[] | select(.viewerDidAuthor == true) | .body | @base64')

if [ -z "$trusted_encoded" ]; then
  [ "$saw_own_tag" -eq 0 ] || [ "$saw_fingerprint" -eq 1 ] \
    || die "no trusted review marker for fingerprint $fingerprint (marker may be malformed or for another snapshot)"
  die "no trusted review marker for fingerprint $fingerprint"
fi

snapshot="$(compute_snapshot_json "$pr" "$issue")"
current_fingerprint="$(printf '%s' "$snapshot" | jq -r .fingerprint)"
[ "$current_fingerprint" = "$fingerprint" ] \
  || die "review fingerprint is stale: current snapshot is $current_fingerprint"

printf '%s' "$snapshot" | jq -c \
  --arg branch "$branch" --arg worktree "$worktree" --arg commentBodyBase64 "$trusted_encoded" \
  --argjson marker "$marker_json" \
  '{issue,pr,fingerprint,head,base,$branch,$worktree,commentBody:($commentBodyBase64 | @base64d),$marker}'
