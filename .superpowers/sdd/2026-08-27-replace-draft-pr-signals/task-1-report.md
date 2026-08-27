# Task 1 Report

## Changed files

- `skills/github-issue/scripts/tests/test-isolate.sh`: added happy-path assertions that `gh pr create` omits `--draft` and receives the literal `--title WIP: My PR Title`.
- `skills/github-issue/scripts/isolate.sh`: removed `--draft` and changed the title argument to `--title "WIP: $pr_title"`; updated adjacent comments.

## RED

Command: `skills/github-issue/scripts/tests/test-isolate.sh`

Result: expected failure. The test exited 1 with `27 passed, 2 failed`; the two failures were `case4: PR is not created as draft` and `case4: PR title is marked WIP`.

## GREEN

Command: `skills/github-issue/scripts/tests/test-isolate.sh`

Result: passed. All cases completed successfully: `29 passed, 0 failed`.

## Commit

`d32f1c63053d52160cc7875106f2885f70960ebf`

## Self-review

- The implementation changes only the PR creation flags and the adjacent description comments.
- The new assertions inspect the captured `gh` invocation and cover both required behaviors.
- `git diff --check` passed.

## Concerns

None.
