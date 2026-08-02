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

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
