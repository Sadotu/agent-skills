#!/usr/bin/env bash
# Tests for scripts/finish-handoff.sh (Phase 6 label-driven handoff).
#
# Self-contained: stubs `gh` on PATH, logs every invocation to $GH_LOG,
# asserts exit code and the exact set of gh calls made. No test framework,
# no network calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF="$SCRIPT_DIR/../finish-handoff.sh"

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

assert_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then fail "$desc (unexpectedly found [$pattern] in $file)"; else ok "$desc"; fi
}

# write_gh_shim <path> — fake `gh` that logs `$*` to $GH_LOG and returns
# canned JSON for label queries. STUB_ISSUE_LABELS / STUB_PR_LABELS are
# comma-separated label names. FAIL_ON, if set, is a substring of the
# invocation that should make this call exit 1 (simulates partial failure).
write_gh_shim() {
  cat > "$1" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]]; then
  exit 1
fi
case "$1 $2" in
  "repo view")
    echo "${STUB_REPO:-testowner/testrepo}"
    ;;
  "issue view")
    IFS=',' read -ra labels <<< "${STUB_ISSUE_LABELS:-}"
    printf '{"labels":['
    for i in "${!labels[@]}"; do
      [ -n "${labels[$i]}" ] || continue
      [ "$i" -gt 0 ] && printf ','
      printf '{"name":"%s"}' "${labels[$i]}"
    done
    printf ']}\n'
    ;;
  "pr view")
    IFS=',' read -ra labels <<< "${STUB_PR_LABELS:-}"
    printf '{"labels":['
    for i in "${!labels[@]}"; do
      [ -n "${labels[$i]}" ] || continue
      [ "$i" -gt 0 ] && printf ','
      printf '{"name":"%s"}' "${labels[$i]}"
    done
    printf ']}\n'
    ;;
  *)
    :
    ;;
esac
SHIM
  chmod +x "$1"
}

# run_handoff <pr> <issue> — invokes finish-handoff.sh with the stubbed
# `gh` ahead on PATH.
run_handoff() {
  local pr="$1" issue="$2"
  PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" STUB_REPO="testowner/testrepo" \
    STUB_ISSUE_LABELS="${STUB_ISSUE_LABELS:-}" STUB_PR_LABELS="${STUB_PR_LABELS:-}" \
    FAIL_ON="${FAIL_ON:-}" \
    "$HANDOFF" "$pr" "$issue"
}

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  mkdir -p "$STUBBIN"
  : > "$GH_LOG"
  write_gh_shim "$STUBBIN/gh"
}

# --- Case 1: manual run (no agent-running on the issue) ---
test_case1_manual() {
  new_fixture
  STUB_ISSUE_LABELS="" run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "case1: exits zero on manual path" 0 "$rc"
  assert_contains "case1: pr ready called" "$GH_LOG" "pr ready 30"
  assert_not_contains "case1: no add-label calls" "$GH_LOG" "add-label"
  assert_not_contains "case1: no remove-label calls" "$GH_LOG" "remove-label"
}

test_case1_manual

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
