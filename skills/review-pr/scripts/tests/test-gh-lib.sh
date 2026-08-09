#!/usr/bin/env bash
# Tests for scripts/lib/gh.sh — verifies the GH() wrapper authenticates
# correctly with a short-lived GitHub App token and fails closed when the App
# helper is unavailable, even if `gh` has a logged-in user. No network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib/gh.sh"
REAL_GIT="$(command -v git)"

PASS=0
FAIL=0

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
  if grep -qF "$pattern" "$file"; then fail "$desc (unexpected [$pattern] in $file)"; else ok "$desc"; fi
}
# Compares a captured token without ever echoing it: a mismatch here can hold a
# real short-lived App token, which must not reach the test output.
assert_token() {
  local desc="$1" expected="$2" file="$3" actual
  actual="$(cat "$file")"
  if [ "$expected" = "$actual" ]; then
    ok "$desc"
  elif [ -z "$actual" ]; then
    fail "$desc (no token delivered)"
  else
    fail "$desc (delivered token differs from the expected stub value; value redacted)"
  fi
}

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO_DIR="$BASE/repo"; STUBBIN="$BASE/bin"
GH_LOG="$BASE/gh.log"; TOKEN_SINK="$BASE/token-sink"; HELPER_LOG="$BASE/helper.log"
mkdir -p "$REPO_DIR" "$STUBBIN"
"$REAL_GIT" -C "$REPO_DIR" init -q
"$REAL_GIT" -C "$REPO_DIR" remote add origin https://github.com/test/repo.git

# A token value distinctive enough that any leak into script output is
# unambiguous when grepped for.
SENTINEL='ghs_SENTINEL_APP_TOKEN_MUST_NOT_LEAK'

# Stub App-token helper: stands in for /opt/agent-devcontainer/gh-app-token.sh.
cat > "$BASE/gh-app-token.sh" <<'SH'
#!/usr/bin/env bash
printf 'GITHUB_APP_REPO=%s\n' "${GITHUB_APP_REPO-<unset>}" >> "$HELPER_LOG"
printf '%s\n' "$SENTINEL_TOKEN"
SH
chmod +x "$BASE/gh-app-token.sh"

# Stub gh: records its arguments, and records the GH_TOKEN it was handed to a
# sink file that is deliberately NOT part of the script's stdout/stderr, so the
# no-leak assertions stay meaningful.
cat > "$STUBBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
printf '%s' "${GH_TOKEN-}" >> "$TOKEN_SINK"
if [ "$1 $2" = "repo view" ]; then echo test/repo; exit 0; fi
echo "stub-gh-ok"
SH
chmod +x "$STUBBIN/gh"

# run_lib <helper-path> <gh-args...> — source lib/gh.sh with the App-helper
# path overridden, then make one GH call. Prints REPO/WORKSPACE so the test can
# assert the lib's derived values too.
run_lib() {
  local helper="$1"; shift
  : > "$GH_LOG"; : > "$TOKEN_SINK"; : > "$HELPER_LOG"
  (
    cd "$REPO_DIR" || exit 1
    PATH="$STUBBIN:$PATH" GH_LOG="$GH_LOG" TOKEN_SINK="$TOKEN_SINK" HELPER_LOG="$HELPER_LOG" \
      SENTINEL_TOKEN="$SENTINEL" GH_APP_TOKEN_HELPER="$helper" \
      bash -c 'source "$1" || exit 1; shift; GH "$@" || exit $?; printf "REPO=%s\n" "$REPO"' _ "$LIB" "$@"
  ) >"$BASE/out" 2>"$BASE/err"
  RC=$?
}

set_origin() {
  "$REAL_GIT" -C "$REPO_DIR" remote set-url origin "$1"
}

# --- Case 1: helper-backed environment (devcontainer) ---
run_lib "$BASE/gh-app-token.sh" pr view 44 --json headRefName
assert_eq "helper mode: exits zero" 0 "$RC"
assert_contains "helper mode: appends --repo to non-api call" "$GH_LOG" \
  "pr view 44 --json headRefName --repo test/repo"
assert_token "helper mode: gh receives the minted token" "$SENTINEL" "$TOKEN_SINK"
assert_contains "helper mode: helper is scoped to the repo" "$HELPER_LOG" "GITHUB_APP_REPO=test/repo"
assert_contains "helper mode: derives REPO" "$BASE/out" "REPO=test/repo"
assert_not_contains "helper mode: token absent from stdout" "$BASE/out" "$SENTINEL"
assert_not_contains "helper mode: token absent from stderr" "$BASE/err" "$SENTINEL"
assert_not_contains "helper mode: token absent from command log" "$GH_LOG" "$SENTINEL"

# --- Case 2: helper-backed environment, `api` subcommand ---
run_lib "$BASE/gh-app-token.sh" api repos/test/repo/pulls/44
assert_eq "helper mode api: exits zero" 0 "$RC"
assert_contains "helper mode api: no --repo appended" "$GH_LOG" "api repos/test/repo/pulls/44"
if grep -qF -- "--repo" "$GH_LOG"; then
  fail "helper mode api: --repo not appended"
else
  ok "helper mode api: --repo not appended"
fi
assert_token "helper mode api: gh receives the minted token" "$SENTINEL" "$TOKEN_SINK"

# --- Case 3: supported origin formats preserve dots in repository names ---
for origin in \
  https://github.com/acme/widget.js.git \
  git@github.com:acme/widget.js.git \
  ssh://git@github.com/acme/widget.js.git
do
  set_origin "$origin"
  run_lib "$BASE/gh-app-token.sh" pr view 44
  assert_eq "origin $origin: exits zero" 0 "$RC"
  assert_contains "origin $origin: derives dotted repo" "$BASE/out" "REPO=acme/widget.js"
  assert_contains "origin $origin: scopes helper" "$HELPER_LOG" "GITHUB_APP_REPO=acme/widget.js"
done
set_origin https://github.com/test/repo.git

# --- Case 4: helper failures and empty tokens never reach gh ---
cat > "$BASE/failing-helper.sh" <<'SH'
#!/usr/bin/env bash
exit 23
SH
chmod +x "$BASE/failing-helper.sh"
run_lib "$BASE/failing-helper.sh" pr view 44
assert_eq "failing helper: preserves failure" 23 "$RC"
assert_contains "failing helper: useful error" "$BASE/err" "failed to mint"
assert_eq "failing helper: gh never invoked" "" "$(cat "$GH_LOG")"
assert_token "failing helper: no token delivered" "" "$TOKEN_SINK"

cat > "$BASE/empty-helper.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BASE/empty-helper.sh"
run_lib "$BASE/empty-helper.sh" pr view 44
assert_eq "empty helper: exits nonzero" 1 "$RC"
assert_contains "empty helper: useful error" "$BASE/err" "empty token"
assert_eq "empty helper: gh never invoked" "" "$(cat "$GH_LOG")"
assert_token "empty helper: no token delivered" "" "$TOKEN_SINK"

# --- Case 5: missing App helper fails closed, even with logged-in stub gh ---
run_lib "$BASE/absent-helper.sh" pr view 44 --json headRefName
assert_eq "missing helper: exits nonzero" 1 "$RC"
assert_contains "missing helper: directs user to setup" "$BASE/err" "/setup"
assert_eq "missing helper: gh never invoked" "" "$(cat "$GH_LOG")"
assert_token "missing helper: no token delivered" "" "$TOKEN_SINK"
assert_eq "missing helper: helper never invoked" "" "$(cat "$HELPER_LOG")"

# --- Case 6: missing App helper also blocks the `api` subcommand ---
run_lib "$BASE/absent-helper.sh" api repos/test/repo/pulls/44
assert_eq "missing helper api: exits nonzero" 1 "$RC"
assert_contains "missing helper api: directs user to setup" "$BASE/err" "/setup"
assert_eq "missing helper api: gh never invoked" "" "$(cat "$GH_LOG")"
assert_token "missing helper api: no token delivered" "" "$TOKEN_SINK"

# --- Case 7: invalid origins fail before helper or gh ---
set_origin https://github.com/acme/team/widget.git
run_lib "$BASE/gh-app-token.sh" pr view 44
assert_eq "invalid origin: exits nonzero" 1 "$RC"
assert_contains "invalid origin: useful error" "$BASE/err" "invalid GitHub origin"
assert_eq "invalid origin: helper never invoked" "" "$(cat "$HELPER_LOG")"
assert_eq "invalid origin: gh never invoked" "" "$(cat "$GH_LOG")"

# --- Case 8: the production default path is unchanged ---
if grep -qF '/opt/agent-devcontainer/gh-app-token.sh' "$LIB"; then
  ok "default: devcontainer helper path preserved"
else
  fail "default: devcontainer helper path preserved"
fi

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
