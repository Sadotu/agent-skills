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

**CRITICAL — synchronize before writing or committing issue artifacts.** `git fetch` updates `origin/main`, not local `main`. Committing design/plan in the primary worktree before isolation pollutes local `main` and makes it diverge.

Start from a clean primary worktree on `main`, fetch, fast-forward only when safe, then branch from `origin/main`:

```bash
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain)"
git fetch origin
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
git worktree add -b agent/<number>-<slug> <worktree-path> origin/main
```

If the branch, cleanliness, or ancestry guard fails, stop — preserve user work (do not reset, merge divergent histories, or commit issue artifacts in the primary worktree), report the exact condition, and request direction. Use a 3–5 word kebab-case slug. From here on, run all writes, commits, tests, and Git commands in `<worktree-path>` unless a command explicitly inspects the primary worktree.

**Open the PR now, as a draft.** A PR needs a branch with at least one commit ahead of `origin/main`, so seed one, push, and open immediately:

```bash
cd <worktree-path>
git commit --allow-empty -m "Start work on #<number>"
git push -u origin agent/<number>-<slug>
GH pr create --draft \
  --title "<title referencing #<number>>" \
  --body "$(cat <<'EOF'
Closes #<number>

## Design Decisions
_In progress — filled in once design work completes._
EOF
)"
```

Report the PR URL to the user now — it is the first thing they see, before any design question is generated. The PR stays **draft** until Phase 6 marks it ready.

---

## Phase 3 — Design and Plan (inside issue worktree)

**REQUIRED SUB-SKILL:** Use `superpowers:brainstorming`, seeded with the issue description and your codebase findings, for its structure only (explore context → clarifying questions → propose approaches → present design → write spec → self-review).

**Override for this workflow — do not pause at any of brainstorming's gates.** That skill normally stops and waits for the user at each step: clarifying questions, the approach choice, per-section design approval, the spec review gate. Here none of that waits. For every question you would have asked, generate it as usual, answer it yourself (pick the recommended or best option), and continue immediately. Record each one as you go: the question, the options considered, the answer chosen, and why.

Once the design doc and plan are written and committed, replace the "In progress" placeholder in the PR body with the full log:

```bash
GH pr edit <pr-number> --body "$(cat <<'EOF'
Closes #<number>

## Design Decisions
- **Q:** <question> — **A:** <answer chosen> — **Why:** <reasoning>
- ...
EOF
)"
```

This is the user's asynchronous review surface for the design conversation. After the design is settled, use `superpowers:writing-plans` to produce the plan.

Commit two artifacts inside `<worktree-path>` so they land in the PR diff — records for the PR, not something the user must re-read before implementation continues:

- Design: `docs/superpowers/specs/<YYYY-MM-DD>-<slug>-design.md`
- Plan: `docs/superpowers/plans/<YYYY-MM-DD>-<slug>.md`

The plan must record the issue number and URL, the original acceptance criteria, and the PR closing reference `Closes #<number>`.

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
- Update the PR body: append a verification summary below the Design Decisions log — what was checked, against which acceptance criteria — plus links to the committed spec and plan paths (`docs/superpowers/specs/…`, `docs/superpowers/plans/…`). Keep the single `Closes #<number>` line intact; don't duplicate it.
- Mark it ready: `GH pr ready <pr-number>`.
- Report the branch name and PR URL.

Do not merge unless the user explicitly requests it.

---

## Phase 7 — Post-Merge Cleanup

Run this phase when the user reports the PR merged or authenticated GitHub state reports `MERGED`. Never treat a merely closed PR as merged.

Resolve the merged branch from the PR, then enforce the `agent/*` boundary:

```bash
PR_JSON="$(GH pr view <pr-number> --json state,headRefName)"
test "$(printf '%s' "$PR_JSON" | jq -r .state)" = MERGED
BRANCH="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
case "$BRANCH" in agent/*) ;; *) echo "Refusing to delete non-agent branch: $BRANCH"; exit 1 ;; esac
```

Fetch and prove the branch tip landed in `origin/main`. Find its registered worktree and require it to be clean, including untracked files:

```bash
git -C "$WORKSPACE" fetch origin
git -C "$WORKSPACE" merge-base --is-ancestor "$BRANCH" origin/main
ISSUE_WORKTREE="$(git -C "$WORKSPACE" worktree list --porcelain | awk -v ref="refs/heads/$BRANCH" '
  /^worktree / { wt=substr($0, 10) }
  $0 == "branch " ref { print wt }
')"
test -n "$ISSUE_WORKTREE"
test -z "$(git -C "$ISSUE_WORKTREE" status --porcelain)"
```

Stop and report the failed guard without cleanup if any command above fails. Once all guards pass, remove the worktree, prune its metadata, delete the local branch safely, and delete the matching remote branch when it still exists:

```bash
cd "$WORKSPACE"
git worktree remove "$ISSUE_WORKTREE"
git worktree prune
git branch -d "$BRANCH"
if git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  git push origin --delete "$BRANCH"
fi
```

Fast-forward local `main` without resetting or cleaning user files:

```bash
test "$(git branch --show-current)" = main
git merge-base --is-ancestor main origin/main
git merge --ff-only origin/main
test "$(git rev-parse main)" = "$(git rev-parse origin/main)"
```

Finally, confirm the issue closed; close it manually if GitHub did not process the closing reference:

```bash
ISSUE_STATE="$(GH issue view <number> --json state -q .state)"
if [ "$ISSUE_STATE" != CLOSED ]; then
  GH issue close <number>
fi
```

Never use forced worktree removal, `git branch -D`, reset, clean, or force-push during post-merge cleanup. Never delete `main`, `master`, `develop`, `release/*`, or `hotfix/*` locally or remotely.

---

## Red Flags — STOP

- **Branching from local `main` or a feature branch.** Always branch from freshly-fetched `origin/main`; if local `main` diverged or the primary worktree is dirty, stop without mutating it.
- **Writing or committing issue artifacts in the primary worktree.** After isolation, every write and commit happens in `<worktree-path>` — never on primary `main`.
- **More than one `Closes #<number>` in the PR body.** Exactly one closing reference.
- **Leaving the PR in draft past a green Phase 6.** Mark it ready once verification passes.
- **Treating a merely closed PR as merged.** Only `MERGED` triggers Phase 7 cleanup.
