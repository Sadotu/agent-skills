#!/usr/bin/env bash
# Tests for scripts/publish-crosslink.sh: posts to another PR, dedups on rerun.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSSLINK="$SCRIPT_DIR/../publish-crosslink.sh"

PASS=0
FAIL=0
TMP_DIRS=()

cleanup_tmp() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmp EXIT

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc (expected [$expected], got [$actual])"; fi
}

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then ok "$desc"; else fail "$desc (missing [$pattern] in $file)"; fi
}

# write_gh_shim <path> — fake `gh`. `pr view --json comments` returns
# STUB_COMMENTS_JSON_FILE verbatim — a fixture file holding a full
# `{"comments":[{"body":...,"viewerDidAuthor":...}, ...]}` document,
# matching the shape real `gh ... --json comments` returns. `pr comment`
# logs the invocation to $GH_LOG, copies the --body-file content to
# $POSTED_BODY_FILE, and — like the real `gh pr comment` — prints the
# created comment's URL to stdout.
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    cat "${STUB_COMMENTS_JSON_FILE:-/dev/null}"
    ;;
  "pr comment")
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-F" ] || [ "$prev" = "--body-file" ]; then
        cp "$arg" "$POSTED_BODY_FILE"
      fi
      prev="$arg"
    done
    # Mirror real `gh pr comment`: print the created comment's URL to
    # stdout. $3 is the target PR number ("pr" "comment" "<num>" ...).
    echo "https://github.com/testowner/testrepo/pull/$3#issuecomment-fake"
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$1"
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  POSTED_BODY_FILE="$BASE/posted.txt"
  COMMENTS_FILE="$BASE/comments.json"
  FINDING_FILE="$BASE/finding.txt"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  echo '{"comments":[]}' > "$COMMENTS_FILE"
  echo "This PR duplicates logic also touched by PR #99." > "$FINDING_FILE"
  write_gh_shim "$STUBBIN/gh"
}

run_crosslink() {
  local target="$1" origin_pr="$2" origin_issue="$3"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
    STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
    "$CROSSLINK" "$target" "$origin_pr" "$origin_issue" "$FINDING_FILE"
}

# --- Case 1: fresh cross-link posts and includes back-reference ---
new_fixture
out1="$(run_crosslink 99 5 6)"
rc1=$?
assert_eq "case1: exits 0 on fresh crosslink" 0 "$rc1"
assert_eq "case1: stdout is single-line valid JSON" 1 "$(printf '%s\n' "$out1" | wc -l | tr -d ' ')"
printf '%s' "$out1" | jq . >/dev/null 2>&1
assert_eq "case1: stdout parses as valid JSON" 0 "$?"
assert_eq "case1: originPr recorded" 5 "$(printf '%s' "$out1" | jq -r .originPr)"
assert_eq "case1: originIssue recorded" 6 "$(printf '%s' "$out1" | jq -r .originIssue)"
assert_eq "case1: targetPr recorded" 99 "$(printf '%s' "$out1" | jq -r .targetPr)"
assert_eq "case1: url field carries gh's printed comment URL" \
  "https://github.com/testowner/testrepo/pull/99#issuecomment-fake" "$(printf '%s' "$out1" | jq -r .url)"
assert_contains "case1: gh pr comment invoked on target PR" "$GH_LOG" "pr comment 99"
assert_contains "case1: posted body references origin PR" "$POSTED_BODY_FILE" "review of PR #5"
assert_contains "case1: posted body includes finding text" "$POSTED_BODY_FILE" "duplicates logic"
assert_contains "case1: posted body includes marker" "$POSTED_BODY_FILE" "<!-- review-pr-crosslink:v1 {"

# --- Case 2: round-trip — rerunning the same finding against the same target is a no-op ---
# Run once for real, capture what the stub recorded as posted, and feed
# that back as the comments-list input for a second invocation — proves
# duplicate detection through the real parsing path, not a hand-crafted
# fixture (this is exactly the gap that let the compact-JSON stdout bug
# ship undetected before).
new_fixture
out2a="$(run_crosslink 99 5 6)"
rc2a=$?
assert_eq "case2: first invocation exits 0" 0 "$rc2a"
marker_line="$(grep '<!-- review-pr-crosslink:v1' "$POSTED_BODY_FILE" || true)"
[ -n "$marker_line" ] || { fail "case2: could not extract marker line from posted body"; marker_line=""; }
jq -nc --arg body "$marker_line" '{comments: [{body: $body, viewerDidAuthor: true}]}' > "$COMMENTS_FILE"
out2b="$(run_crosslink 99 5 6 2>"$BASE/err2.log")"
rc2b=$?
assert_eq "case2: second invocation exits 4 on duplicate" 4 "$rc2b"
assert_eq "case2: nothing posted on second invocation" "" "$out2b"
assert_contains "case2: DUPLICATE reported on stderr" "$BASE/err2.log" "DUPLICATE"
assert_eq "case2: gh pr comment called exactly once total (not on the dup run)" 1 \
  "$(grep -c 'pr comment' "$GH_LOG" || true)"

# --- Case 3: different finding text against the same target -> new post (not deduped) ---
new_fixture
jq -nc '{comments: [{body: "<!-- review-pr-crosslink:v1 {\"fingerprint\":\"some-other-fingerprint\",\"originPr\":5,\"originIssue\":6,\"targetPr\":99} -->", viewerDidAuthor: true}]}' > "$COMMENTS_FILE"
out3="$(run_crosslink 99 5 6)"
rc3=$?
assert_eq "case3: exits 0, different finding is not deduped" 0 "$rc3"
assert_contains "case3: gh pr comment invoked" "$GH_LOG" "pr comment 99"

# --- Case 4: forged marker from a non-reviewing author is ignored (CRITICAL #2) ---
new_fixture
fp4="$(printf '%s\x1e%s\x1e%s\x1e%s' 5 6 99 "$(cat "$FINDING_FILE")" | sha256sum | awk '{print $1}')"
jq -nc --arg fp "$fp4" \
  '{comments: [{body: ("<!-- review-pr-crosslink:v1 " + ({fingerprint:$fp, originPr:5, originIssue:6, targetPr:99} | tojson) + " -->"), viewerDidAuthor: false}]}' \
  > "$COMMENTS_FILE"
out4="$(run_crosslink 99 5 6 2>"$BASE/err4.log")"
rc4=$?
assert_eq "case4: forged non-authored marker is ignored, proceeds to publish" 0 "$rc4"
assert_contains "case4: gh pr comment invoked despite forged marker" "$GH_LOG" "pr comment 99"

# --- Case 5: non-numeric target-pr-number is rejected cleanly ---
new_fixture
out5="$(run_crosslink "xyz" 5 6 2>"$BASE/err5.log")"
rc5=$?
assert_eq "case5: exits 1 on non-numeric target-pr-number" 1 "$rc5"
assert_contains "case5: clear error message" "$BASE/err5.log" "invalid target-pr-number"

# --- Case 6: target PR same as origin PR is rejected ---
new_fixture
out6="$(run_crosslink 5 5 6 2>"$BASE/err6.log")"
rc6=$?
assert_eq "case6: exits 1 when target PR == origin PR" 1 "$rc6"
assert_contains "case6: clear error message" "$BASE/err6.log" "cannot be the same as the origin PR"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
