#!/usr/bin/env bash
# Tests for scripts/publish-review.sh: staleness, duplicate skip, pass
# numbering, and posting.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="$SCRIPT_DIR/../publish-review.sh"

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
  # "--" stops grep from parsing a pattern that itself starts with "--"
  # (e.g. "--previous-fingerprint") as an option flag.
  if grep -qF -- "$pattern" "$file"; then ok "$desc"; else fail "$desc (missing [$pattern] in $file)"; fi
}

# write_gh_shim <path> — fake `gh`. `pr view --json headRefOid,...` (no
# comments) returns PR JSON from STUB_HEAD/STUB_PR_BODY/STUB_PR_UPDATED.
# `api repos/testowner/testrepo/pulls/<pr> --jq .base.sha` returns
# STUB_BASE. `issue view` returns issue JSON from
# STUB_ISSUE_BODY/STUB_ISSUE_UPDATED. `pr view --json comments` returns
# STUB_COMMENTS_JSON_FILE verbatim — a fixture file holding a full
# `{"comments":[{"body":...,"viewerDidAuthor":...}, ...]}` document, exactly
# matching the shape real `gh ... --json comments` returns (each comment
# carries `viewerDidAuthor`, true only for comments authored by the
# reviewing identity). `pr comment` logs the invocation to $GH_LOG, copies
# the --body-file content to $POSTED_BODY_FILE, and — like the real
# `gh pr comment` — prints the created comment's URL to stdout.
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    if printf '%s\n' "$*" | grep -q -- '--json comments'; then
      cat "${STUB_COMMENTS_JSON_FILE:-/dev/null}"
    else
      jq -n --arg head "$STUB_HEAD" --arg body "$STUB_PR_BODY" --arg updated "$STUB_PR_UPDATED" \
        '{headRefOid:$head, body:$body, updatedAt:$updated}'
    fi
    ;;
  "api "*)
    if [ "$#" -eq 4 ] && [[ "$2" =~ ^repos/testowner/testrepo/pulls/[0-9]+$ ]] \
      && [ "$3" = "--jq" ] && [ "$4" = ".base.sha" ]; then
      echo "$STUB_BASE"
    else
      echo "unexpected gh api invocation: $*" >&2
      exit 1
    fi
    ;;
  "issue view")
    jq -n --arg body "$STUB_ISSUE_BODY" --arg updated "$STUB_ISSUE_UPDATED" \
      '{body:$body, updatedAt:$updated}'
    ;;
  "pr comment")
    # Find the file after -F/--body-file.
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-F" ] || [ "$prev" = "--body-file" ]; then
        cp "$arg" "$POSTED_BODY_FILE"
      fi
      prev="$arg"
    done
    # Mirror real `gh pr comment`: print the created comment's URL to
    # stdout. $3 is the PR number ("pr" "comment" "<num>" ...).
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
  BODY_FILE="$BASE/review-body.txt"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  echo '{"comments":[]}' > "$COMMENTS_FILE"
  echo "Review findings go here." > "$BODY_FILE"
  write_gh_shim "$STUBBIN/gh"
}

# marker_comment <fingerprint> <pass> <verdict> [viewerDidAuthor] — builds
# one comments.json entry (default viewerDidAuthor=true) carrying a
# review-pr:v1 marker for the given fingerprint.
marker_comment() {
  local fp="$1" pass="$2" verdict="$3" author="${4:-true}"
  jq -nc --arg fp "$fp" --argjson pass "$pass" --arg verdict "$verdict" --argjson author "$author" \
    '{body: ("<!-- review-pr:v1 " + ({fingerprint:$fp, pass:$pass, verdict:$verdict} | tojson) + " -->"),
      viewerDidAuthor: $author}'
}

# write_comments <comment-json...> — writes {"comments":[...]} from the
# given comment JSON objects (one per arg) into $COMMENTS_FILE.
write_comments() {
  jq -nc --argjson comments "[$(IFS=,; echo "$*")]" '{comments: $comments}' > "$COMMENTS_FILE"
}

run_snapshot() {
  local pr="$1" issue="$2"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" STUB_REPO="testowner/testrepo" \
    STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
    STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
    "$SCRIPT_DIR/../snapshot.sh" "$pr" "$issue" | jq -r .fingerprint
}

run_publish() {
  local pr="$1" issue="$2" fp="$3" verdict="$4"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
    STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
    STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
    STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
    "$PUBLISH" "$pr" "$issue" "$fp" "$verdict" "$BODY_FILE"
}

common_stubs() {
  STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z"
  STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z"
}

# --- Case 1: fresh snapshot, no prior markers -> posts pass 1, PASS ---
new_fixture
common_stubs
fp="$(run_snapshot 5 6)"
out1="$(run_publish 5 6 "$fp" PASS)"
rc1=$?
assert_eq "case1: exits 0 on fresh publish" 0 "$rc1"
assert_eq "case1: stdout is single-line valid JSON" 1 "$(printf '%s\n' "$out1" | wc -l | tr -d ' ')"
printf '%s' "$out1" | jq . >/dev/null 2>&1
assert_eq "case1: stdout parses as valid JSON" 0 "$?"
assert_eq "case1: pass 1" 1 "$(printf '%s' "$out1" | jq -r .pass)"
assert_eq "case1: verdict PASS" "PASS" "$(printf '%s' "$out1" | jq -r .verdict)"
assert_eq "case1: url field carries gh's printed comment URL" \
  "https://github.com/testowner/testrepo/pull/5#issuecomment-fake" "$(printf '%s' "$out1" | jq -r .url)"
assert_contains "case1: gh pr comment invoked" "$GH_LOG" "pr comment 5"
assert_contains "case1: posted body includes original review text" "$POSTED_BODY_FILE" "Review findings go here."
assert_contains "case1: posted body includes marker" "$POSTED_BODY_FILE" "<!-- review-pr:v1 {"

# --- Case 2: stale — expected fingerprint doesn't match current ---
new_fixture
common_stubs
out2="$(run_publish 5 6 "not-the-real-fingerprint" PASS 2>"$BASE/err.log")"
rc2=$?
assert_eq "case2: exits 3 on stale" 3 "$rc2"
assert_eq "case2: nothing posted on stale" "" "$out2"
assert_contains "case2: STALE reported on stderr" "$BASE/err.log" "STALE"
assert_eq "case2: gh pr comment never called" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 3: duplicate — a marker for this fingerprint already exists ---
new_fixture
common_stubs
fp3="$(run_snapshot 5 6)"
write_comments "$(marker_comment "$fp3" 1 PASS)"
out3="$(run_publish 5 6 "$fp3" PASS 2>"$BASE/err3.log")"
rc3=$?
assert_eq "case3: exits 4 on duplicate" 4 "$rc3"
assert_eq "case3: nothing posted on duplicate" "" "$out3"
assert_contains "case3: DUPLICATE reported on stderr" "$BASE/err3.log" "DUPLICATE"
assert_eq "case3: gh pr comment never called" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 4: pass number increments across a genuinely new snapshot ---
new_fixture
common_stubs
fp4a="$(run_snapshot 5 6)"
write_comments "$(marker_comment "$fp4a" 1 PASS)"
STUB_PR_BODY="pr text, now changed"
fp4b="$(run_snapshot 5 6)"
out4="$(run_publish 5 6 "$fp4b" BLOCKING)"
assert_eq "case4: pass number increments to 2" 2 "$(printf '%s' "$out4" | jq -r .pass)"
assert_eq "case4: verdict BLOCKING" "BLOCKING" "$(printf '%s' "$out4" | jq -r .verdict)"

# --- Case 5: round-trip — a marker this script actually posted is later recognized as a duplicate ---
new_fixture
common_stubs
fp5="$(run_snapshot 5 6)"
# First invocation: publish a marker
out5a="$(run_publish 5 6 "$fp5" PASS 2>/dev/null)"
rc5a=$?
assert_eq "case5: first invocation exits 0" 0 "$rc5a"
# Capture the actual posted body (includes review text + marker)
assert_contains "case5: posted body contains marker" "$POSTED_BODY_FILE" "<!-- review-pr:v1 {"
# Extract just the marker line and feed it back as an own (viewerDidAuthor)
# comment for the second invocation — this is a genuine round trip through
# the real posting + parsing path, not a hand-crafted fixture.
marker_line="$(grep '<!-- review-pr:v1' "$POSTED_BODY_FILE" || true)"
[ -n "$marker_line" ] || { fail "case5: could not extract marker line from posted body"; marker_line=""; }
jq -nc --arg body "$marker_line" '{comments: [{body: $body, viewerDidAuthor: true}]}' > "$COMMENTS_FILE"
# Second invocation: same PR, issue, fingerprint — should detect duplicate
out5b="$(run_publish 5 6 "$fp5" PASS 2>"$BASE/err5.log")"
rc5b=$?
assert_eq "case5: second invocation exits 4 on duplicate" 4 "$rc5b"
assert_eq "case5: nothing posted on second invocation" "" "$out5b"
assert_contains "case5: DUPLICATE reported on stderr" "$BASE/err5.log" "DUPLICATE"

# --- Case 6: forged marker from a non-reviewing author is ignored (CRITICAL #2) ---
new_fixture
common_stubs
fp6="$(run_snapshot 5 6)"
# A marker with the *real* fingerprint, but NOT authored by the reviewing
# identity (viewerDidAuthor:false) — e.g. posted by an arbitrary PR
# commenter who computed the public fingerprint themselves. Must not be
# trusted as a duplicate marker.
write_comments "$(marker_comment "$fp6" 1 PASS false)"
out6="$(run_publish 5 6 "$fp6" PASS 2>"$BASE/err6.log")"
rc6=$?
assert_eq "case6: forged non-authored marker is ignored, proceeds to publish" 0 "$rc6"
assert_eq "case6: pass 1 (forged marker not counted)" 1 "$(printf '%s' "$out6" | jq -r .pass)"
assert_contains "case6: gh pr comment invoked despite forged marker" "$GH_LOG" "pr comment 5"

# --- Case 7: malformed marker payload doesn't crash the script (IMPORTANT #3) ---
new_fixture
common_stubs
fp7="$(run_snapshot 5 6)"
malformed_body='<!-- review-pr:v1 {"a":1} --> x <!-- review-pr:v1 {"b":2} -->'
jq -nc --arg body "$malformed_body" '{comments: [{body: $body, viewerDidAuthor: true}]}' > "$COMMENTS_FILE"
out7="$(run_publish 5 6 "$fp7" PASS 2>"$BASE/err7.log")"
rc7=$?
assert_eq "case7: malformed marker doesn't crash, still exits 0" 0 "$rc7"
assert_eq "case7: malformed marker not counted as a valid pass" 1 "$(printf '%s' "$out7" | jq -r .pass)"

# --- Case 8: non-numeric pr-number is rejected cleanly ---
new_fixture
common_stubs
out8="$(run_publish "abc" 6 "somefp" PASS 2>"$BASE/err8.log")"
rc8=$?
assert_eq "case8: exits 1 on non-numeric pr-number" 1 "$rc8"
assert_contains "case8: clear error message" "$BASE/err8.log" "invalid pr-number"

# --- Case 9: staleness is independently sensitive to each snapshot input ---
new_fixture
common_stubs
fp9="$(run_snapshot 5 6)"

new_fixture
STUB_HEAD="CHANGED-HEAD" STUB_BASE="cafef00d" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z"
STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z"
out9a="$(run_publish 5 6 "$fp9" PASS 2>"$BASE/err9a.log")"
assert_eq "case9: head-only change -> stale (exit 3)" 3 "$?"
assert_contains "case9: head-only change reports STALE" "$BASE/err9a.log" "STALE"

new_fixture
STUB_HEAD="deadbeef" STUB_BASE="CHANGED-BASE" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z"
STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z"
out9b="$(run_publish 5 6 "$fp9" PASS 2>"$BASE/err9b.log")"
assert_eq "case9: base-only change -> stale (exit 3)" 3 "$?"
assert_contains "case9: base-only change reports STALE" "$BASE/err9b.log" "STALE"

new_fixture
STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z"
STUB_ISSUE_BODY="CHANGED issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z"
out9c="$(run_publish 5 6 "$fp9" PASS 2>"$BASE/err9c.log")"
assert_eq "case9: issue-body-only change -> stale (exit 3)" 3 "$?"
assert_contains "case9: issue-body-only change reports STALE" "$BASE/err9c.log" "STALE"

new_fixture
STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="CHANGED pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z"
STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z"
out9d="$(run_publish 5 6 "$fp9" PASS 2>"$BASE/err9d.log")"
assert_eq "case9: pr-body-only change -> stale (exit 3)" 3 "$?"
assert_contains "case9: pr-body-only change reports STALE" "$BASE/err9d.log" "STALE"

# ---------------- integration mode ----------------

# integration_marker <fp> <issue> <pr> <verdict> [viewerDidAuthor] — a
# prior full-review marker with head/base, as publish-review.sh posts it.
integration_marker() {
  local fp="$1" issue="$2" pr="$3" verdict="$4" author="${5:-true}"
  jq -nc --arg fp "$fp" --argjson issue "$issue" --argjson pr "$pr" \
    --arg verdict "$verdict" --argjson author "$author" \
    '{body: ("<!-- review-pr:v1 "
             + ({fingerprint:$fp, head:"prevhead", base:"prevbase", issue:$issue, pr:$pr, pass:1, verdict:$verdict} | tojson)
             + " -->"),
      viewerDidAuthor: $author}'
}

run_publish_integration() {
  local pr="$1" issue="$2" fp="$3" verdict="$4" prev="$5"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
    STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
    STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
    STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
    "$PUBLISH" "$pr" "$issue" "$fp" "$verdict" "$BODY_FILE" --mode integration --previous-fingerprint "$prev"
}

# --- Case 10: integration PASS publishes with additive marker fields ---
new_fixture
common_stubs
write_comments "$(integration_marker prevfp 6 5 PASS)"
fp10="$(run_snapshot 5 6)"
out10="$(run_publish_integration 5 6 "$fp10" PASS prevfp)"
rc10=$?
assert_eq "case10: exits 0 on a valid integration pass" 0 "$rc10"
assert_eq "case10: marker carries mode integration" "integration" "$(printf '%s' "$out10" | jq -r .mode)"
assert_eq "case10: marker carries previousFingerprint" "prevfp" "$(printf '%s' "$out10" | jq -r .previousFingerprint)"
assert_eq "case10: verdict PASS" "PASS" "$(printf '%s' "$out10" | jq -r .verdict)"
assert_eq "case10: pass number counts the prior marker" 2 "$(printf '%s' "$out10" | jq -r .pass)"
assert_contains "case10: body identifies integration mode" "$POSTED_BODY_FILE" "Integration review"
assert_contains "case10: body names previous head" "$POSTED_BODY_FILE" "prevhead"
assert_contains "case10: body names previous base" "$POSTED_BODY_FILE" "prevbase"
assert_contains "case10: body names current head" "$POSTED_BODY_FILE" "deadbeef"
assert_contains "case10: body names current base" "$POSTED_BODY_FILE" "cafef00d"
assert_contains "case10: body keeps the review text" "$POSTED_BODY_FILE" "Review findings go here."

# --- Case 11: integration BLOCKING uses the same verdict contract ---
new_fixture
common_stubs
write_comments "$(integration_marker prevfp 6 5 PASS)"
fp11="$(run_snapshot 5 6)"
out11="$(run_publish_integration 5 6 "$fp11" BLOCKING prevfp)"
assert_eq "case11: exits 0 on integration BLOCKING" 0 "$?"
assert_eq "case11: verdict BLOCKING" "BLOCKING" "$(printf '%s' "$out11" | jq -r .verdict)"
assert_eq "case11: marker still carries mode integration" "integration" "$(printf '%s' "$out11" | jq -r .mode)"

# --- Case 12: full review is unchanged — no mode/previousFingerprint keys ---
new_fixture
common_stubs
fp12="$(run_snapshot 5 6)"
out12="$(run_publish 5 6 "$fp12" PASS)"
assert_eq "case12: full-review marker has no mode key" "false" "$(printf '%s' "$out12" | jq 'has("mode")')"
assert_eq "case12: full-review marker has no previousFingerprint key" "false" "$(printf '%s' "$out12" | jq 'has("previousFingerprint")')"
assert_eq "case12: full-review body has no integration header" "" "$(grep -F 'Integration review' "$POSTED_BODY_FILE" || true)"

# --- Case 13: missing prior marker -> exit 5, nothing posted ---
new_fixture
common_stubs
fp13="$(run_snapshot 5 6)"
out13="$(run_publish_integration 5 6 "$fp13" PASS prevfp 2>"$BASE/err13.log")"
rc13=$?
assert_eq "case13: exits 5 when the prior marker is missing" 5 "$rc13"
assert_eq "case13: nothing posted" "" "$out13"
assert_eq "case13: gh pr comment never called" "" "$(grep 'pr comment' "$GH_LOG" || true)"
assert_contains "case13: UNTRUSTED reported on stderr" "$BASE/err13.log" "UNTRUSTED"

# --- Case 14: untrusted prior markers -> exit 5 ---
new_fixture
common_stubs
write_comments "$(integration_marker prevfp 6 5 PASS false)"
fp14a="$(run_snapshot 5 6)"
run_publish_integration 5 6 "$fp14a" PASS prevfp >/dev/null 2>&1
assert_eq "case14: foreign-authored prior marker -> exit 5" 5 "$?"

new_fixture
common_stubs
write_comments "$(integration_marker prevfp 6 5 BLOCKING)"
fp14b="$(run_snapshot 5 6)"
run_publish_integration 5 6 "$fp14b" PASS prevfp >/dev/null 2>&1
assert_eq "case14: prior BLOCKING marker -> exit 5" 5 "$?"

new_fixture
common_stubs
write_comments "$(integration_marker prevfp 99 5 PASS)"
fp14c="$(run_snapshot 5 6)"
run_publish_integration 5 6 "$fp14c" PASS prevfp >/dev/null 2>&1
assert_eq "case14: wrong-pair prior marker -> exit 5" 5 "$?"

# --- Case 15: stale current snapshot beats prior-marker resolution ---
new_fixture
common_stubs
write_comments "$(integration_marker prevfp 6 5 PASS)"
run_publish_integration 5 6 "not-the-real-fingerprint" PASS prevfp >/dev/null 2>"$BASE/err15.log"
assert_eq "case15: stale current snapshot -> exit 3" 3 "$?"
assert_contains "case15: STALE reported on stderr" "$BASE/err15.log" "STALE"
assert_eq "case15: nothing posted while stale" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 16: duplicate current snapshot stays idempotent ---
new_fixture
common_stubs
fp16="$(run_snapshot 5 6)"
write_comments "$(integration_marker prevfp 6 5 PASS)" "$(marker_comment "$fp16" 2 PASS)"
run_publish_integration 5 6 "$fp16" PASS prevfp >/dev/null 2>"$BASE/err16.log"
assert_eq "case16: already-reviewed current snapshot -> exit 4" 4 "$?"
assert_contains "case16: DUPLICATE reported on stderr" "$BASE/err16.log" "DUPLICATE"
assert_eq "case16: nothing posted on duplicate" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 17: the flags are a required pair ---
new_fixture
common_stubs
fp17="$(run_snapshot 5 6)"
PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
  STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
  STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
  STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
  "$PUBLISH" 5 6 "$fp17" PASS "$BODY_FILE" --mode integration >/dev/null 2>"$BASE/err17.log"
assert_eq "case17: --mode without --previous-fingerprint -> exit 1" 1 "$?"
assert_contains "case17: clear error message" "$BASE/err17.log" "--previous-fingerprint"

new_fixture
common_stubs
fp17b="$(run_snapshot 5 6)"
PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
  STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
  STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
  STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
  "$PUBLISH" 5 6 "$fp17b" PASS "$BODY_FILE" --previous-fingerprint prevfp >/dev/null 2>"$BASE/err17b.log"
assert_eq "case17: --previous-fingerprint without --mode -> exit 1" 1 "$?"

new_fixture
common_stubs
fp17c="$(run_snapshot 5 6)"
PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
  STUB_REPO="testowner/testrepo" STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" \
  STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
  STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
  "$PUBLISH" 5 6 "$fp17c" PASS "$BODY_FILE" --mode full --previous-fingerprint prevfp >/dev/null 2>"$BASE/err17c.log"
assert_eq "case17: unknown --mode value -> exit 1" 1 "$?"
assert_contains "case17: names the only valid mode" "$BASE/err17c.log" "integration"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
