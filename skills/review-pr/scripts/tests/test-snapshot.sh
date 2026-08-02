#!/usr/bin/env bash
# Tests for scripts/snapshot.sh — verifies it shells out correctly and
# that the fingerprint is content-based, not timestamp-based.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$SCRIPT_DIR/../snapshot.sh"

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

# write_gh_shim <path> — fake `gh` returning STUB_HEAD/STUB_BASE/STUB_PR_BODY/
# STUB_PR_UPDATED/STUB_ISSUE_BODY/STUB_ISSUE_UPDATED as the relevant JSON.
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "pr view")
    jq -n --arg head "$STUB_HEAD" --arg base "$STUB_BASE" --arg body "$STUB_PR_BODY" --arg updated "$STUB_PR_UPDATED" \
      '{headRefOid:$head, baseRefOid:$base, body:$body, updatedAt:$updated}'
    ;;
  "issue view")
    jq -n --arg body "$STUB_ISSUE_BODY" --arg updated "$STUB_ISSUE_UPDATED" \
      '{body:$body, updatedAt:$updated}'
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$1"
}

run_snapshot() {
  local pr="$1" issue="$2"
  PATH="$STUBBIN:$PATH" STUB_REPO="testowner/testrepo" \
    STUB_HEAD="$STUB_HEAD" STUB_BASE="$STUB_BASE" STUB_PR_BODY="$STUB_PR_BODY" STUB_PR_UPDATED="$STUB_PR_UPDATED" \
    STUB_ISSUE_BODY="$STUB_ISSUE_BODY" STUB_ISSUE_UPDATED="$STUB_ISSUE_UPDATED" \
    "$SNAPSHOT" "$pr" "$issue"
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  mkdir -p "$STUBBIN"
  write_gh_shim "$STUBBIN/gh"
}

# --- Case 1: prints all expected fields ---
new_fixture
STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z" \
  STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z" \
  out="$(run_snapshot 10 20)"
assert_eq "case1: issue field" "20" "$(printf '%s' "$out" | jq -r .issue)"
assert_eq "case1: pr field" "10" "$(printf '%s' "$out" | jq -r .pr)"
assert_eq "case1: head field" "deadbeef" "$(printf '%s' "$out" | jq -r .head)"
assert_eq "case1: base field" "cafef00d" "$(printf '%s' "$out" | jq -r .base)"
assert_eq "case1: issueUpdatedAt field" "2026-07-31T00:00:00Z" "$(printf '%s' "$out" | jq -r .issueUpdatedAt)"
assert_eq "case1: prUpdatedAt field" "2026-08-01T00:00:00Z" "$(printf '%s' "$out" | jq -r .prUpdatedAt)"
fp1="$(printf '%s' "$out" | jq -r .fingerprint)"
assert_eq "case1: fingerprint is 64 hex chars" "64" "${#fp1}"

# --- Case 2: same content, different updatedAt -> same fingerprint ---
new_fixture
STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="pr text" STUB_PR_UPDATED="2099-01-01T00:00:00Z" \
  STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2099-01-01T00:00:00Z" \
  out2="$(run_snapshot 10 20)"
fp2="$(printf '%s' "$out2" | jq -r .fingerprint)"
assert_eq "case2: fingerprint ignores updatedAt (unchanged content -> same fingerprint)" "$fp1" "$fp2"

# --- Case 3: changed PR body -> different fingerprint ---
new_fixture
STUB_HEAD="deadbeef" STUB_BASE="cafef00d" STUB_PR_BODY="different pr text" STUB_PR_UPDATED="2026-08-01T00:00:00Z" \
  STUB_ISSUE_BODY="issue text" STUB_ISSUE_UPDATED="2026-07-31T00:00:00Z" \
  out3="$(run_snapshot 10 20)"
fp3="$(printf '%s' "$out3" | jq -r .fingerprint)"
assert_eq "case3: fingerprint changes with pr body" 1 "$([ "$fp1" != "$fp3" ] && echo 1 || echo 0)"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
