#!/usr/bin/env bash
# Contract tests for the github-pr-cleanup skill boundary.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SKILL_DIR="$ROOT/skills/github-pr-cleanup"
ENTRY="$SKILL_DIR/scripts/cleanup.sh"
ISSUE_DIR="$ROOT/skills/github-issue"
PASS=0
FAIL=0
TMP_DIRS=()

cleanup() {
  local dir
  for dir in "${TMP_DIRS[@]:-}"; do
    [ -n "$dir" ] && rm -rf "$dir"
  done
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+ ($2)}"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc" "expected [$expected], got [$actual]"; fi
}
assert_file() {
  if [ -f "$2" ]; then ok "$1"; else fail "$1" "missing $2"; fi
}

# Ownership/document boundaries are intentionally checked as filesystem
# contracts. Runtime behavior below is exercised through a stubbed gh and an
# instrumented two-argument cleanup boundary.
assert_file "github-pr-cleanup owns a SKILL.md" "$SKILL_DIR/SKILL.md"
assert_file "github-pr-cleanup owns scripts/cleanup.sh" "$ENTRY"

mapfile -t cleanup_scripts < <(find "$ROOT/skills" -type f \( -name 'cleanup.sh' -o -name 'cleanup-merged.sh' \) | sort)
assert_eq "the repository has exactly one cleanup implementation" 1 "${#cleanup_scripts[@]}"
[ "${cleanup_scripts[0]-}" = "$ENTRY" ] \
  && ok "the sole cleanup implementation belongs to github-pr-cleanup" \
  || fail "the sole cleanup implementation belongs to github-pr-cleanup" "found ${cleanup_scripts[*]-none}"

mapfile -t issue_cleanup < <(find "$ISSUE_DIR" -type f \( -name 'cleanup.sh' -o -name 'cleanup-merged.sh' \) | sort)
assert_eq "github-issue contains no cleanup implementation or wrapper" 0 "${#issue_cleanup[@]}"

if [ -f "$SKILL_DIR/SKILL.md" ]; then
  if grep -Eq '^[[:space:]]*/github-pr-cleanup[[:space:]]+<pr-number>[[:space:]]*$' "$SKILL_DIR/SKILL.md"; then
    ok "manual documentation exposes a one-argument invocation"
  else
    fail "manual documentation exposes a one-argument invocation"
  fi
  assert_eq "SKILL.md has one manual-entry start marker" 1 \
    "$(grep -c '^<!-- github-pr-cleanup-manual-entry:start -->$' "$SKILL_DIR/SKILL.md")"
  assert_eq "SKILL.md has one manual-entry end marker" 1 \
    "$(grep -c '^<!-- github-pr-cleanup-manual-entry:end -->$' "$SKILL_DIR/SKILL.md")"
fi

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  mkdir -p "$BASE/skill/scripts/tests" "$BASE/bin"
  cp -R "$SKILL_DIR/." "$BASE/skill/"

  # Execute the SKILL-level manual workflow, while replacing cleanup.sh only
  # at its real two-argument Worktree Warden boundary.
  awk '
    /^<!-- github-pr-cleanup-manual-entry:start -->$/ { in_block=1; next }
    /^<!-- github-pr-cleanup-manual-entry:end -->$/ { exit }
    in_block && /^```(bash)?$/ { next }
    in_block { print }
  ' "$SKILL_DIR/SKILL.md" > "$BASE/skill/manual-entry.sh"
  chmod +x "$BASE/skill/manual-entry.sh"
  cat > "$BASE/skill/scripts/cleanup.sh" <<'SHIM'
#!/usr/bin/env bash
if [ "$#" -ne 2 ]; then
  echo "cleanup stub requires exactly two arguments" >&2
  exit 90
fi
  printf '%s\t%s\n' "$1" "$2" >> "$CLEANUP_CALL_LOG"
  printf '%s\n' "$CLEANUP_STUB_OUTPUT"
  exit "$CLEANUP_STUB_STATUS"
SHIM
  chmod +x "$BASE/skill/scripts/cleanup.sh"

  cat > "$BASE/bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
[ "${GH_TOKEN-}" = app-token ] || { echo "missing App authentication" >&2; exit 91; }
printf '%b\n' "$GH_RESULT"
SHIM
  cat > "$BASE/bin/git" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  'remote get-url origin') echo 'https://github.com/example/project.git' ;;
  'worktree list --porcelain') printf 'worktree %s\n' "$PWD" ;;
  *) exit 92 ;;
esac
SHIM
  cat > "$BASE/token" <<'SHIM'
#!/usr/bin/env bash
printf app-token
SHIM
  chmod +x "$BASE/bin/gh" "$BASE/bin/git" "$BASE/token"
  GH_CALL_LOG="$BASE/gh.log"
  CLEANUP_CALL_LOG="$BASE/cleanup.log"
  : > "$GH_CALL_LOG"
  : > "$CLEANUP_CALL_LOG"
}

run_manual() {
  set +e
  RUN_OUTPUT="$(cd "$BASE/skill" && PATH="$BASE/bin:$PATH" GH_CALL_LOG="$GH_CALL_LOG" GH_RESULT="$GH_RESULT" \
    GH_APP_TOKEN_HELPER="$BASE/token" CLEANUP_CALL_LOG="$CLEANUP_CALL_LOG" \
    CLEANUP_STUB_OUTPUT="$CLEANUP_STUB_OUTPUT" CLEANUP_STUB_STATUS="$CLEANUP_STUB_STATUS" \
    bash "$BASE/skill/manual-entry.sh" "$@" 2>&1)"
  RUN_STATUS=$?
  set -e
}

if [ -f "$ENTRY" ] && [ -f "$SKILL_DIR/SKILL.md" ] \
  && [ "$(grep -c '^<!-- github-pr-cleanup-manual-entry:start -->$' "$SKILL_DIR/SKILL.md")" -eq 1 ] \
  && [ "$(grep -c '^<!-- github-pr-cleanup-manual-entry:end -->$' "$SKILL_DIR/SKILL.md")" -eq 1 ]; then
  for args in zero two; do
    new_fixture
    GH_RESULT=$'MERGED\t1\t47'
    CLEANUP_STUB_OUTPUT=unexpected
    CLEANUP_STUB_STATUS=0
    if [ "$args" = zero ]; then run_manual; else run_manual 101 47; fi
    [ "$RUN_STATUS" -ne 0 ] && ok "manual entry rejects $args arguments" || fail "manual entry rejects $args arguments"
    assert_eq "rejected $args-argument entry does not query GitHub" 0 "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
    assert_eq "rejected $args-argument entry does not invoke cleanup" 0 "$(wc -l < "$CLEANUP_CALL_LOG" | tr -d ' ')"
  done

  new_fixture
  GH_RESULT=$'MERGED\t1\t47'
  CLEANUP_STUB_OUTPUT=unexpected
  CLEANUP_STUB_STATUS=0
  run_manual abc
  [ "$RUN_STATUS" -ne 0 ] && ok "manual entry rejects a nonnumeric PR" || fail "manual entry rejects a nonnumeric PR"
  assert_eq "nonnumeric PR does not query GitHub" 0 "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
  assert_eq "nonnumeric PR does not invoke cleanup" 0 "$(wc -l < "$CLEANUP_CALL_LOG" | tr -d ' ')"

  new_fixture
  GH_RESULT=$'MERGED\t1\t47'
  CLEANUP_STUB_OUTPUT='{"status":"retry","reason":"preserved"}'
  CLEANUP_STUB_STATUS=23
  run_manual 101
  assert_eq "manual entry resolves through one authenticated gh call" 1 "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
  grep -Fq 'pr view 101' "$GH_CALL_LOG" && ok "manual entry queries the requested PR" || fail "manual entry queries the requested PR"
  if grep -Fq 'state' "$GH_CALL_LOG" && grep -Fq 'closingIssuesReferences' "$GH_CALL_LOG"; then
    ok "one query requests terminal state and closing references"
  else
    fail "one query requests terminal state and closing references"
  fi
  assert_eq "exactly one closing issue produces one cleanup call" 1 "$(wc -l < "$CLEANUP_CALL_LOG" | tr -d ' ')"
  assert_eq "cleanup receives PR and resolved issue once" $'101\t47' "$(cat "$CLEANUP_CALL_LOG")"
  assert_eq "manual entry preserves cleanup output" "$CLEANUP_STUB_OUTPUT" "$RUN_OUTPUT"
  assert_eq "manual entry preserves cleanup exit status" 23 "$RUN_STATUS"
  assert_eq "retry result is not automatically retried" 1 "$(wc -l < "$CLEANUP_CALL_LOG" | tr -d ' ')"

  new_fixture
  GH_RESULT=$'CLOSED\t1\t47'
  CLEANUP_STUB_OUTPUT='closed-cleanup'
  CLEANUP_STUB_STATUS=0
  run_manual 102
  assert_eq "CLOSED is also a terminal cleanup state" $'102\t47' "$(cat "$CLEANUP_CALL_LOG")"

  for fixture in 'MERGED\t0\t' 'MERGED\t2\t47' 'OPEN\t1\t47'; do
    new_fixture
    GH_RESULT="$fixture"
    CLEANUP_STUB_OUTPUT=unexpected
    CLEANUP_STUB_STATUS=0
    run_manual 101
    assert_eq "non-singleton or non-terminal PR is rejected ($fixture)" 0 "$(wc -l < "$CLEANUP_CALL_LOG" | tr -d ' ')"
    [ "$RUN_STATUS" -ne 0 ] && ok "rejected PR returns nonzero ($fixture)" || fail "rejected PR returns nonzero ($fixture)"
  done
fi

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
