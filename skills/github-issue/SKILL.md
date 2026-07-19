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

`scripts/isolate.sh` syncs the primary worktree with `origin/main`, isolates issue work into its own worktree and branch, and opens the draft PR — all before any issue commit happens. It guarantees issue work is never committed onto a dirty or diverged `main`: on any guard failure it exits nonzero without mutating the primary worktree, preserving user work so you can report the exact condition and ask for direction. Use a 3–5 word kebab-case slug. From here on, run all writes, commits, tests, and Git commands in `<worktree-path>` unless a command explicitly inspects the primary worktree.

```bash
scripts/isolate.sh <number> <slug> <worktree-path> "<title referencing #<number>>"
```

Report the PR URL to the user now — it is the first thing they see, before any design question is generated. The PR stays **draft** until Phase 6 marks it ready.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review).

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

Once the design doc and plan are written, replace the "In progress" placeholder in the PR body with the full log:

```bash
GH pr edit <pr-number> --body "$(cat <<'EOF'
Closes #<number>

## Design Decisions
- **Q:** <question> — **A:** <answer chosen> — **Why:** <reasoning>
- ...
EOF
)"
```

This is the user's asynchronous review surface for the design conversation — the full design rationale lives here, in the PR body, not in the repo. After the design is settled, use `superpowers:writing-plans` to produce the plan.

Write two artifacts inside `<worktree-path>` as **session-local working files** — the plan drives Phase 4, the design records the decisions. They must **not** land in the PR diff, so Git-exclude them before writing (Phase 7 deletes them with the worktree):

```bash
excl="$(git rev-parse --git-path info/exclude)"
grep -qxF 'docs/superpowers/' "$excl" || echo 'docs/superpowers/' >> "$excl"
```

- Design: `docs/superpowers/specs/<YYYY-MM-DD>-<slug>-design.md`
- Plan: `docs/superpowers/plans/<YYYY-MM-DD>-<slug>.md`

The plan must record the issue number and URL, the original acceptance criteria, and the PR closing reference `Closes #<number>`. Confirm `git status --porcelain` shows neither artifact before continuing.

---

## Phase 4 — Implement

**REQUIRED SUB-SKILL:** Use `superpowers:subagent-driven-development`.

Execute the plan task by task with fresh subagents and the skill's review stages when subagent tools are available (discover deferred tools with `tool_search` if needed). If subagent tools are unavailable, say so and execute directly while preserving the same task boundaries, test-first discipline, and review checkpoints — do not silently omit review.

Follow `superpowers:test-driven-development` for every behavior change unless the user explicitly approves an exception.

---

## Phase 5 — Verify Against the Issue

**REQUIRED SUB-SKILL:** Use `superpowers:verification-before-completion`.

Run focused tests plus the repository checks appropriate to the changed surface. Re-read the original issue and verify each acceptance criterion against current evidence:

```bash
GH issue view <number>
```

Do not claim completion from prior output, expected behavior, or a passing subset that does not cover the requested outcome.

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
- Update the PR body: append a verification summary below the Design Decisions log — what was checked, against which acceptance criteria. The spec and plan are session-local and never committed, so the PR body (Design Decisions + verification summary) is the whole record — do not link `docs/superpowers/…` paths that aren't in the diff. Keep the single `Closes #<number>` line intact; don't duplicate it.
- Mark it ready: `GH pr ready <pr-number>`.
- Report the branch name and PR URL.

Do not merge unless the user explicitly requests it.

---

## Phase 7 — Post-Merge Cleanup

Run this phase when the user reports the PR merged or authenticated GitHub state reports `MERGED`. Never treat a merely closed PR as merged.

`scripts/cleanup-merged.sh` only ever cleans up once the PR is `MERGED`, its branch is under `agent/*`, that branch has actually landed in `origin/main`, and its worktree (including untracked files) is clean; on any guard failure it stops and reports without touching anything.

```bash
scripts/cleanup-merged.sh <pr-number> <issue-number>
```

Never use forced worktree removal, `git branch -D`, reset, clean, or force-push during post-merge cleanup. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

---

## Red Flags — STOP

- **Branching from local `main` or a feature branch.** Always branch from freshly-fetched `origin/main`; if local `main` diverged or the primary worktree is dirty, stop without mutating it.
- **Writing or committing issue artifacts in the primary worktree.** After isolation, every write and commit happens in `<worktree-path>` — never on primary `main`.
- **More than one `Closes #<number>` in the PR body.** Exactly one closing reference.
- **Leaving the PR in draft past a green Phase 6.** Mark it ready once verification passes.
- **Treating a merely closed PR as merged.** Only `MERGED` triggers Phase 7 cleanup.
