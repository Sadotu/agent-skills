#!/usr/bin/env bash
# Tests for scripts/baseline-triage.sh — pure baseline-failure classifier.
# Self-contained: no framework, no network. TAP-style ok/not ok.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE="$SCRIPT_DIR/../baseline-triage.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL+1)); echo "not ok - $1"; }

# assert_verdict <desc> <expected_exit> <expected_stdout_prefix> -- <args...>
assert_verdict() {
  local desc="$1" exp_code="$2" exp_prefix="$3"; shift 3
  [ "$1" = "--" ] && shift
  local out code
  out="$("$TRIAGE" "$@" 2>/dev/null)"; code=$?
  if [ "$code" = "$exp_code" ] && [ "${out#"$exp_prefix"}" != "$out" ]; then
    ok "$desc"
  else
    fail "$desc (exit $code out [$out])"
  fi
}

SAFE=(--reproduces-on-main yes --overlaps-surface no --branch-worsened no --branch-resolved no --ambiguous no)

# 1. Unrelated pre-existing → CONTINUE
assert_verdict "unrelated pre-existing continues" 0 CONTINUE -- "${SAFE[@]}"
# 2. Related → STOP
assert_verdict "related failure stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface yes --branch-worsened no --branch-resolved no --ambiguous no
# 3. New branch failure (does not reproduce on main) → STOP
assert_verdict "non-reproducing failure stops" 2 STOP -- --reproduces-on-main no --overlaps-surface no --branch-worsened no --branch-resolved no --ambiguous no
# 3b. Worse on branch → STOP
assert_verdict "worsened-on-branch failure stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface no --branch-worsened yes --branch-resolved no --ambiguous no
# 4. Resolved on branch → STOP
assert_verdict "resolved-on-branch failure stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface no --branch-worsened no --branch-resolved yes --ambiguous no
# 5. Ambiguous → STOP
assert_verdict "ambiguous failure stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface no --branch-worsened no --branch-resolved no --ambiguous yes
# 6. Multiple failures classified independently: one CONTINUE, one STOP
assert_verdict "multi: safe one continues" 0 CONTINUE -- "${SAFE[@]}"
assert_verdict "multi: other one stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface yes --branch-worsened no --branch-resolved no --ambiguous no
# 7. Change-surface expansion (re-run, overlaps now yes) → STOP
assert_verdict "expanded surface stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface yes --branch-worsened no --branch-resolved no --ambiguous no
# 8. Final-verification regression (re-run, worsened yes) → STOP
assert_verdict "final-verification regression stops" 2 STOP -- --reproduces-on-main yes --overlaps-surface no --branch-worsened yes --branch-resolved no --ambiguous no
# 9. Fail-closed: missing flag → STOP (not CONTINUE)
assert_verdict "missing evidence fails closed" 2 STOP -- --reproduces-on-main yes --overlaps-surface no
# 9b. Fail-closed: malformed value → STOP
assert_verdict "malformed value fails closed" 2 STOP -- --reproduces-on-main maybe --overlaps-surface no --branch-worsened no --branch-resolved no --ambiguous no

echo "1..$((PASS+FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
