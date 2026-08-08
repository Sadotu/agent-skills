---
name: address-review
description: Repair blocking findings from one trusted review-pr snapshot on an existing managed issue/PR worktree, verify and commit the repair, then safely push the same branch.
---

# Address Review

Invoke as `/address-review <issue-number> <pr-number> <review-fingerprint>`.

This skill repairs only blocking findings from a specific trusted `review-pr`
snapshot. It operates on an existing PR and managed `agent/<issue>-*` worktree.
It never creates a PR or worktree, changes labels or draft state, approves or
merges, or launches another review.

## Guarded entry

Before any mutation, run:

```bash
skills/address-review/scripts/inspect.sh <issue-number> <pr-number> <review-fingerprint>
```

Stop on any error. The inspector rejects manual PRs: the issue must carry
`agent-running`, the PR must exactly close the issue, its head must be a managed
`agent/<issue>-*` branch with exactly one existing worktree, and its current
snapshot must match the trusted review marker and supplied fingerprint.

Treat only the inspector's JSON output as identity data. Change directory only
to its emitted `worktree`, confirm its emitted branch and head, and use the exact
emitted `commentBody` as the review input. Do not substitute a copied comment,
another comment, or a newly fetched review.

## Decide what to repair

Extract the blocking findings from the trusted comment. Address those findings
only. Nonblocking observations are context, not additional scope.

For every blocking finding, verify it against the issue, PR description, and
current code. If a finding is unresolved, ambiguous, or contradicted by those
sources, do not make a speculative change. Stop and report the finding, the
conflicting evidence, and the decision needed from the user.

Before editing, use `superpowers:test-driven-development`. Reproduce each
accepted behavior gap with a focused failing test, observe the expected RED,
make the minimum repair, then observe GREEN. Preserve unrelated user changes.

Update the existing PR body only when the repair changes its claimed behavior
or design. In that case, keep its exact closing line and update the relevant
Problem/Approach summary and Design Decisions Q&A so they match the resulting
diff. Do not rewrite accurate sections merely to record activity.

## Verify, commit, and finalize

Run the relevant focused tests and the repository's complete test suite. Keep
useful command output in the session log, without credentials or tokens. Create
a JSON verification sentinel outside the repository or as an ignored file:

```json
{"status":"success","command":"<commands actually run>","result":"<concise observed passing result>"}
```

The command and result must be nonempty and must describe fresh successful
verification. Commit at least one repair change on the inspected branch. The
tracked worktree must be clean afterward; untracked durable logs are allowed but
must not contain credentials.

From the exact emitted worktree, call:

```bash
skills/address-review/scripts/finalize.sh \
  <issue-number> <pr-number> <inspector-head> \
  <inspector-branch> <inspector-worktree> <verification-json>
```

The finalizer revalidates numeric identifiers, exact worktree/branch identity,
the unchanged PR head branch, successful verification evidence, a clean tracked
tree, and at least one new descendant commit beyond the inspected head. It then
pushes exactly `HEAD:refs/heads/<inspector-branch>`. A push failure is terminal;
report its output and do not attempt lifecycle actions.

Finish by reporting the repaired findings, commit SHA, focused and full-suite
verification evidence, and push result. Do not mark ready, approve, merge,
change labels, create or close anything, or start another review pass.
