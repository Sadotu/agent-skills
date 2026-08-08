#!/usr/bin/env bash
# Self-contained TAP-style tests for inspect.sh. No network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSPECT="$SCRIPT_DIR/../inspect.sh"
REAL_GIT="$(command -v git)"
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
assert_contains() {
  if grep -qF "$3" "$2"; then ok "$1"; else fail "$1 (missing [$3])"; fi
}

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
REPO="$BASE/repo"; WT="$BASE/repair"; BIN="$BASE/bin"; LOG="$BASE/gh.log"
mkdir -p "$REPO" "$BIN"
"$REAL_GIT" -C "$REPO" init -q
"$REAL_GIT" -C "$REPO" config user.email test@example.com
"$REAL_GIT" -C "$REPO" config user.name Test
"$REAL_GIT" -C "$REPO" commit --allow-empty -qm init
"$REAL_GIT" -C "$REPO" branch -M main
"$REAL_GIT" -C "$REPO" worktree add -qb agent/26-repair "$WT"

cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "worktree list" ] && [ "${STUB_WORKTREES+x}" = x ]; then
  printf '%b' "$STUB_WORKTREES"
else
  exec "$REAL_GIT" "$@"
fi
SH
chmod +x "$BIN/git"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2" = "repo view" ]; then echo test/repo; exit 0; fi
case "$1 $2 ${5:-${4:-}}" in
  "issue view labels,body,updatedAt")
    jq -n --arg body "$STUB_ISSUE_BODY" --arg updated "$STUB_ISSUE_UPDATED" --arg labels "$STUB_LABELS" \
      '{body:$body,updatedAt:$updated,labels:($labels|split(",")|map(select(length>0)|{name:.}))}' ;;
  "issue view body,updatedAt")
    jq -n --arg body "$STUB_ISSUE_BODY" --arg updated "$STUB_ISSUE_UPDATED" '{body:$body,updatedAt:$updated}' ;;
  "pr view body,headRefName,comments")
    jq -n --arg body "$STUB_PR_BODY" --arg head "$STUB_BRANCH" --argjson comments "$STUB_COMMENTS" \
      '{body:$body,headRefName:$head,comments:$comments}' ;;
  "pr view headRefOid,body,updatedAt")
    jq -n --arg head "$STUB_HEAD" --arg body "$STUB_PR_BODY" --arg updated "$STUB_PR_UPDATED" \
      '{headRefOid:$head,body:$body,updatedAt:$updated}' ;;
  "api repos/test/repo/pulls/44 .base.sha") echo "$STUB_BASE" ;;
  *) echo "unexpected gh call: $*" >&2; exit 91 ;;
esac
SH
chmod +x "$BIN/gh"

ISSUE_BODY="managed issue"; PR_BODY=$'repair details\n\nCloses #26'
HEAD=deadbeef BASE_SHA=cafebabe
FP="$(printf '%s\x1e%s\x1e%s\x1e%s' "$HEAD" "$BASE_SHA" "$ISSUE_BODY" "$PR_BODY" | sha256sum | awk '{print $1}')"
GOOD_BODY=$'Automated review\n<!-- review-pr:v1 {"issue":26,"pr":44,"fingerprint":"'"$FP"'","verdict":"BLOCKING"} -->'
DEFAULT_WORKTREES="worktree $REPO\nHEAD 0000\nbranch refs/heads/main\n\nworktree $WT\nHEAD $HEAD\nbranch refs/heads/agent/26-repair\n\n"

run_case() {
  local name="$1" issue="${2:-26}" pr="${3:-44}" fp="${4:-$FP}"
  : > "$LOG"
  PATH="$BIN:$PATH" REAL_GIT="$REAL_GIT" GH_LOG="$LOG" \
    STUB_LABELS="${CASE_LABELS-agent-running}" STUB_ISSUE_BODY="${CASE_ISSUE_BODY-$ISSUE_BODY}" \
    STUB_ISSUE_UPDATED=2026-08-01T00:00:00Z STUB_PR_BODY="${CASE_PR_BODY-$PR_BODY}" \
    STUB_PR_UPDATED=2026-08-02T00:00:00Z STUB_BRANCH="${CASE_BRANCH-agent/26-repair}" \
    STUB_HEAD="$HEAD" STUB_BASE="$BASE_SHA" STUB_COMMENTS="${CASE_COMMENTS:-$(jq -nc --arg body "$GOOD_BODY" '[{viewerDidAuthor:true,body:$body}]')}" \
    STUB_WORKTREES="${CASE_WORKTREES-$DEFAULT_WORKTREES}" \
    "$INSPECT" "$issue" "$pr" "$fp" >"$BASE/$name.out" 2>"$BASE/$name.err"
  CASE_RC=$?
}
reset_case() { unset CASE_LABELS CASE_ISSUE_BODY CASE_PR_BODY CASE_BRANCH CASE_COMMENTS CASE_WORKTREES; }
reject_case() {
  local name="$1" message="$2"; shift 2
  run_case "$name" "$@"
  assert_eq "$name: rejected" 1 "$CASE_RC"
  assert_contains "$name: useful error" "$BASE/$name.err" "$message"
  if grep -Eq '(^| )(edit|comment|create|delete|merge|close|reopen|review)( |$)' "$LOG"; then
    fail "$name: no mutation"
  else ok "$name: no mutation"; fi
  reset_case
}

run_case success
assert_eq "success: exits zero" 0 "$CASE_RC"
assert_eq "success: issue" 26 "$(jq -r .issue "$BASE/success.out")"
assert_eq "success: pr" 44 "$(jq -r .pr "$BASE/success.out")"
assert_eq "success: fingerprint" "$FP" "$(jq -r .fingerprint "$BASE/success.out")"
assert_eq "success: head" "$HEAD" "$(jq -r .head "$BASE/success.out")"
assert_eq "success: base" "$BASE_SHA" "$(jq -r .base "$BASE/success.out")"
assert_eq "success: branch" agent/26-repair "$(jq -r .branch "$BASE/success.out")"
assert_eq "success: worktree" "$WT" "$(jq -r .worktree "$BASE/success.out")"
assert_eq "success: exact trusted body" "$GOOD_BODY" "$(jq -r .commentBody "$BASE/success.out")"

reject_case bad-issue "invalid issue-number" nope 44 "$FP"
reject_case bad-pr "invalid pr-number" 26 nope "$FP"
CASE_LABELS="bug"; reject_case unmanaged "agent-running"
CASE_PR_BODY="mentions #26 without closure"; reject_case link "closing linkage"
CASE_BRANCH="feature/26-repair"; reject_case branch "managed branch"
CASE_WORKTREES="worktree $REPO\nHEAD 0000\nbranch refs/heads/main\n\n"; reject_case missing-worktree "exactly one worktree"
CASE_WORKTREES="$DEFAULT_WORKTREES"$'worktree /tmp/duplicate\nHEAD deadbeef\nbranch refs/heads/agent/26-repair\n\n'; reject_case duplicate-worktree "exactly one worktree"

CASE_COMMENTS="$(jq -nc --arg body "$GOOD_BODY" '[{viewerDidAuthor:false,body:$body}]')"; reject_case foreign "trusted review marker"
CASE_COMMENTS='[{"viewerDidAuthor":true,"body":"<!-- review-pr:v1 {broken} -->"}]'; reject_case malformed "well-formed"
CASE_COMMENTS="$(jq -nc --arg fp "$FP" '[{viewerDidAuthor:true,body:("<!-- review-pr:v1 " + ({issue:26,pr:44,fingerprint:$fp,verdict:"PASS"}|tojson) + " -->")}]')"; reject_case pass "BLOCKING"
CASE_COMMENTS="$(jq -nc --arg fp "$FP" '[{viewerDidAuthor:true,body:("<!-- review-pr:v1 " + ({issue:27,pr:44,fingerprint:$fp,verdict:"BLOCKING"}|tojson) + " -->")}]')"; reject_case wrong-issue "issue/pr"
CASE_COMMENTS="$(jq -nc --arg fp "$FP" '[{viewerDidAuthor:true,body:("<!-- review-pr:v1 " + ({issue:26,pr:45,fingerprint:$fp,verdict:"BLOCKING"}|tojson) + " -->")}]')"; reject_case wrong-pr "issue/pr"
STALE="${FP%?}0"; [ "$STALE" = "$FP" ] && STALE="${FP%?}1"
CASE_COMMENTS="$(jq -nc --arg fp "$STALE" '[{viewerDidAuthor:true,body:("<!-- review-pr:v1 " + ({issue:26,pr:44,fingerprint:$fp,verdict:"BLOCKING"}|tojson) + " -->")}]')"; reject_case stale "stale" 26 44 "$STALE"

echo "1..$((PASS + FAIL))"
echo "# pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
