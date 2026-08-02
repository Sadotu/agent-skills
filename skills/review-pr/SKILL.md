---
name: review-pr
description: Use for a single, read-only application-coherence and drift review pass against a linked issue and PR — scope drift, PR-description/implementation drift, overengineering, convention drift, integration gaps, orphaned compatibility code or TODOs. Never modifies code, approves, merges, or changes draft/label state; posts one idempotent, staleness-checked PR comment per pass, with cross-linking when evidence implicates another PR.
---

# Review PR — Read-Only Application Drift Review

One full, read-only review pass against a linked issue and PR, checked
against a stable snapshot. This skill never edits code, approves, merges,
or changes draft/label state — it only ever posts plain PR comments. It is
independent of `issue-orchestrator`'s scheduling and repair behavior: it
takes an issue number and PR number and performs exactly one pass.

**Preconditions:**

- **Run all phases in one shell session** so `$REPO`, `$WORKSPACE`, and the `GH` helper below persist.
- **Authentication adapts to the environment**, same as `github-issue`: inside the agent devcontainer, `gh` uses the GitHub App; elsewhere, your own `gh auth login`.

Setup — identical to `github-issue`'s:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
WORKSPACE="$(git rev-parse --show-toplevel)"
if [ -x /opt/agent-devcontainer/gh-app-token.sh ]; then
  GH() { GH_TOKEN="$(GITHUB_APP_REPO=$REPO /opt/agent-devcontainer/gh-app-token.sh)" gh "$@" --repo "$REPO"; }
else
  GH() { gh "$@" --repo "$REPO"; }
fi
```

---

## Phase 1 — Resolve inputs

Requires an issue number and a PR number (from arguments, or ask if not
given). Confirm the PR actually closes/references the issue — read the PR
body (`GH pr view <pr> --json body`) and check for a `Closes #<issue>` (or
equivalent) reference. If the PR doesn't reference the issue, stop and ask;
this skill reviews one linked issue+PR pair, not an arbitrary PR.

## Phase 2 — Capture the snapshot

```bash
scripts/snapshot.sh <pr-number> <issue-number>
```

Prints `{"issue":N,"pr":N,"head":"sha","base":"sha","issueUpdatedAt":"...","prUpdatedAt":"...","fingerprint":"hex"}`.
Record the `fingerprint` — it is this pass's snapshot identity. Everything
from here on is judged against exactly this head/base/issue-body/PR-body;
`scripts/publish-review.sh` re-checks it before posting, so a mid-review
edit to any of those four things safely aborts the pass rather than posting
stale findings.

## Phase 3 — Read-only inspection

Get a disposable, detached look at the application at the PR's head commit
— never the primary worktree, never a branch checkout (so nothing can
accidentally be committed to it):

```bash
git fetch origin
tmp_review_dir="$(mktemp -d)"
git worktree add --detach "$tmp_review_dir" <head-sha>
```

Read, in this order: the issue body (the spec/acceptance criteria), the PR
body (Summary, Approach, Design Decisions Q&A), the diff (`GH pr diff
<pr-number>` or `git -C "$tmp_review_dir" diff <base-sha> <head-sha>`), and
the surrounding application code in `$tmp_review_dir` at head — conventions,
call sites, related modules — enough to judge coherence, not just the diff
in isolation.

When done, always clean up regardless of outcome:

```bash
git worktree remove "$tmp_review_dir"
```

## Phase 4 — Analyze for drift

Review for exactly these categories (per the issue's scope) — and nothing
else unless it affects one of these relationships:

- **Scope drift** — does the PR's actual change surface match what the issue asked for?
- **Description drift** — does the diff match the PR's own Summary/Approach, the Design Decisions Q&A, and any claimed behavior?
- **Overengineering** — is there a materially simpler implementation that satisfies the issue equally well?
- **Architectural/convention drift** — does the change follow this codebase's existing patterns, or invent a new one without reason?
- **Integration gaps** — visible from the current application state at head: dangling references, unused exports, call sites the diff should have updated but didn't.
- **Orphaned temporary code** — compatibility shims, feature flags, TODOs, or duplicate code paths introduced without a visible removal plan.
- **Unjustified complexity** — complexity whose delivered value doesn't justify it.

Do **not** repeat ordinary correctness, style, security, or test feedback
unless it bears on one of the categories above.

For each finding, capture: concrete evidence (file:line, quoted diff/code),
impact, and a recommended action. Classify each as **blocking** or
**non-blocking**. Overall verdict is `BLOCKING` if any finding is blocking,
otherwise `PASS`.

If concrete evidence (not speculation) implicates another open PR — e.g. it
names another PR, or duplicates/overlaps a change also present in another
open PR you can see — note it for cross-linking in Phase 7.

## Phase 5 — Compose the comment

Write the review to a file. Include: reviewed head/base SHAs, issue and PR
update timestamps (from the Phase 2 snapshot), the pass number (filled in
automatically by the publish script — reference it as "pass N" once you
have the script's output), every blocking and non-blocking finding with its
evidence/impact/recommended action, the clean areas (what's fine, so a
human doesn't have to re-check them), and the overall verdict.

## Phase 6 — Publish

```bash
scripts/publish-review.sh <pr-number> <issue-number> <fingerprint-from-phase-2> <PASS|BLOCKING> <body-file>
```

- **Exit 0** — posted. The marker JSON (including the real pass number and
  the posted comment's URL) is printed to stdout; report the PR comment
  URL/pass number to the user.
- **Exit 3 (stale)** — the issue or PR changed since Phase 2's snapshot was
  captured. Do not retry with the same body — restart from Phase 2 with a
  fresh snapshot; if the change is substantive, the analysis in Phase 4 may
  need to change too.
- **Exit 4 (duplicate)** — this exact snapshot was already reviewed; no new
  comment is needed. Report convergence, not an error.
- **Any other nonzero exit** — a genuine script error (e.g. bad arguments).
  Stop and report the error rather than retrying blindly.

Note: on a very long-lived PR, `gh pr view --json comments` may not return
the full comment history (GitHub API pagination), so pass numbering and
duplicate detection are best-effort in that case — this is a documented
limitation, not something this skill codes around.

## Phase 7 — Cross-link affected PRs

For each finding from Phase 4 that names or is concretely evidenced against
another open PR, write that finding to its own file and run, once per
affected PR:

```bash
scripts/publish-crosslink.sh <target-pr-number> <pr-number> <issue-number> <finding-body-file>
```

- **Exit 0** — posted to the target PR.
- **Exit 4 (duplicate)** — already cross-linked; no-op, not an error.
- **Any other nonzero exit** — a genuine script error (e.g. bad arguments).
  Stop and report the error rather than retrying blindly.

---

## Red Flags — STOP

- **Editing code, approving, merging, or changing draft/label state.** This skill only ever reads and posts comments.
- **Posting without Phase 2's fresh-fingerprint check.** Always pass the Phase 2 fingerprint to `publish-review.sh` and let it re-verify — never hand-construct or skip the staleness check.
- **Hand-rolling the marker text.** Always go through `publish-review.sh`/`publish-crosslink.sh` so the idempotency contract holds; a hand-written marker can't be trusted by reruns or by the external supervisor parsing it.
- **Leaving the detached review worktree behind.** Always `git worktree remove` it at the end of Phase 3, success or failure.
- **Repeating ordinary correctness/style/security/test feedback** that doesn't bear on scope, description, architectural, or complexity drift — that's other reviewers' job, not this skill's.
- **Speculative cross-linking.** Only cross-link with concrete evidence, never a guess that another PR "might" be relevant.
