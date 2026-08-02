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
