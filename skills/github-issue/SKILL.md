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

`scripts/isolate.sh` syncs the primary worktree with `origin/main`, isolates issue work into its own worktree and branch, and opens the draft PR — all before any issue commit. On any guard failure it exits nonzero without mutating the primary worktree, so issue work is never committed onto a dirty or diverged `main`: report the exact condition and ask for direction. Use a 3–5 word kebab-case slug; `<worktree-path>` is `.claude/worktrees/agent-<number>-<slug>`. From here on, run every write, commit, test, and Git command in `<worktree-path>` unless it explicitly inspects the primary worktree. Pass an optional 5th `base-ref` arg (e.g. `origin/agent/82-other-issue`) when this issue's work must stack on another in-flight branch instead of `origin/main`.

```bash
scripts/isolate.sh <number> <slug> <worktree-path> "<title referencing #<number>>"
```

Report the PR URL to the user now — it is the first thing they see, before any design question is generated. The PR stays **draft** until Phase 6 finalizes it, then it is marked ready for the repository owner on both manual and managed runs.

### Dirty-tree triage (read-only, when the guard trips)

If `scripts/isolate.sh` exits nonzero, check `git branch --show-current` and `git status --porcelain` in the primary worktree: on `main` with nonempty porcelain, the dirty-tree guard is what tripped — the wrong-branch guard runs before it, the diverged-`main` guards after. When it's the dirty-tree guard:

```bash
scripts/diagnose-dirty-main.sh
```

This is read-only — it never stashes, resets, or cleans. It breaks the tree into staged changes, unstaged changes to tracked files, genuinely untracked paths, and already-ignored paths, and reports per untracked entry whether `.gitignore` should already have covered it. Report that breakdown to the user and ask for direction — pre-existing state on primary `main` is not this issue's to resolve, so never stash, reset, or clean it away to get past the guard.

### Baseline-failure triage (unattended override)

`superpowers:using-git-worktrees` says to report and ask when the post-isolation baseline fails. **For unattended `github-issue` runs only**, this narrow evidence-based procedure overrides that gate; the upstream skill is unchanged, and interactive users keep its default. No failure is ever silently ignored, suppressed, excluded, weakened, or dropped from final verification.

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

   It prints `CONTINUE` (exit 0) only when the failure provably reproduces on untouched `origin/main` and is unrelated on every axis; otherwise `STOP: <reason>` (exit 2). It is fail-closed — missing or unclear evidence stops. Continue **only if every** failure returns `CONTINUE`; one `STOP` stops the run, and you report each classification and ask for direction.

6. For every accepted (`CONTINUE`) failure, add an `Accepted baseline failure` section to the draft PR recording: the command, the exact test, bounded relevant output, the `origin/main` SHA and the issue-branch SHA, the implicated files, the change-surface comparison, and the classifier verdict with rationale. Redact secrets without hiding diagnostic facts; link an artifact if the output is too large.

The classifier only reads evidence — it never runs, excludes, or alters a test, and you still supply every judgment. It enforces only the go/no-go combination, so an unattended run cannot rationalize past it.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review).

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

**Prefer the simplest design that satisfies the issue; avoid speculative requirements.**

Before implementation, record the expected files and approximate production-code size in the plan. Every added production behavior must map to an acceptance criterion or demonstrated regression; if the change grows beyond roughly twice the estimate, redesign around the simplest viable solution, and require explicit user approval for speculative hardening.

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

Both must be specific, not boilerplate. **Problem** states observable user-facing pain — what someone hits — without naming the fix or using implementation nouns. **Approach** states the behavior-level solution in minimal jargon and names deliberate non-goals; Phase 6 updates it if the implementation differs. The PR body is the asynchronous record of the design conversation. Then use `superpowers:writing-plans` to produce the plan.

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

Execute the plan task by task with fresh subagents and the skill's review stages when subagent tools are available (discover deferred tools with `tool_search` if needed). If they are unavailable, say so and execute directly, preserving the same task boundaries, test-first discipline, and review checkpoints — never silently omit review.

Follow `superpowers:test-driven-development` for every behavior change unless the user explicitly approves an exception.

**Reject task diffs that are more complex than required; send them back for simplification.**

## Simplicity constraints

- Implement only the behavior explicitly described in this issue.
- Do not add retries, backoff, compatibility layers, additional commands,
  speculative abstractions, or extension points unless explicitly required.
- If a dependency is not ready, stop and report the dependency; do not create
  a temporary alternative.
- Every new production module and persistent state field must map to a named
  acceptance criterion.
- If the implementation needs more than five production files or introduces
  a new state machine, pause and present the simpler alternative first.

## Behavioral verification constraints

- Verify acceptance criteria through observable behavior at the smallest
  practical boundary. Source text, generated arguments, or mock calls alone
  are not proof of runtime behavior.
- For wrappers and integrations, test at least one realistic failure beyond
  the success check and preserve the underlying exit status.
- Do not add test infrastructure solely for this verification. If the relevant
  boundary is unavailable, report the gap instead of claiming it was verified.

---

## Phase 5 — Verify Against the Issue

**REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`.

Run focused tests plus the repository checks appropriate to the changed surface. Re-read the original issue and verify each acceptance criterion against current evidence:

```bash
GH issue view <number>
```

Do not claim completion from prior output, expected behavior, or a passing subset that does not cover the requested outcome.

**Re-check every accepted baseline failure.** For each one recorded in the PR, re-run its command and re-invoke `scripts/baseline-triage.sh`, setting `--branch-worsened yes` if the output, failing assertions, or exit/timing behavior changed from the recorded baseline. If any now regresses, or the implementation expanded the change surface so `--overlaps-surface` is now `yes`, stop, do **not** mark the PR ready, and report. Otherwise preserve the confirmed-unchanged evidence in the PR verification summary. Never convert, suppress, or exclude a failure to finish.

**Before finalizing, ensure the full diff is the simplest solution that satisfies the issue.**

Report production, test, and documentation line counts separately.

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

---

## Phase 7 — Post-Merge Cleanup

Run this phase once the PR is terminal — the user reports it merged or closed, or authenticated GitHub state reports `MERGED` or `CLOSED`. A merged PR and a closed, unmerged one are both cleaned up, but they are never treated as the same outcome: only a merge resolves the issue and advances the trunk.

`scripts/cleanup-merged.sh` is the canonical Phase 7 cleanup for a manual run and for any unattended caller. Run it directly:

```bash
scripts/cleanup-merged.sh <pr-number> <issue-number>
```

The PR's state selects one of two dispositions; an `OPEN` PR is `waiting` and any other state is `blocked` / `pr-state-unknown` rather than guessed at:

| PR state | disposition | what it does |
| --- | --- | --- |
| `MERGED` | merged | removes the owned artifacts, worktree, local branch and exact remote branch; fast-forwards local `main`; closes the linked issue if GitHub did not |
| `CLOSED` | closed-unmerged | removes exactly the same owned state — and nothing else: local `main` is never moved, and the linked issue is read to verify it but never closed |

Both run the same guards: the branch must be under `agent/*` and unprotected, and its worktree clean. A merged PR must additionally be proven to have landed in `origin/main` — as a true merge commit, or via `git patch-id` equivalence for a squash merge; rebase merges stop and ask, since the PR's merge commit is only the last replayed commit and can never patch-match the whole feature. A closed, unmerged PR requires no such proof and asserts none (`merge_mode` is `null`, and the `cleaned` reason is `closed-unmerged-cleanup-complete`): the change is being discarded on purpose, which is exactly why nothing about it may reach `main` or the issue.

Either way it deletes only the two manifest-recorded session artifacts after confirming they are ignored and untracked; matching tracked documents are preserved, and an unrecorded matching file stops cleanup with an actionable report.

Every knowable guard is evaluated before the first mutation, and each step is journaled at `$(git rev-parse --git-common-dir)/github-issue/cleanup/pr-<pr-number>.state` — the intent (`attempted=`) before the mutation, the completion (`done=`) after it — so a crash in between still converges on the next run. A missing worktree, local branch, or recorded artifact is accepted **only** when that journal proves this workflow removed it; otherwise cleanup stops and asks. The journal also records the `disposition=`, so a run resumed against a PR whose outcome has since changed is `blocked` / `journal-mismatch` instead of finishing under the wrong rules.

The merge proof covers one commit, so nothing is deleted without re-verifying the tip: the local branch must still equal the proven SHA (else `branch-advanced`), origin's branch must too (else `remote-branch-advanced`), and since the earlier read goes stale during removal, the deletion itself carries that expected tip as a lease, so origin rejects it if the ref moved (also `remote-branch-advanced`). Work pushed or committed after the proof is preserved, never deleted.

Every run writes exactly one JSON record to stdout and keeps human diagnostics on stderr, so an unattended caller never parses free-form text:

```json
{"status":"cleaned","pr":"40","issue":"28","branch":"agent/28-restart-safe-cleanup","merge_mode":"regular","reason":"cleanup-complete"}
```

| `status` | exit | meaning |
| --- | --- | --- |
| `cleaned` | 0 | this run performed at least one cleanup step |
| `already-clean` | 0 | nothing was pending; this run mutated nothing |
| `waiting` | 10 | a normal precondition has not happened yet (PR still open) — no alert |
| `blocked` | 20 | dirty, diverged, ambiguous, or unprovable state needing a human |
| `retry` | 30 | authentication, GitHub, fetch, or another operational failure that may recover |

`merge_mode` is `regular`, `squash`, or `null` — not yet proven, or a closed, unmerged PR that has no merge to prove; `reason` is a stable token (e.g. `pr-open`, `pr-state-unknown`, `merge-unprovable`, `worktree-dirty`, `closed-unmerged-cleanup-complete`), never prose. Read the stderr diagnostic for the details behind a `blocked` or `retry`.

Never use forced worktree removal, reset, clean, or a force-push of content. The only permitted force flag is `--force-with-lease=refs/heads/<branch>:<proven-sha>` on the remote branch deletion, where it constrains the delete to the proven tip instead of loosening it — never a bare `--force`, never `--force-with-lease` without an expected SHA, never on anything but that deletion. `git branch -D` only via the two gated paths in `cleanup-merged.sh` — a proven squash (PR `MERGED` + `agent/*` + merge commit in `origin/main` + patch-id equivalence + clean worktree), or a discarded branch (PR `CLOSED` + `agent/*` + clean worktree + a remote tip still equal to the local tip) — never by hand. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

---

## Red Flags — STOP

- **Branching from local `main` or a feature branch.** Always branch from freshly-fetched `origin/main`; if local `main` diverged or the primary worktree is dirty, stop without mutating it.
- **`git stash -f`, `git reset --hard`, or `git clean -f` on primary `main` to force past the dirty-tree guard.** Run `scripts/diagnose-dirty-main.sh`, report the breakdown, and ask — pre-existing main state isn't this issue's job to resolve.
- **Writing or committing issue artifacts in the primary worktree.** After isolation, every write and commit happens in `<worktree-path>`.
- **More than one `Closes #<number>` in the PR body.** Exactly one closing reference.
- **Generic `## Summary`.** Problem must reflect the issue; Approach must reflect the diff.
- **Leaving the PR in draft past a green Phase 6, or calling `GH pr ready` directly.** Always hand off through `scripts/finish-handoff.sh`, so the handoff stays one explicit, testable step.
- **Treating a closed PR as merged.** Both terminal states trigger Phase 7 cleanup, but only `MERGED` may fast-forward local `main` or close the linked issue — a closed, unmerged PR removes its own branch, worktree and artifacts and nothing else.
- **Silently accepting or suppressing a baseline failure.** Unattended, one may be passed only when `scripts/baseline-triage.sh` returns `CONTINUE`, it is documented in the PR, and it is re-verified in Phase 5 — never ignored, excluded, weakened, converted to a pass, or marked ready on a regression.
