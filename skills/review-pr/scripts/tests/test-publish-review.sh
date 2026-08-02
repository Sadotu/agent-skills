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
  if grep -qF "$pattern" "$file"; then ok "$desc"; else fail "$desc (missing [$pattern] in $file)"; fi
}

# write_gh_shim <path> — fake `gh`. `pr view --json headRefOid,...` (no -q)
# returns full PR JSON from STUB_HEAD/STUB_BASE/STUB_PR_BODY/STUB_PR_UPDATED.
# `issue view` returns issue JSON from STUB_ISSUE_BODY/STUB_ISSUE_UPDATED.
# `pr view --json comments -q ...` prints STUB_COMMENTS_BODY_FILE verbatim
# (a fixture file holding the raw multi-line concatenation of comment
# bodies, matching what real `gh ... -q '.comments[].body'` would print).
# `pr comment` logs the invocation to $GH_LOG and copies the --body-file
# content to $POSTED_BODY_FILE.
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    if printf '%s\n' "$*" | grep -q -- '-q'; then
      cat "${STUB_COMMENTS_BODY_FILE:-/dev/null}"
    else
      jq -n --arg head "$STUB_HEAD" --arg base "$STUB_BASE" --arg body "$STUB_PR_BODY" --arg updated "$STUB_PR_UPDATED" \
        '{headRefOid:$head, baseRefOid:$base, body:$body, updatedAt:$updated}'
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
  COMMENTS_FILE="$BASE/comments.txt"
  BODY_FILE="$BASE/review-body.txt"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  : > "$COMMENTS_FILE"
  echo "Review findings go here." > "$BODY_FILE"
  write_gh_shim "$STUBBIN/gh"
}

run_publish() {
  local pr="$1" issue="$2" fp="$3" verdict="$4"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
    STUB_REPO="testowner/testrepo" STUB_COMMENTS_BODY_FILE="$COMMENTS_FILE" \
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
fp="$(PATH="$STUBBIN:$PATH" STUB_REPO="testowner/testrepo" STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" \
  STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" STUB_ISSUE_BODY="$STUB_ISSUE_BODY" \
  STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" "$SCRIPT_DIR/../snapshot.sh" 5 6 | jq -r .fingerprint)"
out1="$(run_publish 5 6 "$fp" PASS)"
rc1=$?
assert_eq "case1: exits 0 on fresh publish" 0 "$rc1"
assert_eq "case1: pass 1" 1 "$(printf '%s' "$out1" | jq -r .pass)"
assert_eq "case1: verdict PASS" "PASS" "$(printf '%s' "$out1" | jq -r .verdict)"
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

# --- Case 3: duplicate — a marker for this fingerprint already exists ---
new_fixture
common_stubs
fp3="$(PATH="$STUBBIN:$PATH" STUB_REPO="testowner/testrepo" STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" \
  STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" STUB_ISSUE_BODY="$STUB_ISSUE_BODY" \
  STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" "$SCRIPT_DIR/../snapshot.sh" 5 6 | jq -r .fingerprint)"
printf '<!-- review-pr:v1 {"fingerprint":"%s","pass":1,"verdict":"PASS"} -->\n' "$fp3" > "$COMMENTS_FILE"
out3="$(run_publish 5 6 "$fp3" PASS 2>"$BASE/err3.log")"
rc3=$?
assert_eq "case3: exits 4 on duplicate" 4 "$rc3"
assert_eq "case3: nothing posted on duplicate" "" "$out3"
assert_contains "case3: DUPLICATE reported on stderr" "$BASE/err3.log" "DUPLICATE"
assert_eq "case3: gh pr comment never called" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 4: pass number increments across a genuinely new snapshot ---
new_fixture
common_stubs
fp4a="$(PATH="$STUBBIN:$PATH" STUB_REPO="testowner/testrepo" STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" \
  STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" STUB_ISSUE_BODY="$STUB_ISSUE_BODY" \
  STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" "$SCRIPT_DIR/../snapshot.sh" 5 6 | jq -r .fingerprint)"
printf '<!-- review-pr:v1 {"fingerprint":"%s","pass":1,"verdict":"PASS"} -->\n' "$fp4a" > "$COMMENTS_FILE"
STUB_PR_BODY="pr text, now changed"
fp4b="$(PATH="$STUBBIN:$PATH" STUB_REPO="testowner/testrepo" STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" \
  STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" STUB_ISSUE_BODY="$STUB_ISSUE_BODY" \
  STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" "$SCRIPT_DIR/../snapshot.sh" 5 6 | jq -r .fingerprint)"
out4="$(run_publish 5 6 "$fp4b" BLOCKING)"
assert_eq "case4: pass number increments to 2" 2 "$(printf '%s' "$out4" | jq -r .pass)"
assert_eq "case4: verdict BLOCKING" "BLOCKING" "$(printf '%s' "$out4" | jq -r .verdict)"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
