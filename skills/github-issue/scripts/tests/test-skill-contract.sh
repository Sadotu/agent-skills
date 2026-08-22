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

replacement='Write both in plain language for a reviewer who has not read the issue or code, and explain unavoidable technical terms. **Problem** describes what goes wrong and its impact without proposing a fix. **Approach** describes the smallest behavior-level solution and deliberate non-goals without implementation detail.'
assert_eq "replacement Problem/Approach guidance appears exactly once" 1 \
  "$(grep -Fxc "$replacement" "$SKILL")"

assert_eq "Problem/Approach one-sentence cap is documented" 1 \
  "$(grep -Fc 'capped at one sentence' "$SKILL")"
assert_eq "mechanical trailing-period check is documented" 1 \
  "$(grep -Fc 'strip one trailing period from each bullet and confirm no period remains' "$SKILL")"

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

if grep -Fq 'exit 1' "$SKILL" && \
   grep -Fq 'before the fast-forward' "$SKILL" && \
   grep -Fq 'other nonzero' "$SKILL"; then
  ok "isolation diagnosis distinguishes unsafe-base exit 1 before fast-forward from command errors"
else
  fail "isolation diagnosis distinguishes unsafe-base exit 1 before fast-forward from command errors"
fi
# Regression fixture (issue #51), modeled on Sadotu/agent-devcontainer#65: the
# request was to skip one existing warning unless a workspace opts in, and the
# workflow still produced a new one-caller library plus build wiring across
# exactly five production files, with tests excluded from the size estimate.
# Each assertion below is a rule that would have kept that change inline.
gate_section="$(awk '
  /^## Phase 3 / { section=1 }
  section && /^## Phase 4 / { exit }
  section { print }
' "$SKILL")"
if printf '%s\n' "$gate_section" | grep -Fq 'inline baseline' && \
   printf '%s\n' "$gate_section" | grep -Eq 'before (proposing|you propose)'; then
  ok "#65 fixture: inline baseline is recorded before architecture selection"
else
  fail "#65 fixture: inline baseline is recorded before architecture selection"
fi
if printf '%s\n' "$gate_section" | grep -Eq 'existing code path' && \
   printf '%s\n' "$gate_section" | grep -Eq 'existing test'; then
  ok "#65 fixture: gate asks whether the existing code path and test boundary suffice"
else
  fail "#65 fixture: gate asks whether the existing code path and test boundary suffice"
fi
if grep -Eq 'documentation, configuration, and (Docker/)?build wiring' "$SKILL"; then
  ok "#65 fixture: budgets count tests, docs, configuration, and build wiring"
else
  fail "#65 fixture: budgets count tests, docs, configuration, and build wiring"
fi
if grep -Eq 'reaches five changed files' "$SKILL" && ! grep -Fq 'more than five production files' "$SKILL"; then
  ok "#65 fixture: file threshold is inclusive and not production-only"
else
  fail "#65 fixture: file threshold is inclusive and not production-only"
fi
if grep -Eq 'one caller' "$SKILL" && grep -Fq 'cannot meet' "$SKILL"; then
  ok "#65 fixture: a one-caller module must cite the criterion the inline baseline cannot meet"
else
  fail "#65 fixture: a one-caller module must cite the criterion the inline baseline cannot meet"
fi
if printf '%s\n' "$gate_section" | grep -Fq 'compact path'; then
  ok "#65 fixture: qualifying small changes take a compact path"
else
  fail "#65 fixture: qualifying small changes take a compact path"
fi
verify_section="$(awk '
  /^## Phase 5 / { section=1 }
  section && /^## Phase 6 / { exit }
  section { print }
' "$SKILL")"
if printf '%s\n' "$verify_section" | grep -Fq 'inline baseline' && \
   printf '%s\n' "$verify_section" | grep -Fq 'not your own estimate'; then
  ok "#65 fixture: final review compares the diff against the recorded inline baseline"
else
  fail "#65 fixture: final review compares the diff against the recorded inline baseline"
fi

# Fixture (issue #54): the compact path must skip subagent-driven-development
# entirely, while non-compact work keeps the existing subagent workflow.
implement_section="$(awk '
  /^## Phase 4 / { section=1 }
  section && /^## Phase 5 / { exit }
  section { print }
' "$SKILL")"
compact_skip_line='On the compact path, implement directly in this session — do not invoke `superpowers:subagent-driven-development` or dispatch implementation or review subagents.'
assert_eq "#54 fixture: compact path skips subagent-driven-development" 1 \
  "$(grep -Fxc "$compact_skip_line" "$SKILL")"
if printf '%s\n' "$implement_section" | grep -Fq 'REQUIRED SUB-SKILL' && \
   printf '%s\n' "$implement_section" | grep -Fq 'superpowers:subagent-driven-development'; then
  ok "#54 fixture: non-compact path still requires subagent-driven-development"
else
  fail "#54 fixture: non-compact path still requires subagent-driven-development"
fi

word_count="$(wc -w < "$SKILL" | tr -d ' ')"
if [ "$word_count" -lt 2000 ]; then
  ok "SKILL.md is under 2000 words"
else
  fail "SKILL.md is under 2000 words" "$word_count words"
fi

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
