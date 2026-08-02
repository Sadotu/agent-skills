---
name: github-issue
description: Use when working a GitHub issue in this repo end-to-end — from a bare issue number, a full issue URL, or "work this issue" with no plan/build handoff.
---

# GitHub Issue — End to End

A single continuous workflow — select the issue, design, implement, verify, PR — run in order in one session. There is no plan/build handoff.

**Preconditions:**

- **Run all phases in one shell session** so `$REPO`, `$WORKSPACE`, and the `GH` helper below persist. This harness may run each command in a fresh shell; if the shell resets, re-run the setup block before continuing.
- **Authentication adapts to the environment.** Inside the agent devcontainer, `gh` and git push use the GitHub App (helper baked into the image). Anywhere else — a WSL host, a plain container — they use your own `gh` login; run `gh auth login` and `gh auth setup-git` once first. The `GH` helper below selects the right path automatically.

**Core principle:** the issue description is the leading input — it seeds the design work and is the spec you verify the result against. The PR opens as a draft *before* any design work, so the user reviews the whole design conversation asynchronously in the PR body rather than live.

Setup — resolve the repo dynamically (never hardcode an owner/repo) and define the authenticated `gh` shorthand used throughout:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
WORKSPACE="$(git rev-parse --show-toplevel)"
if [ -x /opt/agent-devcontainer/gh-app-token.sh ]; then
  # devcontainer: mint a short-lived GitHub App token per call
  GH() { GH_TOKEN="$(GITHUB_APP_REPO=$REPO /opt/agent-devcontainer/gh-app-token.sh)" gh "$@" --repo "$REPO"; }
else
  # elsewhere: use your own authenticated gh (run `gh auth login` first)
  GH() { gh "$@" --repo "$REPO"; }
fi
```

`git` push/fetch rely on whatever credential helper the environment wired — the container's App helper, or `gh auth setup-git` on a host — so no manual token is needed either way.

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

`scripts/isolate.sh` syncs the primary worktree with `origin/main`, isolates issue work into its own worktree and branch, and opens the draft PR — all before any issue commit happens. It guarantees issue work is never committed onto a dirty or diverged `main`: on any guard failure it exits nonzero without mutating the primary worktree, preserving user work so you can report the exact condition and ask for direction. Use a 3–5 word kebab-case slug. From here on, run all writes, commits, tests, and Git commands in `<worktree-path>` unless a command explicitly inspects the primary worktree. Convention: `<worktree-path>` is `.claude/worktrees/agent-<number>-<slug>`; pass an optional 5th `base-ref` arg (e.g. `origin/agent/82-other-issue`) when this issue's work must stack on another in-flight branch instead of `origin/main`.

```bash
scripts/isolate.sh <number> <slug> <worktree-path> "<title referencing #<number>>"
```

Report the PR URL to the user now — it is the first thing they see, before any design question is generated. The PR stays **draft** until Phase 6 finalizes it — marked ready on a manual run, or handed to `issue-orchestrator` still draft on a managed run.

### Dirty-tree triage (read-only, when the guard trips)

If `scripts/isolate.sh` exits nonzero, check both `git branch --show-current` and `git status --porcelain` in the primary worktree yourself — if you're on `main` and porcelain is nonempty, the dirty-primary-tree guard is what tripped: the wrong-branch guard runs first and would have failed there instead, and the diverged-`main` guards run after the dirty-tree check so they're unreachable while the tree is still dirty. When it's the dirty-tree guard:

```bash
scripts/diagnose-dirty-main.sh
```

This is read-only — it never stashes, resets, or cleans anything. It runs a separate `git status --porcelain --ignored` to break the tree into staged changes (via `git diff --cached --name-status`), unstaged changes to already-tracked files (via `git diff --name-status`), genuinely untracked paths, and already-ignored paths, then runs `git check-ignore -v` per untracked entry to tell "genuinely untracked scaffold `.gitignore` doesn't cover yet" apart from "should already be ignored but isn't on this checkout." Report this breakdown to the user and ask for direction — the pre-existing state on primary `main` is not the current issue's to resolve, so do not stash, reset, or clean it away just to get past the guard.

### Baseline-failure triage (unattended override)

`superpowers:using-git-worktrees` verifies a clean test baseline after isolation and, on failure, says to report and ask before proceeding. This workflow runs unattended, so — **for unattended `github-issue` runs only** — it overrides that gate with a narrow, evidence-based procedure. The upstream skill is unchanged; interactive users keep its report-and-ask default. No failure is ever silently ignored, suppressed, excluded, weakened, or dropped from final verification.

When the isolated worktree's baseline verification fails, classify **each** failing test independently:

1. Capture the exact baseline command, the failing test(s), exit status, and relevant (bounded) output from the issue worktree.
2. Reproduce the same command on a separate, untouched checkout pinned to the branch-base `origin/main` commit (`git merge-base origin/main HEAD`) — never a checkout carrying issue-branch changes or generated state.
3. Identify the files implicated by the failure: the failing test plus the production/configuration files named by its stack trace, assertion, coverage, or focused investigation.
4. Compare those files and the failure's behavior against the issue's planned **and** actual change surface (expected tests, production files, configuration, dependencies, shared infrastructure).
5. Run the classifier once per failure with the gathered evidence:

   ```bash
   scripts/baseline-triage.sh \
     --reproduces-on-main <yes|no> \  # step 2 reproduced it on untouched origin/main
     --overlaps-surface   <yes|no> \  # step 4 found overlap with the change surface
     --branch-worsened    <yes|no> \  # new, worse, or materially different on the branch
     --branch-resolved    <yes|no> \  # branch makes it pass/changes it with no reviewed in-scope cause
     --ambiguous          <yes|no>    # flaky/timeout/environmental/global-setup/unclassifiable
   ```

   It prints `CONTINUE` (exit 0) only when the failure provably reproduces on untouched `origin/main` and is unrelated on every axis; otherwise `STOP: <reason>` (exit 2). It is fail-closed — missing or unclear evidence stops. Continue the run **only if every** failure returns `CONTINUE`; a single `STOP` stops the run, and you report each classification and ask for direction. One safely classified failure never lets an unrelated or ambiguous one through.

6. For every accepted (`CONTINUE`) failure, add an `Accepted baseline failure` section to the draft PR recording: the command, the exact test, bounded relevant output, the `origin/main` SHA and the issue-branch SHA, the implicated files, the change-surface comparison, and the classifier verdict with rationale. Redact secrets without hiding diagnostic facts; link an artifact if the output is too large.

The classifier only reads evidence — it never runs, excludes, or alters a test. You still supply every judgment; it enforces only the go/no-go combination so an unattended run cannot rationalize past it.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review).

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

**Prefer the simplest design that satisfies the issue; avoid speculative requirements.**

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

Derive **Problem** from the issue and **Approach** from the chosen design; both must be specific, not boilerplate. **Problem** states observable application/user-facing pain — what someone hits — without naming the fix; no implementation nouns. **Approach** states the behavior-level solution in minimal implementation jargon and names deliberate non-goals (what this PR intentionally does not do). Phase 6 updates **Approach** if the implementation differs. The PR body is the asynchronous record of the design conversation. Then use `superpowers:writing-plans` to produce the plan.

Write two artifacts inside `<worktree-path>` as **session-local working files** — the plan drives Phase 4, the design records the decisions. They must **not** land in the PR diff, so Git-exclude them before writing (Phase 7 deletes them with the worktree):

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

After writing both files, record those two paths for Phase 7. Set `pr_number`
to the PR selected in Phase 2:

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

**REQUIRED SUB-SKILL:** Use `superpowers:subagent-driven-development`.

Execute the plan task by task with fresh subagents and the skill's review stages when subagent tools are available (discover deferred tools with `tool_search` if needed). If subagent tools are unavailable, say so and execute directly while preserving the same task boundaries, test-first discipline, and review checkpoints — do not silently omit review.

Follow `superpowers:test-driven-development` for every behavior change unless the user explicitly approves an exception.

**Reject task diffs that are more complex than required; send them back for simplification.**

---

## Phase 5 — Verify Against the Issue

**REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`.

Run focused tests plus the repository checks appropriate to the changed surface. Re-read the original issue and verify each acceptance criterion against current evidence:

```bash
GH issue view <number>
```

Do not claim completion from prior output, expected behavior, or a passing subset that does not cover the requested outcome.

**Re-check every accepted baseline failure.** For each `Accepted baseline failure` recorded in the PR, re-run its recorded command and re-invoke `scripts/baseline-triage.sh` — set `--branch-worsened yes` if the output, failing assertions, or exit/timing behavior changed from the recorded baseline. If any accepted failure now regresses, or the actual implementation expanded the change surface so `--overlaps-surface` is now `yes`, stop, do **not** mark the PR ready, and report. Otherwise preserve the confirmed-unchanged evidence in the PR verification summary. Never convert, suppress, or exclude a failure to finish.

**Before finalizing, ensure the full diff is the simplest solution that satisfies the issue.**

---

## Phase 6 — Finish (with stale-base guard)

**REQUIRED SUB-SKILL:** Use `superpowers:finishing-a-development-branch`.

**Before pushing, guard against a stale base** — a branch that has fallen behind `origin/main` produces a bloated, dangerous PR diff:

```bash
git fetch origin
base=$(git merge-base origin/main HEAD)
behind=$(git rev-list --count "$base"..origin/main)
[ "$behind" -gt 50 ] && echo "STALE BASE: $behind commits behind origin/main — rebase before PR"
```

If stale, `git rebase origin/main` (resolve conflicts, drop already-merged commits), then re-run Phase 5. Confirm `git diff --stat origin/main...HEAD` shows only your intended files before finalizing.

**The PR already exists (opened in Phase 2) — finalize it, don't create a new one:**

- Push the final commits to the existing branch.
- Update the existing PR body: make the Summary's **Approach** match the actual diff, then append verification results against the acceptance criteria below Design Decisions. Preserve the single `Closes #<number>` line and Summary block. Because the spec and plan are session-local, do not link their paths.
- Hand off: `scripts/finish-handoff.sh <pr-number> <number>`. (`issue-orchestrator` is a separate, external system — this repo does not create or manage the `agent-running` label itself, only reads it.) On a manual run (the linked issue has no `agent-running` label) this marks the PR ready exactly as before. On a managed run (issue-orchestrator already applied `agent-running` to the linked issue) this instead keeps the PR draft, adds `agent-running` to the PR, and replaces any other phase label with `agent-review` on both issue and PR — issue-orchestrator owns review/CI/merge from there. Safe to rerun after a partial failure; it converges to the same label state.
- Report which path it took (its stderr output says so) alongside the branch name and PR URL.

Do not merge unless the user explicitly requests it.

---

## Phase 7 — Post-Merge Cleanup

Run this phase when the user reports the PR merged or authenticated GitHub state reports `MERGED`. Never treat a merely closed PR as merged.

`scripts/cleanup-merged.sh` only ever cleans up once the PR is `MERGED`, its branch is under `agent/*`, that branch has actually landed in `origin/main` — as a true merge commit, or proven via `git patch-id` equivalence for a squash merge; rebase merges stop and ask, since the PR's merge commit is only the last replayed commit and can never patch-match the whole feature — and its worktree is clean. It deletes only the two manifest-recorded session artifacts after confirming they are ignored and untracked. Matching tracked documents are preserved; an unrecorded matching file stops cleanup with an actionable report.

```bash
scripts/cleanup-merged.sh <pr-number> <issue-number>
```

Never use forced worktree removal, reset, clean, or force-push during post-merge cleanup. `git branch -D` only via the proven-squash path in `cleanup-merged.sh` (PR `MERGED` + `agent/*` + merge commit in `origin/main` + patch-id equivalence + clean worktree); never by hand. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

---

## Red Flags — STOP

- **Branching from local `main` or a feature branch.** Always branch from freshly-fetched `origin/main`; if local `main` diverged or the primary worktree is dirty, stop without mutating it.
- **Running `git stash -f`, `git reset --hard`, or `git clean -f` on primary `main` to force past a tripped dirty-tree guard.** Run `scripts/diagnose-dirty-main.sh`, report the breakdown, and ask — pre-existing main state isn't the current issue's job to resolve.
- **Writing or committing issue artifacts in the primary worktree.** After isolation, every write and commit happens in `<worktree-path>` — never on primary `main`.
- **More than one `Closes #<number>` in the PR body.** Exactly one closing reference.
- **Generic `## Summary`.** Problem must reflect the issue; Approach must reflect the diff.
- **Leaving the PR in draft past a green Phase 6 on a manual run.** Mark it ready once verification passes; on a managed run (issue carries `agent-running`), staying draft is correct — see `scripts/finish-handoff.sh`.
- **Calling `GH pr ready` directly in Phase 6.** Always go through `scripts/finish-handoff.sh` so a managed run's PR correctly stays draft.
- **Treating a merely closed PR as merged.** Only `MERGED` triggers Phase 7 cleanup.
- **Silently accepting or suppressing a baseline failure.** In an unattended run a pre-existing baseline failure may be passed only when `scripts/baseline-triage.sh` returns `CONTINUE`, it is documented in the PR, and it is re-verified in Phase 5 — never ignored, excluded, weakened, converted to a pass, or marked ready on a regression.
