#!/usr/bin/env bash
# Tests for scripts/diagnose-dirty-main.sh — read-only dirty-tree diagnosis.
# Self-contained: builds disposable temp git repos per case, no framework,
# no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSE="$SCRIPT_DIR/../diagnose-dirty-main.sh"

PASS=0
FAIL=0
TMP_DIRS=()

cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

assert_contains() {
  # assert_contains <desc> <haystack> <needle>
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$desc" ;;
    *) fail "$desc (missing [$needle] in output: $haystack)" ;;
  esac
}

new_repo() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  echo "$d"
}

# --- case 1: clean repo ---
repo="$(new_repo)"
echo "tracked" > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -q -m init
out="$(cd "$repo" && "$DIAGNOSE" 2>&1)"; code=$?
[ "$code" -eq 0 ] && ok "case1: clean repo exits 0" || fail "case1: clean repo exits 0 (code $code)"
assert_contains "case1: reports clean" "$out" "clean"

# --- case 2: staged deletion shows under Staged changes ---
repo="$(new_repo)"
echo "tracked" > "$repo/old-file.txt"
git -C "$repo" add old-file.txt
git -C "$repo" commit -q -m init
git -C "$repo" rm -q --cached old-file.txt
out="$(cd "$repo" && "$DIAGNOSE" 2>&1)"; code=$?
[ "$code" -eq 0 ] && ok "case2: exits 0" || fail "case2: exits 0 (code $code)"
assert_contains "case2: staged deletion reported" "$out" "old-file.txt"

# --- case 3: tree with only ignored paths is clean (no staged/untracked non-ignored) ---
repo="$(new_repo)"
echo "tracked" > "$repo/tracked.txt"
printf 'ignored-scaffold/\n' > "$repo/.gitignore"
git -C "$repo" add tracked.txt .gitignore
git -C "$repo" commit -q -m init
mkdir -p "$repo/ignored-scaffold"
echo "x" > "$repo/ignored-scaffold/x.txt"
out="$(cd "$repo" && "$DIAGNOSE" 2>&1)"; code=$?
[ "$code" -eq 0 ] && ok "case3: only ignored paths exits 0 (clean)" || fail "case3: only ignored paths exits 0 (code $code)"
assert_contains "case3: reports clean when only ignored" "$out" "clean"

# --- case 4: untracked path with no matching rule reported as NOT ignored ---
repo="$(new_repo)"
echo "tracked" > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -q -m init
echo "new" > "$repo/new-file.txt"
out="$(cd "$repo" && "$DIAGNOSE" 2>&1)"
assert_contains "case4: unignored path reported as NOT ignored" "$out" "new-file.txt: NOT ignored"

# --- case 5: mixed staged + both kinds of untracked in one run ---
repo="$(new_repo)"
echo "tracked" > "$repo/old-file.txt"
printf 'ignored-scaffold/\n' > "$repo/.gitignore"
git -C "$repo" add old-file.txt .gitignore
git -C "$repo" commit -q -m init
git -C "$repo" rm -q --cached old-file.txt
mkdir -p "$repo/ignored-scaffold"
echo "x" > "$repo/ignored-scaffold/x.txt"
echo "new" > "$repo/new-file.txt"
out="$(cd "$repo" && "$DIAGNOSE" 2>&1)"
assert_contains "case5: staged deletion present" "$out" "old-file.txt"
assert_contains "case5: ignored path present" "$out" "ignored-scaffold/: ignored"
assert_contains "case5: unignored path present" "$out" "new-file.txt: NOT ignored"

# --- case 6: usage error on unexpected argument ---
repo="$(new_repo)"
(cd "$repo" && "$DIAGNOSE" extra-arg) >/dev/null 2>&1
code=$?
[ "$code" -ne 0 ] && ok "case6: nonzero exit on usage error" || fail "case6: nonzero exit on usage error (code $code)"

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
