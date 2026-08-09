#!/usr/bin/env bash
# Shared marker/fingerprint helpers for skills/review-pr scripts. Sourced,
# not executed.
#
# A "marker" is a single-line HTML comment embedded in a PR comment body,
# carrying a compact JSON payload. Because the JSON is built with jq's
# default compact output (no embedded newlines), a marker always survives
# as one complete line inside a multi-line comment body, so it can be found
# with a plain line-anchored regex regardless of what else is in the
# comment.

MARKER_TAG_REVIEW="review-pr:v1"
MARKER_TAG_CROSSLINK="review-pr-crosslink:v1"

# compute_fingerprint <a> <b> <c> <d> — sha256 of the four inputs joined by
# a record-separator byte (\x1e), so concatenation can't collide across
# inputs (e.g. "ab"+"c" vs "a"+"bc").
compute_fingerprint() {
  printf '%s\x1e%s\x1e%s\x1e%s' "$1" "$2" "$3" "$4" | sha256sum | awk '{print $1}'
}

# marker_line <tag> <json> — builds one complete marker line (no trailing
# newline; callers add their own).
marker_line() {
  printf '<!-- %s %s -->' "$1" "$2"
}

# extract_markers <text> <tag> — prints one JSON payload per line for every
# <tag> marker line found in <text>. Empty output if none found.
extract_markers() {
  printf '%s\n' "$1" | sed -nE "s/^<!-- ${2} (\{.*\}) -->\$/\1/p"
}

# marker_own_fingerprints <comments-json> <tag> — given the raw JSON object
# from `gh ... --json comments` (i.e. {"comments":[...]}), returns one
# fingerprint per line for every <tag> marker actually authored by the
# reviewing identity (viewerDidAuthor) — comments from anyone else are
# never trusted as markers, since the fingerprint they'd need to forge is
# derivable from public PR/issue data. Skips malformed marker payloads
# instead of crashing the caller under `set -e` (a crafted comment body
# can't take the script down). CR-strips first so a web-UI edit that
# introduces CRLF line endings doesn't silently break extract_markers's
# line-anchored regex.
marker_own_fingerprints() {
  local comments_json="$1" tag="$2" own_bodies payload fp
  own_bodies="$(printf '%s' "$comments_json" | jq -r '.comments[] | select(.viewerDidAuthor) | .body')" || return 1
  own_bodies="$(printf '%s' "$own_bodies" | tr -d '\r')"
  extract_markers "$own_bodies" "$tag" | while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    fp="$(printf '%s' "$payload" | jq -r '.fingerprint // empty' 2>/dev/null)" || continue
    [ -n "$fp" ] || continue
    printf '%s\n' "$fp"
  done
}

# resolve_trusted_review_marker <comments-json> <fingerprint> <issue> <pr> <required-verdict>
# — given the raw JSON object from `gh ... --json comments`, proves that
# exactly ONE marker authored by the reviewing identity (viewerDidAuthor)
# matches <fingerprint> AND names <issue>/<pr> AND carries
# <required-verdict>, then prints that marker's payload as one line of
# JSON. Returns 1 with a reason on stderr for a deliberate refusal, or 2
# with a reason on stderr when its own tooling fails (e.g. jq missing or
# comments_json unreadable, or a marker body that fails to base64-decode)
# — callers must not treat 2 the same as 1: it means "this environment is
# broken", not "no trusted prior verdict".
#
# Fail-closed on purpose: a malformed own marker anywhere on the PR, or
# two markers claiming the same fingerprint, refuses rather than picking
# one — a caller relying on a prior verdict must not act on an ambiguous
# or tampered history. Foreign-authored comments are never considered
# (the fingerprint is derivable from public data, so an outsider could
# otherwise forge a PASS).
resolve_trusted_review_marker() {
  local comments_json="$1" want_fp="$2" want_issue="$3" want_pr="$4" want_verdict="$5"
  local encoded body clean tag_count payloads payload_count payload
  local found="" saw_fingerprint=0
  local encoded_bodies

  encoded_bodies="$(printf '%s' "$comments_json" \
    | jq -r '.comments[] | select(.viewerDidAuthor == true) | .body | @base64')" || {
    echo "internal error: failed to read PR comments as JSON (is jq available and working?)" >&2
    return 2
  }

  while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    if ! body="$(printf '%s' "$encoded" | base64 -d)"; then
      echo "internal error: failed to base64-decode a marker comment body" >&2
      return 2
    fi
    clean="$(printf '%s' "$body" | tr -d '\r')"
    tag_count="$(printf '%s\n' "$clean" | { grep -oF "<!-- $MARKER_TAG_REVIEW " || true; } | wc -l)"
    [ "$tag_count" -gt 0 ] || continue
    payloads="$(extract_markers "$clean" "$MARKER_TAG_REVIEW")"
    payload_count="$(printf '%s\n' "$payloads" | awk 'NF { n++ } END { print n+0 }')"
    if [ "$tag_count" -ne "$payload_count" ]; then
      echo "previous review marker is not well-formed" >&2
      return 1
    fi
    while IFS= read -r payload; do
      [ -n "$payload" ] || continue
      if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "previous review marker is not well-formed JSON" >&2
        return 1
      fi
      [ "$(printf '%s' "$payload" | jq -r '.fingerprint // empty')" = "$want_fp" ] || continue
      saw_fingerprint=1
      if [ "$(printf '%s' "$payload" | jq -r '.issue // empty')" != "$want_issue" ] \
        || [ "$(printf '%s' "$payload" | jq -r '.pr // empty')" != "$want_pr" ]; then
        echo "previous review marker issue/pr does not match #$want_issue/PR #$want_pr" >&2
        return 1
      fi
      if [ "$(printf '%s' "$payload" | jq -r '.verdict // empty')" != "$want_verdict" ]; then
        echo "previous review marker verdict must be $want_verdict" >&2
        return 1
      fi
      if ! printf '%s' "$payload" | jq -e '
        (.head | type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$")) and
        (.base | type == "string" and test("^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$"))
      ' >/dev/null 2>&1; then
        echo "previous review marker head/base must be full commit IDs" >&2
        return 1
      fi
      if [ -n "$found" ]; then
        echo "found multiple trusted review markers for fingerprint $want_fp" >&2
        return 1
      fi
      found="$payload"
    done <<< "$payloads"
  done <<< "$encoded_bodies"

  if [ -z "$found" ]; then
    if [ "$saw_fingerprint" -eq 1 ]; then
      echo "no trusted review marker for fingerprint $want_fp" >&2
    else
      echo "no trusted review marker for fingerprint $want_fp (missing, or authored by another identity)" >&2
    fi
    return 1
  fi

  printf '%s\n' "$found"
}
