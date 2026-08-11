#!/usr/bin/env bash
# Contract checks for review-pr finding guidance.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../../SKILL.md"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

skill_text="$(tr '\n' ' ' < "$SKILL_FILE")"
if grep -Fq 'Each finding: concrete evidence (file:line, quoted diff/code), impact, and the output required by its Phase 5 label.' <<< "$skill_text"; then
  ok "generic finding contract defers action requirements to Phase 5 labels"
else
  fail "generic finding contract must not require actions for decision-required findings"
fi

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
