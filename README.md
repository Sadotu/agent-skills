# agent-skills

Agent skills for Claude Code and Codex, distributed to projects with
[dotagents](https://docs.sentry.io/ai/dotagents/).

[`Sadotu/agent-devcontainer`](https://github.com/Sadotu/agent-devcontainer)
includes them in its image and installs them on container startup.

## Layout

Skills live at `skills/<name>/SKILL.md` with `name` and `description`
frontmatter. This conventional path lets dotagents find them without an
explicit `path` in `agents.toml`.

## Skills

- `github-issue` — takes an issue from selection to a verified, ready-for-review
  PR using an isolated worktree and subagents. Works in any repository.
- `github-pr-cleanup` — safely cleans the owned worktree and branch for one
  merged or closed PR, manually or through Worktree Warden.
- `review-pr` — one read-only, idempotent application-drift review pass
  against a linked issue and PR: scope/description drift, overengineering,
  convention drift, integration gaps, orphaned compatibility code. Never
  edits code or changes draft/label state.
- `address-review` — repairs blocking findings from one trusted `review-pr`
  snapshot in an existing managed worktree, verifies and commits the repair,
  then safely pushes the unchanged PR branch without lifecycle actions.
