#!/usr/bin/env bash
# Tests for scripts/lib/marker.sh (fingerprint + marker build/extract).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/marker.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc (expected [$expected], got [$actual])"; fi
}

# --- compute_fingerprint: deterministic ---
fp1="$(compute_fingerprint head1 base1 issuebody prbody)"
fp2="$(compute_fingerprint head1 base1 issuebody prbody)"
assert_eq "fingerprint is deterministic" "$fp1" "$fp2"

# --- compute_fingerprint: sensitive to each input independently ---
base_fp="$(compute_fingerprint headA baseA issueA prA)"
assert_eq "changing head changes fingerprint" 1 \
  "$([ "$base_fp" != "$(compute_fingerprint headB baseA issueA prA)" ] && echo 1 || echo 0)"
assert_eq "changing base changes fingerprint" 1 \
  "$([ "$base_fp" != "$(compute_fingerprint headA baseB issueA prA)" ] && echo 1 || echo 0)"
assert_eq "changing issue body changes fingerprint" 1 \
  "$([ "$base_fp" != "$(compute_fingerprint headA baseA issueB prA)" ] && echo 1 || echo 0)"
assert_eq "changing pr body changes fingerprint" 1 \
  "$([ "$base_fp" != "$(compute_fingerprint headA baseA issueA prB)" ] && echo 1 || echo 0)"

# --- compute_fingerprint: no ambiguous concatenation across the boundary ---
fp_split_ab_c="$(compute_fingerprint ab c same same)"
fp_split_a_bc="$(compute_fingerprint a bc same same)"
assert_eq "no concatenation collision across arg boundary" 1 \
  "$([ "$fp_split_ab_c" != "$fp_split_a_bc" ] && echo 1 || echo 0)"

# --- marker_line: exact format ---
line="$(marker_line "review-pr:v1" '{"a":1}')"
assert_eq "marker_line format" '<!-- review-pr:v1 {"a":1} -->' "$line"

# --- extract_markers: single marker embedded in surrounding text ---
text="Some review text.

<!-- review-pr:v1 {\"fingerprint\":\"abc123\",\"pass\":1} -->

More text after."
extracted="$(extract_markers "$text" "review-pr:v1")"
assert_eq "extract_markers finds single embedded marker" '{"fingerprint":"abc123","pass":1}' "$extracted"

# --- extract_markers: multiple markers, one per line ---
text_multi="<!-- review-pr:v1 {\"pass\":1} -->
some text
<!-- review-pr:v1 {\"pass\":2} -->"
extracted_multi="$(extract_markers "$text_multi" "review-pr:v1")"
expected_multi='{"pass":1}
{"pass":2}'
assert_eq "extract_markers finds multiple markers in order" "$expected_multi" "$extracted_multi"

# --- extract_markers: wrong tag matches nothing ---
extracted_wrong_tag="$(extract_markers "$text" "review-pr-crosslink:v1")"
assert_eq "extract_markers with wrong tag returns empty" "" "$extracted_wrong_tag"

# --- extract_markers: no marker present returns empty ---
extracted_none="$(extract_markers "plain comment, no marker here" "review-pr:v1")"
assert_eq "extract_markers with no marker returns empty" "" "$extracted_none"

# --- marker_own_fingerprints: only viewerDidAuthor:true markers count ---
comments_mixed="$(jq -n '{comments: [
  {viewerDidAuthor: true,  body: "<!-- review-pr:v1 {\"fingerprint\":\"own-fp\",\"pass\":1} -->"},
  {viewerDidAuthor: false, body: "<!-- review-pr:v1 {\"fingerprint\":\"forged-fp\",\"pass\":99} -->"}
]}')"
own_fps="$(marker_own_fingerprints "$comments_mixed" "review-pr:v1")"
assert_eq "marker_own_fingerprints excludes non-viewerDidAuthor markers" "own-fp" "$own_fps"

# --- marker_own_fingerprints: no own markers returns empty, doesn't crash ---
comments_none_own="$(jq -n '{comments: [
  {viewerDidAuthor: false, body: "<!-- review-pr:v1 {\"fingerprint\":\"forged-fp\"} -->"}
]}')"
none_own="$(marker_own_fingerprints "$comments_none_own" "review-pr:v1")"
rc_none_own=$?
assert_eq "marker_own_fingerprints returns empty when no own markers" "" "$none_own"
assert_eq "marker_own_fingerprints exits 0 when no own markers" 0 "$rc_none_own"

# --- marker_own_fingerprints: own marker with valid JSON but no fingerprint
# key is skipped, not fatal, and does not stop other valid markers from
# being returned (regression: an earlier version's while-loop last
# statement was `[ -n "$fp" ] && printf ...`, whose false branch made the
# loop's own exit status 1 on the final skipped item, which killed any
# `set -e` caller via `existing_fps="$(marker_own_fingerprints ...)"`) ---
comments_no_fp_field="$(jq -n '{comments: [
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"note\":\"hi\"} -->"}
]}')"
no_fp_out="$(marker_own_fingerprints "$comments_no_fp_field" "review-pr:v1")"
rc_no_fp=$?
assert_eq "marker_own_fingerprints skips own marker missing fingerprint key" "" "$no_fp_out"
assert_eq "marker_own_fingerprints exits 0 (not fatal) when fingerprint key missing" 0 "$rc_no_fp"

comments_no_fp_then_valid="$(jq -n '{comments: [
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"note\":\"hi\"} -->"},
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"fingerprint\":\"real-fp\"} -->"}
]}')"
mixed_out="$(marker_own_fingerprints "$comments_no_fp_then_valid" "review-pr:v1")"
assert_eq "marker_own_fingerprints returns later valid fingerprint after skipping one missing it" "real-fp" "$mixed_out"

# --- marker_own_fingerprints: malformed JSON payload (two marker-shaped
# substrings on one line) is skipped, not fatal ---
comments_malformed="$(jq -n '{comments: [
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"a\":1} --> x <!-- review-pr:v1 {\"b\":2} -->"}
]}')"
malformed_out="$(marker_own_fingerprints "$comments_malformed" "review-pr:v1")"
rc_malformed=$?
assert_eq "marker_own_fingerprints skips malformed marker payload" "" "$malformed_out"
assert_eq "marker_own_fingerprints exits 0 (not fatal) on malformed payload" 0 "$rc_malformed"

# --- marker_own_fingerprints: CRLF-terminated own marker still matches ---
comments_crlf="$(jq -n '{comments: [
  {viewerDidAuthor: true, body: "line one\r\n<!-- review-pr:v1 {\"fingerprint\":\"crlf-fp\"} -->\r\nline two"}
]}')"
crlf_out="$(marker_own_fingerprints "$comments_crlf" "review-pr:v1")"
assert_eq "marker_own_fingerprints strips CRLF before matching" "crlf-fp" "$crlf_out"

# --- marker_own_fingerprints: multiple own markers, all returned in order ---
comments_multi_own="$(jq -n '{comments: [
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"fingerprint\":\"fp-a\"} -->"},
  {viewerDidAuthor: true, body: "<!-- review-pr:v1 {\"fingerprint\":\"fp-b\"} -->"}
]}')"
multi_out="$(marker_own_fingerprints "$comments_multi_own" "review-pr:v1")"
expected_multi_own='fp-a
fp-b'
assert_eq "marker_own_fingerprints returns all own markers in order" "$expected_multi_own" "$multi_out"

# --- resolve_trusted_review_marker ---

# rtm_comments <comment-json...> — builds {"comments":[...]}.
rtm_comments() { jq -nc --argjson c "[$(IFS=,; echo "$*")]" '{comments: $c}'; }

# rtm_marker <fp> <issue> <pr> <verdict> [viewerDidAuthor] — one own comment
# carrying a well-formed review-pr:v1 marker.
rtm_marker() {
  local fp="$1" issue="$2" pr="$3" verdict="$4" author="${5:-true}"
  jq -nc --arg fp "$fp" --argjson issue "$issue" --argjson pr "$pr" \
    --arg verdict "$verdict" --argjson author "$author" \
    '{body: ("Review text\n\n<!-- review-pr:v1 "
             + ({fingerprint:$fp, issue:$issue, pr:$pr, pass:1, verdict:$verdict} | tojson)
             + " -->"),
      viewerDidAuthor: $author}'
}

out="$(resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker abc123 27 34 PASS)")" abc123 27 34 PASS)"
assert_eq "resolve: exits 0 on a valid trusted marker" 0 "$?"
assert_eq "resolve: prints the matching payload" "abc123" "$(printf '%s' "$out" | jq -r .fingerprint)"
assert_eq "resolve: payload carries prior verdict" "PASS" "$(printf '%s' "$out" | jq -r .verdict)"

resolve_trusted_review_marker "$(rtm_comments)" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects when no markers exist" 1 "$?"

resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker abc123 27 34 PASS false)")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a foreign-authored marker" 1 "$?"

resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker other 27 34 PASS)")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a marker for another fingerprint" 1 "$?"

resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker abc123 99 34 PASS)")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a marker for another issue" 1 "$?"

resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker abc123 27 99 PASS)")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a marker for another PR" 1 "$?"

resolve_trusted_review_marker "$(rtm_comments "$(rtm_marker abc123 27 34 BLOCKING)")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a BLOCKING marker when PASS is required" 1 "$?"

malformed='{"body":"<!-- review-pr:v1 not json -->","viewerDidAuthor":true}'
resolve_trusted_review_marker "$(rtm_comments "$malformed")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects a malformed own marker payload" 1 "$?"

resolve_trusted_review_marker \
  "$(rtm_comments "$(rtm_marker abc123 27 34 PASS)" "$(rtm_marker abc123 27 34 PASS)")" \
  abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: rejects two trusted markers for the same fingerprint" 1 "$?"

crlf="$(jq -nc --arg fp abc123 '{body: ("x\r\n<!-- review-pr:v1 " + ({fingerprint:$fp, issue:27, pr:34, pass:1, verdict:"PASS"} | tojson) + " -->\r"), viewerDidAuthor: true}')"
resolve_trusted_review_marker "$(rtm_comments "$crlf")" abc123 27 34 PASS >/dev/null 2>&1
assert_eq "resolve: tolerates CRLF line endings from a web-UI edit" 0 "$?"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
