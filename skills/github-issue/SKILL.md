---
name: github-issue
description: Use when working a GitHub issue in this repo end-to-end — from a bare issue number, a full issue URL, or "work this issue" with no plan/build handoff.
---

# GitHub Issue — End to End

A single continuous workflow — select the issue, design, implement, verify, PR — run in order in one session. There is no plan/build handoff.

**Preconditions:**

- **Run all phases in one shell session** so `$REPO`, `$WORKSPACE`, and the `GH` helper below persist. This harness may run each command in a fresh shell; if the shell resets, re-run the setup block before continuing.
- **GitHub App authentication is mandatory.** Never use the GitHub connector, a user PAT, `gh auth login`, or `gh auth setup-git`. If App authentication is unavailable, stop and run `/setup`.

**Core principle:** the issue description is the leading input — it seeds the design work and is the spec you verify the result against. The PR opens as a draft *before* any design work, so the user reviews the whole design conversation asynchronously in the PR body rather than live.

Setup — source the fail-closed App helper used by the scripts:

```bash
WORKSPACE="$(git rev-parse --show-toplevel)"
source "$WORKSPACE/skills/github-issue/scripts/lib/gh.sh"
```

Use `GIT_AUTH` for every network Git command. It forces the canonical
`https://github.com/$REPO.git` route, mints a fresh App token, clears ambient
credentials for that command, and supplies only the scoped `x-access-token`
credential. Never run network `git` directly; if App token minting fails,
stop and repair it with `/setup`.

---

## Phase 1 — Select and Understand

Resolve the issue number:

- Full issue URL: extract the number, and confirm its repo matches `$REPO` — if it doesn't, stop and ask (this skill only works issues in the current repo).
- Bare number: use it directly.
- None named: run `GH issue list` and ask the user to choose.

Read the selected issue and treat its description as the specification:

```bash
GH issue view <number>
```

Summarize: request, current behavior, expected outcome, acceptance criteria, linked context. Inspect the relevant files before trusting the issue's diagnosis. Keep the issue number and original acceptance criteria visible throughout.

---

## Phase 2 — Synchronize and Isolate (before any issue commit)

**REQUIRED SUB-SKILL:** Use `superpowers:using-git-worktrees`.

**CRITICAL — synchronize before writing or committing issue work.** `git fetch` updates `origin/main`, not local `main`. Committing in the primary worktree before isolation pollutes local `main` and makes it diverge.

`scripts/isolate.sh` checks the current branch and cleanliness, fetches (updating remote refs), rejects an unsafe base, and may fast-forward a clean local `main`. Only the wrong-branch, dirty-tree, and unsafe-base checks complete before the fast-forward; a later failure may leave local `main` synchronized. The script then branches from `origin/main`, creates the worktree, and opens the draft PR. On failure, diagnose the condition below and ask for direction. Use a 3–5 word kebab-case slug; `<worktree-path>` is `.claude/worktrees/agent-<number>-<slug>`. After isolation, run every write, commit, test, and Git command there unless it explicitly inspects the primary worktree.

```bash
scripts/isolate.sh <number> <slug> <worktree-path> "<title referencing #<number>>"
```

Report the PR URL before generating design questions. It stays draft until Phase 6.

### Isolation-guard diagnosis (read-only)

If isolation fails, inspect the primary worktree with `git branch --show-current` and `git status --porcelain`. The first guards run in this order: a branch other than `main` means wrong branch; `main` with nonempty porcelain means dirty main. After both pass and fetch succeeds, exit 1 from `git merge-base --is-ancestor main origin/main` establishes an unsafe base before the fast-forward. Any other nonzero exit, including an error from that command or a later merge, equality, worktree, commit, push, or PR command, must be reported as the actual command failure; local `main` may already have been fast-forwarded. App-auth failures require `/setup`. For dirty main, run:

```bash
scripts/diagnose-dirty-main.sh
```

This read-only script separates staged, unstaged, untracked, and ignored state. Report its result and ask; never alter pre-existing primary-worktree state.

### Baseline-failure triage (unattended override)

When the isolated baseline fails during an unattended run, follow the [baseline-failure triage procedure](references/baseline-failure-triage.md). It overrides only the upstream pause gate and fails closed: continue only when every failure is proven pre-existing and unrelated; otherwise stop and ask. Interactive runs always stop and ask.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL (unless the small-change gate below selects the compact path):** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review).

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

**Prefer the simplest design that satisfies the issue; avoid speculative requirements.**

**Small-change gate — settle this before proposing any approach.** First record the inline baseline: the smallest edit to the existing code path, covered at an existing test boundary, with its changed-file and changed-line count. Then answer three questions. Can every acceptance criterion be met by editing that existing code path? Can regression coverage go in an existing test boundary? Does a proposed new module solve a concrete technical impossibility, rather than only making testing or organization easier? On yes, yes, and no, constrain the work to that code path and test boundary and take the **compact path**: skip brainstorming, the design doc, the plan file, and the artifact manifest below, and record scope, expected diff, focused test, and verification in the PR body instead.

Otherwise record the expected files and approximate size in the plan. Size and file budgets count every changed line and file — production, tests, documentation, configuration, and Docker/build wiring. Every added behavior must map to an acceptance criterion or demonstrated regression; if the change grows beyond roughly twice the inline baseline, redesign around the simplest viable solution, and require explicit user approval for speculative hardening.

Once the design doc and plan are written, replace the PR body placeholders. `## Summary` should tell reviewers what the PR solves and how, before the design log and diff:

```bash
GH pr edit <pr-number> --body "$(cat <<'EOF'
Closes #<number>

## Summary
- **Problem:** <what the issue requires>
- **Approach:** <how this PR solves it>

## Design Decisions
- **Q:** <question> — **A:** <answer chosen> — **Why:** <reasoning>
- ...
EOF
)"
```

Write both in plain language for a reviewer who has not read the issue or code. Keep them short and explain unavoidable technical terms. **Problem** describes what goes wrong and its impact without proposing a fix. **Approach** describes the smallest behavior-level solution and deliberate non-goals without implementation detail.

The PR body is the asynchronous design record. Then use `superpowers:writing-plans`.

Write two artifacts inside `<worktree-path>` as **session-local working files** — the plan drives Phase 4, the design records the decisions. They must **not** land in the PR diff, so Git-exclude them before writing; the cleanup workflow owns their eventual removal with the worktree:

```bash
excl="$(git rev-parse --git-path info/exclude)"
grep -qxF 'docs/superpowers/' "$excl" || echo 'docs/superpowers/' >> "$excl"
```

Keep the exact relative paths used for this run:

```bash
design_path="docs/superpowers/specs/<YYYY-MM-DD>-<slug>-design.md"
plan_path="docs/superpowers/plans/<YYYY-MM-DD>-<slug>.md"
```

- Design: `$design_path`
- Plan: `$plan_path`

After writing both files, record those two paths for the cleanup workflow. Set
`pr_number` to the PR selected in Phase 2:

```bash
git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
case "$git_common_dir" in /*) ;; *) git_common_dir="$WORKSPACE/$git_common_dir" ;; esac
artifact_manifest="$git_common_dir/github-issue/artifacts/pr-${pr_number}.paths"
mkdir -p "$(dirname "$artifact_manifest")"
printf '%s\n' "$design_path" "$plan_path" > "$artifact_manifest"
```

The plan must record the issue number and URL, the original acceptance criteria, and the PR closing reference `Closes #<number>`. Confirm `git status --porcelain` shows neither artifact before continuing.

---

## Phase 4 — Implement

### Implementation constraints

- Implement only the behavior explicitly described in this issue.
- Do not add speculative retries, backoff, compatibility layers, additional
  commands, abstractions, extension points, or temporary alternatives.
- If a dependency is unavailable, stop and report the dependency.
- Every new production module and persistent state field must map to a named
  acceptance criterion. A module with only one caller must also name the
  acceptance criterion the inline baseline cannot meet.
- If the change reaches five changed files of any kind, or introduces a new
  state machine, pause and present the simpler alternative first.
- Verify changed behavior through observable behavior at the smallest practical
  boundary. Source text, generated arguments, or mock calls alone are not proof
  of runtime behavior.
- Exercise at least one realistic failure where relevant. Process wrappers must
  preserve the underlying exit status; other integrations must verify the
  relevant error or response semantics.
- Do not add test infrastructure solely for this verification. If the relevant
  boundary is unavailable, report the gap instead of claiming it was verified.

**REQUIRED SUB-SKILL:** Use `superpowers:subagent-driven-development`.

Execute the plan task by task with fresh subagents and the skill's review stages when subagent tools are available (discover deferred tools with `tool_search` if needed). If they are unavailable, say so and execute directly, preserving the same task boundaries, test-first discipline, and review checkpoints — never silently omit review.

Follow `superpowers:test-driven-development` for every behavior change unless the user explicitly approves an exception.

---

## Phase 5 — Verify Against the Issue

**REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`.

Run focused tests plus the repository checks appropriate to the changed surface. Re-read the original issue and verify each acceptance criterion against current evidence:

```bash
GH issue view <number>
```

Do not claim completion from prior output, expected behavior, or a passing subset that does not cover the requested outcome.

Re-check every baseline failure recorded under the Phase 2 procedure. Any regression or overlap with the final change surface blocks readiness; otherwise preserve the confirmed-unchanged evidence in the PR verification summary.

**Before finalizing, compare the full diff against the inline baseline recorded in Phase 3** — that concrete alternative, not your own estimate. Justify every file and behavior beyond it against a named acceptance criterion, or simplify.

Report changed line counts separately by kind: production, test, documentation, configuration, and Docker/build wiring.

---

## Phase 6 — Finish (with stale-base guard)

**REQUIRED SUB-SKILL:** Use `superpowers:finishing-a-development-branch`.

**Before pushing, guard against a stale base** — a branch far behind `origin/main` produces a bloated, dangerous PR diff:

```bash
GIT_AUTH fetch origin '+refs/heads/*:refs/remotes/origin/*'
base=$(git merge-base origin/main HEAD)
behind=$(git rev-list --count "$base"..origin/main)
[ "$behind" -gt 50 ] && echo "STALE BASE: $behind commits behind origin/main — rebase before PR"
```

If stale, `git rebase origin/main` (resolve conflicts, drop already-merged commits), then re-run Phase 5. Confirm `git diff --stat origin/main...HEAD` shows only your intended files before finalizing.

**The PR already exists (opened in Phase 2) — finalize it, don't create a new one:**

- Push the final commits to the existing branch.
- Update the existing PR body: make the Summary's **Approach** match the actual diff, then append verification results against the acceptance criteria below Design Decisions. Preserve the single `Closes #<number>` line and Summary block. Because the spec and plan are session-local, do not link their paths.
- Hand off: `scripts/finish-handoff.sh <pr-number> <number>`. It marks the PR ready for the repository owner on both manual and managed runs, and starts no automated review, repair, approval, or merge phase.
- Report its stderr line alongside the branch name and PR URL.

Do not merge unless the user explicitly requests it.
Approval and merge remain explicit repository-owner actions.

In the devcontainer, Worktree Warden cleans the terminal PR automatically.
Outside it, run `/github-pr-cleanup <pr-number>` after the PR is merged or closed.

---
