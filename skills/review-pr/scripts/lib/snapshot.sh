#!/usr/bin/env bash
# Shared snapshot computation for skills/review-pr scripts. Sourced, not
# executed. Requires lib/gh.sh (GH) and lib/marker.sh (compute_fingerprint)
# to already be sourced by the caller.

# compute_snapshot_json <pr-number> <issue-number> — prints
# {"issue":N,"pr":N,"head":"sha","base":"sha","issueUpdatedAt":"...","prUpdatedAt":"...","fingerprint":"hex"}.
#
# Snapshot identity (the fingerprint) is the PR's head/base commits plus
# the issue and PR body TEXT — never updatedAt, which also moves on
# label/reviewer/comment changes unrelated to what this skill reviews. The
# UpdatedAt fields are carried through for display in the posted comment
# only.
compute_snapshot_json() {
  local pr="$1" issue="$2"
  local pr_json issue_json head base pr_body issue_body pr_updated_at issue_updated_at fp

  pr_json="$(GH pr view "$pr" --json headRefOid,body,updatedAt)"
  issue_json="$(GH issue view "$issue" --json body,updatedAt)"

  head="$(printf '%s' "$pr_json" | jq -r .headRefOid)"
  base="$(GH api "repos/$REPO/pulls/$pr" --jq .base.sha)"
  pr_body="$(printf '%s' "$pr_json" | jq -r .body)"
  pr_updated_at="$(printf '%s' "$pr_json" | jq -r .updatedAt)"
  issue_body="$(printf '%s' "$issue_json" | jq -r .body)"
  issue_updated_at="$(printf '%s' "$issue_json" | jq -r .updatedAt)"

  fp="$(compute_fingerprint "$head" "$base" "$issue_body" "$pr_body")"

  jq -n \
    --arg issue "$issue" --arg pr "$pr" --arg head "$head" --arg base "$base" \
    --arg issueUpdatedAt "$issue_updated_at" --arg prUpdatedAt "$pr_updated_at" --arg fp "$fp" \
    '{issue: ($issue | tonumber), pr: ($pr | tonumber), head: $head, base: $base,
      issueUpdatedAt: $issueUpdatedAt, prUpdatedAt: $prUpdatedAt, fingerprint: $fp}'
}
