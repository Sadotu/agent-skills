#!/usr/bin/env bash
# Tests for scripts/finding-triage.sh — the pre-publication classifier that
# decides whether a state/timing/race finding may be published as a
# mechanically actionable repair.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE="$SCRIPT_DIR/../finding-triage.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc (expected [$expected], got [$actual])"; fi
}

assert_match() {
  local desc="$1" text="$2" pattern="$3"
  if printf '%s' "$text" | grep -qF -- "$pattern"; then ok "$desc"; else fail "$desc (missing [$pattern] in [$text])"; fi
}

# run_triage <flags...> — sets OUT (stdout), ERR (stderr), RC (exit code).
run_triage() {
  local err_file
  err_file="$(mktemp)"
  OUT="$("$TRIAGE" "$@" 2>"$err_file")"
  RC=$?
  ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# all_clear <overrides...> — the fully-clearing flag set, with any flag the
# caller repeats later on the command line taking precedence.
all_clear() {
  run_triage \
    --happy-path-replayed yes \
    --race-restart-transitions-replayed yes \
    --preserves-issue-paths yes \
    --discriminator-matches-system-change no \
    --needs-additional-state no \
    --separately-repairable-parts no \
    "$@"
}

# --- Case 1: every axis clears -> REPAIRABLE ---
all_clear
assert_eq "case1: exits 0 when every axis clears" 0 "$RC"
assert_eq "case1: prints REPAIRABLE" "REPAIRABLE" "$OUT"

# --- Case 2: happy path not replayed -> DECISION-REQUIRED ---
all_clear --happy-path-replayed no
assert_eq "case2: exits 2 when the happy path was not replayed" 2 "$RC"
assert_match "case2: names the verdict" "$OUT" "DECISION-REQUIRED"
assert_match "case2: reason mentions the success transition" "$OUT" "success transition"

# --- Case 3: named race/restart transitions not replayed -> DECISION-REQUIRED ---
all_clear --race-restart-transitions-replayed no
assert_eq "case3: exits 2 when race/restart transitions were not replayed" 2 "$RC"
assert_match "case3: reason mentions race/restart transitions" "$OUT" "race/restart transitions"

# --- Case 4: action breaks an issue acceptance path -> DECISION-REQUIRED ---
all_clear --preserves-issue-paths no
assert_eq "case4: exits 2 when an issue acceptance path is not preserved" 2 "$RC"
assert_match "case4: reason names the acceptance path conflict" "$OUT" "acceptance path"

# --- Case 4: the Update Branch example — the discriminator also matches a
# legitimate system-generated state change -> DECISION-REQUIRED ---
all_clear --discriminator-matches-system-change yes
assert_eq "case4: exits 2 when the discriminator matches a system change" 2 "$RC"
assert_match "case4: reason names the system-generated change" "$OUT" "system-generated"

# --- Case 5: invariant needs state the application does not record ---
all_clear --needs-additional-state yes
assert_eq "case5: exits 2 when the invariant needs unrecorded state" 2 "$RC"
assert_match "case5: reason names the missing state/provenance" "$OUT" "provenance"

# --- Case 6: compound finding -> SPLIT, and SPLIT wins over other failures ---
all_clear --separately-repairable-parts yes
assert_eq "case6: exits 3 on a compound finding" 3 "$RC"
assert_match "case6: prints SPLIT" "$OUT" "SPLIT"

all_clear --separately-repairable-parts yes --discriminator-matches-system-change yes
assert_eq "case6: SPLIT is decided before DECISION-REQUIRED" 3 "$RC"
assert_match "case6: still prints SPLIT when other axes also fail" "$OUT" "SPLIT"

# --- Case 7: fail-closed on missing, empty, and non-yes/no evidence ---
run_triage \
  --happy-path-replayed yes \
  --preserves-issue-paths yes \
  --discriminator-matches-system-change no \
  --needs-additional-state no \
  --separately-repairable-parts no
assert_eq "case7: exits 2 when race/restart evidence is omitted entirely" 2 "$RC"
assert_match "case7: names the omitted race/restart flag" "$OUT" "--race-restart-transitions-replayed"

all_clear --happy-path-replayed ""
assert_eq "case7: exits 2 on an empty flag value" 2 "$RC"
assert_match "case7: empty value is not treated as no" "$OUT" "DECISION-REQUIRED"

all_clear --needs-additional-state maybe
assert_eq "case7: exits 2 on a non-yes/no value" 2 "$RC"
assert_match "case7: names the unusable flag" "$OUT" "--needs-additional-state"

all_clear --happy-path-replayed YES
assert_eq "case7: exits 2 on a differently-cased value" 2 "$RC"

# A compound finding whose other evidence is unusable still fails closed:
# SPLIT is only reached once every flag is a usable yes/no.
run_triage --separately-repairable-parts yes
assert_eq "case7: unusable evidence outranks SPLIT" 2 "$RC"
assert_match "case7: unusable evidence reports DECISION-REQUIRED" "$OUT" "DECISION-REQUIRED"

# --- Case 8: usage errors are exit 1, distinct from a refusal ---
run_triage --not-a-flag yes
assert_eq "case8: exits 1 on an unknown flag" 1 "$RC"
assert_match "case8: unknown flag reported on stderr" "$ERR" "unknown argument"

run_triage --happy-path-replayed
assert_eq "case8: exits 1 when a flag is missing its value" 1 "$RC"
assert_match "case8: missing value reported on stderr" "$ERR" "requires a value"

assert_eq "case8: usage errors print nothing on stdout" "" "$OUT"

# --- Case 9: the issue's worked example, both halves ---
# The compound finding as originally written on issue-orchestrator#99:
# "recheck issue/PR-body drift AND treat head drift as content drift".
all_clear --separately-repairable-parts yes --discriminator-matches-system-change yes \
  --needs-additional-state yes
assert_eq "case9: the original compound finding must be split first" 3 "$RC"

# Half A — recheck issue/PR-body drift on an active reservation. Mechanically
# repairable: the body text is already recorded, and rechecking it preserves
# the integration path.
all_clear
assert_eq "case9: the body-drift half is repairable" 0 "$RC"
assert_eq "case9: the body-drift half prints REPAIRABLE" "REPAIRABLE" "$OUT"

# Half B — "treat head drift as content drift". GitHub Update Branch changes
# the head itself, so the discriminator also matches the issue-required
# transition, and proving the head IS the requested base update needs
# provenance the application does not record.
all_clear --discriminator-matches-system-change yes --needs-additional-state yes \
  --preserves-issue-paths no
assert_eq "case9: the head-drift half requires a decision" 2 "$RC"
assert_match "case9: the head-drift half is not presented as a repair" "$OUT" "DECISION-REQUIRED"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
