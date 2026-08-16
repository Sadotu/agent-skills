#!/usr/bin/env bash
# Mechanical contract for the compressed github-issue instructions (issue #48).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SKILL="$ROOT/skills/github-issue/SKILL.md"
REFERENCE="$ROOT/skills/github-issue/references/baseline-failure-triage.md"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1${2:+ ($2)}"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"; else fail "$desc" "expected [$expected], got [$actual]"; fi
}

replacement='Write both in plain language for a reviewer who has not read the issue or code. Keep them short and explain unavoidable technical terms. **Problem** describes what goes wrong and its impact without proposing a fix. **Approach** describes the smallest behavior-level solution and deliberate non-goals without implementation detail.'
assert_eq "replacement Problem/Approach guidance appears exactly once" 1 \
  "$(grep -Fxc "$replacement" "$SKILL")"

if [ -f "$REFERENCE" ]; then
  ok "conditional baseline-failure reference exists"
else
  fail "conditional baseline-failure reference exists" "missing $REFERENCE"
fi
reference_target='references/baseline-failure-triage.md'
assert_eq "SKILL.md contains the baseline-failure reference exactly once" 1 \
  "$(grep -Fo "$reference_target" "$SKILL" | wc -l | tr -d ' ')"
reference_pattern='references/baseline-failure-triage\.md'
if grep -EiEq "\b(if|when)\b.*baseline.*fails.*\]\($reference_pattern\)" "$SKILL"; then
  ok "baseline-failure reference is gated by an explicit condition"
else
  fail "baseline-failure reference is gated by an explicit condition"
fi

baseline_section="$(awk '
  /^### Baseline-failure triage/ { section=1; print; next }
  section && /^(##|###) / { exit }
  section { print }
' "$SKILL")"
baseline_section_words="$(printf '%s\n' "$baseline_section" | wc -w | tr -d ' ')"
if [ -n "$baseline_section" ] && [ "$baseline_section_words" -le 100 ]; then
  ok "inline baseline-failure contract is concise"
else
  fail "inline baseline-failure contract is concise" "$baseline_section_words words"
fi
if printf '%s\n' "$baseline_section" | grep -Eq '^[[:space:]]*([0-9]+\.|[-*])[[:space:]]|^```'; then
  fail "baseline evidence procedure lists and code blocks are absent from SKILL.md"
else
  ok "baseline evidence procedure lists and code blocks are absent from SKILL.md"
fi
if grep -Eq -- '--reproduces-on-main|--overlaps-surface|--branch-worsened|--branch-resolved|--ambiguous|Accepted baseline failure' "$SKILL"; then
  fail "detailed baseline triage is absent from SKILL.md"
else
  ok "detailed baseline triage is absent from SKILL.md"
fi

for phase in 1 2 3 4 5 6; do
  assert_eq "Phase $phase heading appears exactly once" 1 \
    "$(grep -Ec "^## Phase $phase([[:space:]]|—)" "$SKILL")"
done
if grep -Fq 'unless it explicitly inspects the primary worktree' "$SKILL"; then
  ok "post-isolation commands may explicitly inspect the primary worktree"
else
  fail "post-isolation commands may explicitly inspect the primary worktree"
fi
word_count="$(wc -w < "$SKILL" | tr -d ' ')"
if [ "$word_count" -lt 2000 ]; then
  ok "SKILL.md is under 2000 words"
else
  fail "SKILL.md is under 2000 words" "$word_count words"
fi

# The remaining Red Flags must not repeat one another verbatim. Repeating a
# complete bullet is a useful mechanical lower bound for the editorial rule.
red_flags="$(sed -n '/^## Red Flags/,/^## /p' "$SKILL" | grep '^- ' || true)"
red_flag_count="$(printf '%s\n' "$red_flags" | sed '/^$/d' | wc -l | tr -d ' ')"
unique_red_flag_count="$(printf '%s\n' "$red_flags" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
assert_eq "remaining Red Flags are unique" "$red_flag_count" "$unique_red_flag_count"

# Extract the documented classifier example, replace its placeholders, and
# execute it against a strict stub. This catches continuation-line comments:
# they become unexpected arguments even though `bash -n` accepts the syntax.
if [ -f "$REFERENCE" ]; then
  example="$(awk '
    /^```bash$/ { block=1; text=""; next }
    block && /^```$/ {
      if (text ~ /scripts\/baseline-triage\.sh/) { printf "%s", text; exit }
      block=0; next
    }
    block { text=text $0 "\n" }
  ' "$REFERENCE")"
  if [ -z "$example" ]; then
    fail "reference contains a baseline classifier example"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/classifier" <<'STUB'
#!/usr/bin/env bash
[ "$#" -eq 10 ] || exit 80
expected=(--reproduces-on-main yes --overlaps-surface no --branch-worsened no --branch-resolved no --ambiguous no)
[ "$*" = "${expected[*]}" ] || exit 81
STUB
    chmod +x "$tmp/classifier"
    runnable="${example/scripts\/baseline-triage.sh/$tmp\/classifier}"
    runnable="${runnable//<yes|no>/no}"
    runnable="${runnable/--reproduces-on-main no/--reproduces-on-main yes}"
    if bash -n <<<"$runnable" && bash -c "$runnable"; then
      ok "classifier example is valid after replacing placeholders"
    else
      fail "classifier example is valid after replacing placeholders"
    fi
  fi
fi

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
