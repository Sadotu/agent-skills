# Unattended Baseline-Failure Triage

This is the narrow unattended override to `superpowers:using-git-worktrees`. Interactive runs keep that skill's default: report the baseline failure and ask. Never ignore, suppress, exclude, weaken, or convert a failure.

Classify each failing test independently:

1. Capture the exact command, failing test, exit status, and bounded relevant output from the issue worktree.
2. Run the same command in a separate untouched checkout pinned to `git merge-base origin/main HEAD`. Do not reuse issue-branch or generated state.
3. Identify implicated files from the failing test, stack trace, assertion, coverage, and focused investigation.
4. Compare those files and the failure behavior with the issue's planned and actual change surface: tests, production files, configuration, dependencies, and shared infrastructure.
5. Run the classifier once per failure. Put comments on their own lines; never append them after continuation backslashes.

```bash
# Reproduction was on an untouched checkout at the branch-base origin/main commit.
# Surface overlap includes planned and actual issue changes.
# Worsened means new, worse, or materially different output, assertions, exit, or timing.
# Resolved means the branch changes it without a reviewed in-scope cause.
# Ambiguous includes flaky, timeout, environmental, global-setup, or unclassifiable failures.
scripts/baseline-triage.sh \
  --reproduces-on-main <yes|no> \
  --overlaps-surface <yes|no> \
  --branch-worsened <yes|no> \
  --branch-resolved <yes|no> \
  --ambiguous <yes|no>
```

The classifier prints `CONTINUE` with exit 0 only when the failure provably reproduces on untouched `origin/main` and is unrelated on every axis. Missing, unclear, overlapping, changed, or ambiguous evidence produces `STOP: <reason>` with exit 2. Continue only if every failure returns `CONTINUE`; otherwise stop, report every classification, and ask for direction.

For every accepted failure, add an `Accepted baseline failure` section to the issue PR with the command, exact test, bounded output, `origin/main` and issue-branch SHAs, implicated files, change-surface comparison, verdict, and rationale. Redact secrets without hiding diagnostic facts; link an artifact for large output.

In Phase 5, rerun each recorded command and classifier. Set `--branch-worsened yes` for changed output, assertions, exit, or timing, and set `--overlaps-surface yes` if the final change surface overlaps. Any `STOP` blocks readiness. Otherwise preserve the confirmed-unchanged evidence in the PR verification summary.

The classifier reads supplied evidence only; it does not run or alter tests. The operator remains responsible for every judgment.
