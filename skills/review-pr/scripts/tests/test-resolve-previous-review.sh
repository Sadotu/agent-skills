#!/usr/bin/env bash
# Tests for scripts/resolve-previous-review.sh: trusted prior-PASS
# resolution, fail-closed rejection, and never posting anything.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/../resolve-previous-review.sh"

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

# Fake `gh`: only `repo view` and `pr view --json comments` are expected.
# Any write (`pr comment`, `pr review`, `pr merge`) is a hard failure — this
# script must never mutate anything.
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo "${STUB_REPO:-testowner/testrepo}" ;;
  "pr view")
    if printf '%s\n' "$*" | grep -q -- '--json comments'; then
      cat "${STUB_COMMENTS_JSON_FILE:-/dev/null}"
    else
      echo "unexpected gh pr view invocation: $*" >&2
      exit 1
    fi
    ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
SHIM
  chmod +x "$1"
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  COMMENTS_FILE="$BASE/comments.json"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  echo '{"comments":[]}' > "$COMMENTS_FILE"
  write_gh_shim "$STUBBIN/gh"
}

# marker_comment <fp> <issue> <pr> <verdict> [viewerDidAuthor]
marker_comment() {
  local fp="$1" issue="$2" pr="$3" verdict="$4" author="${5:-true}"
  jq -nc --arg fp "$fp" --argjson issue "$issue" --argjson pr "$pr" \
    --arg verdict "$verdict" --argjson author "$author" \
    '{body: ("<!-- review-pr:v1 "
             + ({fingerprint:$fp, head:"headsha", base:"basesha", issue:$issue, pr:$pr, pass:1, verdict:$verdict} | tojson)
             + " -->"),
      viewerDidAuthor: $author}'
}

write_comments() {
  jq -nc --argjson comments "[$(IFS=,; echo "$*")]" '{comments: $comments}' > "$COMMENTS_FILE"
}

run_resolve() {
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" STUB_REPO="testowner/testrepo" \
    STUB_COMMENTS_JSON_FILE="$COMMENTS_FILE" "$RESOLVE" "$@"
}

# --- Case 1: trusted prior PASS resolves ---
new_fixture
write_comments "$(marker_comment prevfp 6 5 PASS)"
out1="$(run_resolve 5 6 prevfp)"
rc1=$?
assert_eq "case1: exits 0 on a trusted prior PASS" 0 "$rc1"
assert_eq "case1: stdout is a single line" 1 "$(printf '%s\n' "$out1" | wc -l | tr -d ' ')"
assert_eq "case1: payload fingerprint" "prevfp" "$(printf '%s' "$out1" | jq -r .fingerprint)"
assert_eq "case1: payload head available for the base diff" "headsha" "$(printf '%s' "$out1" | jq -r .head)"
assert_eq "case1: payload base available for the base diff" "basesha" "$(printf '%s' "$out1" | jq -r .base)"
assert_eq "case1: nothing was posted" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 2: no prior marker at all ---
new_fixture
out2="$(run_resolve 5 6 prevfp 2>"$BASE/err2.log")"
rc2=$?
assert_eq "case2: exits 5 when no prior marker exists" 5 "$rc2"
assert_eq "case2: stdout empty" "" "$out2"
assert_contains "case2: reason on stderr" "$BASE/err2.log" "no trusted review marker"

# --- Case 3: foreign-authored marker is untrusted ---
new_fixture
write_comments "$(marker_comment prevfp 6 5 PASS false)"
run_resolve 5 6 prevfp >/dev/null 2>&1
assert_eq "case3: exits 5 on a foreign-authored marker" 5 "$?"

# --- Case 4: prior verdict BLOCKING is rejected ---
new_fixture
write_comments "$(marker_comment prevfp 6 5 BLOCKING)"
run_resolve 5 6 prevfp >/dev/null 2>&1
assert_eq "case4: exits 5 when the prior verdict is BLOCKING" 5 "$?"

# --- Case 5: marker for another issue/PR pair is rejected ---
new_fixture
write_comments "$(marker_comment prevfp 99 5 PASS)"
run_resolve 5 6 prevfp >/dev/null 2>&1
assert_eq "case5: exits 5 on a wrong-issue marker" 5 "$?"

new_fixture
write_comments "$(marker_comment prevfp 6 99 PASS)"
run_resolve 5 6 prevfp >/dev/null 2>&1
assert_eq "case5: exits 5 on a wrong-PR marker" 5 "$?"

# --- Case 6: malformed own marker is rejected ---
new_fixture
jq -nc '{comments: [{body: "<!-- review-pr:v1 not-json -->", viewerDidAuthor: true}]}' > "$COMMENTS_FILE"
run_resolve 5 6 prevfp >/dev/null 2>&1
assert_eq "case6: exits 5 on a malformed own marker" 5 "$?"

# --- Case 7: argument validation ---
new_fixture
run_resolve abc 6 prevfp >"$BASE/out7.log" 2>"$BASE/err7.log"
assert_eq "case7: exits 1 on non-numeric pr-number" 1 "$?"
assert_contains "case7: clear error message" "$BASE/err7.log" "invalid pr-number"

new_fixture
run_resolve 5 6 >/dev/null 2>"$BASE/err7b.log"
assert_eq "case7: exits 1 on missing fingerprint" 1 "$?"
assert_contains "case7: usage message" "$BASE/err7b.log" "usage:"

# --- Case 8: an internal tooling failure (jq missing/broken) must not be
# misreported as an untrusted marker — the caller needs to tell "no prior
# PASS, run a full review" apart from "this environment is broken" ---
new_fixture
write_comments "$(marker_comment prevfp 6 5 PASS)"
cat > "$STUBBIN/jq" <<'SHIM'
#!/usr/bin/env bash
echo "jq: simulated failure" >&2
exit 1
SHIM
chmod +x "$STUBBIN/jq"
run_resolve 5 6 prevfp >"$BASE/out8.log" 2>"$BASE/err8.log"
rc8=$?
assert_eq "case8: exits 1 (genuine script error) when jq is broken" 1 "$rc8"
assert_eq "case8: stderr does not claim UNTRUSTED" "" "$(grep -F 'UNTRUSTED' "$BASE/err8.log" || true)"
assert_contains "case8: stderr reports the internal-error reason" "$BASE/err8.log" "failed internally"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
