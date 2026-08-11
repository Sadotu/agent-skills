---
name: review-pr
description: Use for a single, read-only application-coherence and drift review pass against a linked issue and PR — scope drift, PR-description/implementation drift, overengineering, convention drift, integration gaps, orphaned compatibility code or TODOs. Never modifies code, approves, merges, or changes draft/label state; posts one idempotent, staleness-checked PR comment per pass, with cross-linking when evidence implicates another PR. Also supports a narrower `--mode integration --previous-fingerprint <fingerprint>` pass that revalidates an already-PASSed PR against a moved base, gated on the exact prior trusted PASS marker.
---

# Review PR — Read-Only Application Drift Review

One read-only review pass against a linked issue + PR, checked against a
stable snapshot. Never edits code, approves, merges, or changes draft/label
state — only posts plain PR comments. Independent of `issue-orchestrator`'s
scheduling/repair: takes an issue number and PR number, performs exactly
one pass.

**Preconditions:**

- **Run all phases in one shell session** so `$REPO`, `$WORKSPACE`, and the `GH` helper below persist.
- **GitHub App authentication is mandatory**, same as `github-issue`. Never use the GitHub connector, a user PAT, `gh auth login`, or `gh auth setup-git`. If App authentication is unavailable, stop and run `/setup`.

Setup — source the fail-closed App helper used by the scripts:

```bash
WORKSPACE="$(git rev-parse --show-toplevel)"
source "$WORKSPACE/skills/review-pr/scripts/lib/gh.sh"
```

Use `GIT_AUTH` for every network Git command. It forces the canonical
`https://github.com/$REPO.git` route, mints a fresh App token, clears ambient
credentials for that command, and supplies only the scoped `x-access-token`
credential; never run network `git` directly.

---

## Phase 1 — Resolve inputs

Needs an issue number and PR number (args, or ask). Confirm the PR
references the issue: `GH pr view <pr> --json body`, check for `Closes
#<issue>` (or equivalent). If it doesn't, stop and ask — this reviews one
linked pair, not an arbitrary PR.

## Phase 1b — Integration mode (optional)

Full review is the default. When `main` has moved under a PR that already
earned a trusted `PASS`, run the narrower integration pass instead:

```text
/review-pr <issue-number> <pr-number> --mode integration --previous-fingerprint <fingerprint>
```

Resolve the prior `PASS` **before** any analysis — it is the gate, not a
formality:

```bash
scripts/resolve-previous-review.sh <pr-number> <issue-number> <previous-fingerprint>
```

- **Exit 0** — prints the prior marker payload. Record its `head` and
  `base`: they are the previous snapshot this pass compares against.
- **Exit 5** — the prior `PASS` is missing, malformed, authored by another
  identity, for another issue/PR pair, `BLOCKING`, ambiguous, or carries a
  `head`/`base` that isn't a full commit ID. Stop without publishing and
  tell the user to run a full review.
- **Any other nonzero exit** — genuine script error. Stop and report.

Then continue with Phase 2 unchanged. Phases 3–7 are the same pass, with
the scope narrowed in Phase 4.

## Phase 2 — Capture the snapshot

```bash
scripts/snapshot.sh <pr-number> <issue-number>
```

Prints `{"issue":N,"pr":N,"head":"sha","base":"sha","issueUpdatedAt":"...","prUpdatedAt":"...","fingerprint":"hex"}`.
Record `fingerprint` — this pass's snapshot identity. Everything below is
judged against exactly this head/base/issue-body/PR-body; `publish-review.sh`
re-checks it before posting, so a mid-review edit to any of those four
safely aborts instead of posting stale findings.

## Phase 3 — Read-only inspection

Disposable, detached look at the app at the PR's head commit — never the
primary worktree, never a branch checkout, so nothing can accidentally get
committed:

```bash
GIT_AUTH fetch origin '+refs/heads/*:refs/remotes/origin/*'
tmp_review_dir="$(mktemp -d)"
git worktree add --detach "$tmp_review_dir" <head-sha>
```

Read, in order: issue body (spec/acceptance criteria), PR body (Summary,
Approach, Design Decisions Q&A), the diff (`GH pr diff <pr-number>` or `git
-C "$tmp_review_dir" diff <base-sha> <head-sha>`), and surrounding app code
in `$tmp_review_dir` at head — conventions, call sites, related modules.
Enough to judge coherence, not just the diff alone.

Always clean up, success or failure:

```bash
git worktree remove "$tmp_review_dir"
```

## Phase 4 — Analyze for drift

Review for exactly these categories — nothing else unless it bears on one
of them:

- **Scope drift** — does the PR's actual change surface match what the issue asked for?
- **Description drift** — does the diff match the PR's own Summary/Approach, the Design Decisions Q&A, and any claimed behavior?
- **Overengineering** — is there a materially simpler implementation that satisfies the issue equally well?
- **Architectural/convention drift** — does the change follow this codebase's existing patterns, or invent a new one without reason?
- **Integration gaps** — visible from the current application state at head: dangling references, unused exports, call sites the diff should have updated but didn't.
- **Orphaned temporary code** — compatibility shims, feature flags, TODOs, or duplicate code paths introduced without a visible removal plan.
- **Unjustified complexity** — complexity whose delivered value doesn't justify it.

Do not repeat ordinary correctness, style, security, or test feedback
unless it bears on one of the categories above.

**In integration mode, narrow the scope.** Review only the interaction
between the newly-integrated base and this PR:

- what the base gained since the prior marker's `base` (`git -C
  "$tmp_review_dir" log --oneline <previous-base>..<current-base>` and its
  diff);
- how those changes meet the PR's own changes — semantic conflicts,
  duplicated paths, invalidated assumptions, convention drift, new
  integration gaps;
- the merge/update result at the current head;
- whether the PR's stated Problem/Approach and claimed behavior are still
  true on the new base.

Do not re-raise findings about unchanged PR code unless the new base makes
them relevant — re-litigating settled feedback is the cost this mode
exists to avoid.

Each finding: concrete evidence (file:line, quoted diff/code), impact,
recommended action, classified **blocking** or **non-blocking**. Verdict is
`BLOCKING` if any finding is blocking, else `PASS`.

Concrete evidence implicating another open PR (named, or an
overlapping/duplicate change you can see) — note for cross-linking in
Phase 7.

### State, timing, and race findings

For findings involving state machines, reservations/leases, asynchronous or
external completion, restart/retry, races, or drift discriminators ("reject
when X moved"), complete this pre-publication checklist:

1. Replay the expected success transition through the proposed action; the
   happy path must still complete.
2. Replay every named race and restart transition.
3. Check whether the discriminator also changes through platform/application action,
   for example Update Branch, a bot commit, or a scheduled job.
4. Check whether the invariant needs state or provenance the application does not record.
5. Confirm the proposed action preserves every acceptance path the issue requires.
6. Split independently repairable behavior from parts that require a design decision.

Do not publish the finding until every replay above is complete. State the
required **invariant**, not an insufficient shortcut such as "head changed,
therefore content drifted."

## Phase 5 — Compose the comment

Write the review to a file: reviewed head/base SHAs, issue/PR update
timestamps (from Phase 2), pass number (filled in by the publish script —
reference "pass N" once you have its output), every finding with
evidence/impact/action, clean areas (what's fine, so a human doesn't
re-check it), overall verdict.

### Labelling findings

Label every finding exactly one of:

- **blocking (repairable)** — evidence, impact, and a recommended action a
  repairer can apply mechanically.
- **blocking (decision required)** — evidence, impact, required invariant, why
  current state cannot establish it, which issue acceptance path the shortcut
  breaks, and the explicit decision the user must make. **No recommended action:**
  `address-review` would apply it literally.
- **non-blocking** — observations, unchanged.

The overall verdict is still `BLOCKING` if any finding blocks, whether
repairable or decision-required, else `PASS`.

For a split finding, identify the original finding on each separately labelled
part.

## Phase 6 — Publish

```bash
scripts/publish-review.sh <pr-number> <issue-number> <fingerprint-from-phase-2> <PASS|BLOCKING> <body-file>
```

- **Exit 0** — posted; marker JSON (pass number, comment URL) on stdout — report URL/pass to the user.
- **Exit 3 (stale)** — issue/PR changed since Phase 2's snapshot. Don't retry with the same body — restart from Phase 2 with a fresh snapshot; a substantive change may need re-analysis (Phase 4) too.
- **Exit 4 (duplicate)** — already reviewed this exact snapshot; no new comment needed. Report convergence, not an error.
- **Any other nonzero exit** — genuine script error (e.g. bad args). Stop and report, don't retry blindly.

In integration mode, pass the same flags through:

```bash
scripts/publish-review.sh <pr-number> <issue-number> <fingerprint-from-phase-2> <PASS|BLOCKING> <body-file> \
  --mode integration --previous-fingerprint <previous-fingerprint>
```

The script re-verifies the prior `PASS` from the comments it already
fetches, prepends a header naming the mode and both snapshots' head/base,
and adds `mode` and `previousFingerprint` to the `review-pr:v1` marker —
additive fields existing consumers ignore. Resolution only trusts a marker
whose `head`/`base` are full commit IDs, so that header always names real
commits rather than a placeholder. **Exit 5** means the prior
`PASS` stopped being trustworthy between Phase 1b and now: nothing was
posted; stop and request a full review.

Note: on a very long-lived PR, `gh pr view --json comments` may not return
full history (API pagination) — pass numbering/duplicate detection are
best-effort there; documented limitation, not coded around.

Note: markers are only recognized when authored by the same
`gh`-authenticated App identity running the review — deliberate (stops a PR
commenter forging a marker to suppress/fake a review). Changing the App
identity resets pass numbering and duplicate detection across that identity
change.

## Phase 7 — Cross-link affected PRs

For each Phase 4 finding naming/evidencing another open PR, write it to its
own file and run, once per affected PR:

```bash
scripts/publish-crosslink.sh <target-pr-number> <pr-number> <issue-number> <finding-body-file>
```

- **Exit 0** — posted to the target PR.
- **Exit 4 (duplicate)** — already cross-linked; no-op, not an error.
- **Any other nonzero exit** — genuine script error (e.g. bad args). Stop and report, don't retry blindly.

---

## Red Flags — STOP

- **Editing code, approving, merging, or changing draft/label state.** This skill only ever reads and posts comments.
- **Posting without Phase 2's fingerprint.** Always pass it to `publish-review.sh` for re-verification — never skip or hand-construct the staleness check.
- **Hand-rolling marker text.** Always go through `publish-review.sh`/`publish-crosslink.sh` — a hand-written marker can't be trusted by reruns or the external supervisor.
- **Leaving the detached review worktree behind.** Always `git worktree remove` it at the end of Phase 3, success or failure.
- **Repeating ordinary correctness/style/security/test feedback** unrelated to scope/description/architectural/complexity drift — that's other reviewers' job.
- **Speculative cross-linking.** Only cross-link with concrete evidence, never a guess that another PR "might" be relevant.
- **Publishing an integration pass without a resolved prior `PASS`.** Exit 5 from either script means run a full review — never fall back to posting an unverified integration comment, and never hand-pick a "close enough" prior marker.
- **Publishing a state/timing/race finding without completing the pre-publication checklist.** The replay is the point — a discriminator that also fires on Update Branch reads exactly like a valid repair until you replay the happy path through it.
- **Presenting a decision-required finding as a repair, or dropping it.** It stays blocking; it just names the invariant and the decision instead of an action.
- **Publishing a compound finding under one label.** If only part of it is mechanically repairable, split it — the repairable half must not be held hostage by the open decision.
