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

write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    cat "${STUB_COMMENTS_BODY_FILE:-/dev/null}"
    ;;
  "pr comment")
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
  FINDING_FILE="$BASE/finding.txt"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  : > "$COMMENTS_FILE"
  echo "This PR duplicates logic also touched by PR #99." > "$FINDING_FILE"
  write_gh_shim "$STUBBIN/gh"
}

run_crosslink() {
  local target="$1" origin_pr="$2" origin_issue="$3"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" POSTED_BODY_FILE="$POSTED_BODY_FILE" \
    STUB_REPO="testowner/testrepo" STUB_COMMENTS_BODY_FILE="$COMMENTS_FILE" \
    "$CROSSLINK" "$target" "$origin_pr" "$origin_issue" "$FINDING_FILE"
}

# --- Case 1: fresh cross-link posts and includes back-reference ---
new_fixture
out1="$(run_crosslink 99 5 6)"
rc1=$?
assert_eq "case1: exits 0 on fresh crosslink" 0 "$rc1"
assert_eq "case1: originPr recorded" 5 "$(printf '%s' "$out1" | jq -r .originPr)"
assert_eq "case1: originIssue recorded" 6 "$(printf '%s' "$out1" | jq -r .originIssue)"
assert_eq "case1: targetPr recorded" 99 "$(printf '%s' "$out1" | jq -r .targetPr)"
assert_contains "case1: gh pr comment invoked on target PR" "$GH_LOG" "pr comment 99"
assert_contains "case1: posted body references origin PR" "$POSTED_BODY_FILE" "review of PR #5"
assert_contains "case1: posted body includes finding text" "$POSTED_BODY_FILE" "duplicates logic"
assert_contains "case1: posted body includes marker" "$POSTED_BODY_FILE" "<!-- review-pr-crosslink:v1 {"

# --- Case 2: rerunning the same finding against the same target is a no-op ---
new_fixture
fp="$(printf '%s\x1e%s\x1e%s\x1e%s' 5 6 99 "$(cat "$FINDING_FILE")" | sha256sum | awk '{print $1}')"
printf '<!-- review-pr-crosslink:v1 {"fingerprint":"%s","originPr":5,"originIssue":6,"targetPr":99} -->\n' "$fp" > "$COMMENTS_FILE"
out2="$(run_crosslink 99 5 6 2>"$BASE/err2.log")"
rc2=$?
assert_eq "case2: exits 4 on duplicate crosslink" 4 "$rc2"
assert_eq "case2: nothing posted on duplicate" "" "$out2"
assert_contains "case2: DUPLICATE reported on stderr" "$BASE/err2.log" "DUPLICATE"
assert_eq "case2: gh pr comment never called" "" "$(grep 'pr comment' "$GH_LOG" || true)"

# --- Case 3: different finding text against the same target -> new post (not deduped) ---
new_fixture
printf '<!-- review-pr-crosslink:v1 {"fingerprint":"some-other-fingerprint","originPr":5,"originIssue":6,"targetPr":99} -->\n' > "$COMMENTS_FILE"
out3="$(run_crosslink 99 5 6)"
rc3=$?
assert_eq "case3: exits 0, different finding is not deduped" 0 "$rc3"
assert_contains "case3: gh pr comment invoked" "$GH_LOG" "pr comment 99"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
