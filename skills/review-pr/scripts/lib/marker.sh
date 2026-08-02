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
