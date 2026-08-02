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

This phase produces two **session-local working files** inside `<worktree-path>` — the design records the decisions and the plan drives Phase 4. They must **not** land in the PR diff, so Git-exclude them before writing (Phase 7 removes them through its recoverable cleanup):

```bash
excl="$(git rev-parse --git-path info/exclude)"
grep -qxF 'docs/superpowers/' "$excl" || echo 'docs/superpowers/' >> "$excl"
```

Set `issue_number`, `slug`, and `pr_number` from the values already resolved by this workflow. Validate them, derive the UTC date, and define the exact repository-relative artifact paths once; use these variables when writing the files:

```bash
case "${issue_number:-}" in ''|*[!0-9]*) echo "invalid issue number" >&2; exit 1 ;; esac
case "${pr_number:-}" in ''|*[!0-9]*) echo "invalid PR number" >&2; exit 1 ;; esac
if ! [[ "${slug:-}" =~ ^[a-z0-9]+(-[a-z0-9]+){2,4}$ ]]; then
  echo "invalid slug: expected 3-5 lowercase kebab-case words" >&2
  exit 1
fi
artifact_date="$(date -u +%F)"
design_path="docs/superpowers/specs/${artifact_date}-${slug}-design.md"
plan_path="docs/superpowers/plans/${artifact_date}-${slug}.md"
```

- Design: `$design_path`
- Plan: `$plan_path`

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review). Write and self-review the completed design specifically at `$design_path`.

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

**Prefer the simplest design that satisfies the issue; avoid speculative requirements.**

Then use `superpowers:writing-plans` and write the plan specifically at `$plan_path`. The plan must record the issue number and URL, the original acceptance criteria, and the PR closing reference `Closes #<number>`.

Confirm both artifacts are ignored and absent from `git status --porcelain` before publishing their provenance:

```bash
for artifact_path in "$design_path" "$plan_path"; do
  git check-ignore -q -- "$artifact_path" || exit 1
done
test -z "$(git status --porcelain -- "$design_path" "$plan_path")" || exit 1
```

Record those two exact paths as NUL-delimited session provenance in shared Git metadata. Resolve a relative `--git-common-dir` against `$WORKSPACE`, then publish the manifest atomically without replacing existing provenance:

```bash
git_common_dir="$(git -C "$WORKSPACE" rev-parse --git-common-dir)"
case "$git_common_dir" in
  /*) ;;
  *) git_common_dir="$WORKSPACE/$git_common_dir" ;;
esac
git_common_dir="$(cd "$git_common_dir" && pwd -P)"
artifact_dir="$git_common_dir/github-issue/artifacts"
artifact_manifest="$artifact_dir/pr-${pr_number}.paths"
mkdir -p -- "$artifact_dir" || exit 1
if ! (
  artifact_tmp="$(mktemp "$artifact_dir/.pr-${pr_number}.paths.XXXXXX")" || exit 1
  cleanup_artifact_tmp() { [ -z "$artifact_tmp" ] || rm -f -- "$artifact_tmp"; }
  trap cleanup_artifact_tmp EXIT
  printf '%s\0' "$design_path" "$plan_path" > "$artifact_tmp" || exit 1

  if [ -e "$artifact_manifest" ] || [ -L "$artifact_manifest" ]; then
    if [ ! -f "$artifact_manifest" ] || [ -L "$artifact_manifest" ] \
      || ! cmp -s -- "$artifact_tmp" "$artifact_manifest"; then
      echo "refusing to replace different or unsafe artifact provenance: $artifact_manifest" >&2
      exit 1
    fi
  elif ! ln -- "$artifact_tmp" "$artifact_manifest"; then
    if [ ! -f "$artifact_manifest" ] || [ -L "$artifact_manifest" ] \
      || ! cmp -s -- "$artifact_tmp" "$artifact_manifest"; then
      echo "artifact provenance changed during publication: $artifact_manifest" >&2
      exit 1
    fi
  fi

  rm -- "$artifact_tmp" || exit 1
  artifact_tmp=''
  trap - EXIT
); then
  echo "failed to publish artifact provenance: $artifact_manifest" >&2
  exit 1
fi
```

Identical reruns are safe; different or unsafe existing provenance stops the workflow. The manifest contains exactly this correlated pair: one design and one plan with the same generated date and slug. This PR-specific manifest is the stronger session provenance Phase 7 requires. An artifact being ignored, untracked, or pathname-matched does not by itself prove that this session owns it.

Only after the completed design and plan have been recorded in the manifest, replace the PR body placeholders. `## Summary` should tell reviewers what the PR solves and how, before the design log and diff:

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

Derive **Problem** from the issue and **Approach** from the completed design; both must be specific, not boilerplate. **Problem** states observable application/user-facing pain — what someone hits — without naming the fix; no implementation nouns. **Approach** states the behavior-level solution in minimal implementation jargon and names deliberate non-goals (what this PR intentionally does not do). Phase 6 updates **Approach** if the implementation differs. The PR body is the asynchronous record of the design conversation.

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

`scripts/cleanup-merged.sh` runs all existing merged-PR, `agent/*` branch, landed-work, and clean-worktree guards before artifact handling. Landed work must be either a true merge or proven via `git patch-id` equivalence for a squash merge; rebase merges stop and ask because the PR's merge commit is only the last replayed commit and cannot patch-match the whole feature.

With a manifest, cleanup requires exactly the correlated Phase 3 pair: one design and one plan with the same date and slug. Both must still be ignored, untracked regular files at their exact recorded paths. Any other ignored or untracked file anywhere in the worktree is ambiguous and stops cleanup; ignored status or a familiar pathname is never ownership proof. A missing manifest is allowed only when the worktree has no ignored or untracked files anywhere. Tracked historical documents remain preserved during validated cleanup.

Valid artifacts are moved into a pinned, PR-specific quarantine under shared Git metadata before normal nonforced worktree removal. Cleanup refuses symlinked quarantine metadata components and anchors the real quarantine directories and file identities while operating. After quarantining, it rechecks ignored and untracked files immediately before worktree removal; late ambiguity or discovery failure rolls the artifacts back and preserves the worktree. If worktree removal fails, it likewise restores quarantined artifacts byte-for-byte when the original locations remain safe; ambiguous restoration retains the data and reports its actionable recovery path.

If branch deletion, main synchronization, or GitHub cleanup fails after worktree removal, the manifest and quarantine remain available for recovery. Final success first preflights the complete quarantine contents and every recorded file identity before deleting any quarantine entry; a mismatch retains the manifest and quarantine for recovery. Only full success disposes the exact quarantined files and directory and removes the manifest. These safety guarantees assume no external process mutates the worktree or quarantine after the final preflights: a shell workflow cannot make such concurrent mutation transactional, while discrepancies it detects still fail closed.

```bash
scripts/cleanup-merged.sh <pr-number> <issue-number>
```

After artifact validation, cleanup uses normal nonforced worktree removal. Never use forced worktree removal, reset, clean, or force-push during post-merge cleanup. `git branch -D` only via the proven-squash path in `cleanup-merged.sh` (PR `MERGED` + `agent/*` + merge commit in `origin/main` + patch-id equivalence + clean worktree); never by hand. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

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
