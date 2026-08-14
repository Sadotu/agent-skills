#!/usr/bin/env bash
# Tests for scripts/finish-handoff.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF="$SCRIPT_DIR/../finish-handoff.sh"
SENTINEL='ghs_SENTINEL_APP_TOKEN_MUST_NOT_LEAK'
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

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
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

new_fixture() {
  BASE="$(mktemp -d)"
  TMP_DIRS+=("$BASE")
  STUBBIN="$BASE/bin"
  GH_LOG="$BASE/gh.log"
  REPO_DIR="$BASE/repo"
  APP_TOKEN_HELPER="$BASE/gh-app-token.sh"
  mkdir -p "$STUBBIN"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" remote add origin https://github.com/testowner/testrepo.git
  printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$SENTINEL_TOKEN"' > "$APP_TOKEN_HELPER"
  chmod +x "$APP_TOKEN_HELPER"
  : > "$GH_LOG"
  cat > "$STUBBIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
if [ "${GH_TOKEN-}" != "$SENTINEL_TOKEN" ]; then exit 4; fi
SHIM
  chmod +x "$STUBBIN/gh"
}

run_handoff() {
  local pr="$1" issue="$2"
  (cd "$REPO_DIR" && PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" \
    GH_APP_TOKEN_HELPER="$APP_TOKEN_HELPER" SENTINEL_TOKEN="$SENTINEL" \
    "$HANDOFF" "$pr" "$issue")
}

test_ready_handoff() {
  new_fixture
  run_handoff 30 30 >"$BASE/out.log" 2>&1
  local rc=$?
  assert_eq "handoff exits zero" 0 "$rc"
  assert_contains "PR is marked ready" "$GH_LOG" "pr ready 30"
  assert_not_contains "no review label is added" "$GH_LOG" "agent-review"
  assert_not_contains "agent-running is not mutated" "$GH_LOG" "agent-running"
}

test_rerun() {
  new_fixture
  run_handoff 31 31 >"$BASE/out1.log" 2>&1
  local rc1=$?
  : > "$GH_LOG"
  run_handoff 31 31 >"$BASE/out2.log" 2>&1
  local rc2=$?
  assert_eq "first run exits zero" 0 "$rc1"
  assert_eq "rerun exits zero" 0 "$rc2"
  assert_contains "rerun repeats the idempotent ready call" "$GH_LOG" "pr ready 31"
  assert_not_contains "rerun performs no label mutation" "$GH_LOG" "label"
}

test_ready_handoff
test_rerun

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
