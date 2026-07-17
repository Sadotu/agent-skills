# agent-skills

Self-authored agent skills, distributed to every project via
[dotagents](https://docs.sentry.io/ai/dotagents/) (`npx @sentry/dotagents
install`) instead of being copied file-by-file into each repo. Covers both
Claude Code and Codex from this one source.

Consumed by [`Sadotu/agent-devcontainer`](https://github.com/Sadotu/agent-devcontainer)'s
`.devcontainer/agents.toml`, baked into the published devcontainer image and
installed automatically by `setup-agents.sh` on every container start.

## Layout

Each skill lives at `skills/<name>/SKILL.md` (frontmatter: `name`,
`description`) — the `skills/` prefix is the "conventional directory"
`dotagents` searches for when resolving a bare `name` + `source = "owner/repo"`
entry in a consumer's `agents.toml`. Skills placed directly at the repo root
(no `skills/` prefix) won't resolve without an explicit `path` field.

## Skills

- `github-issue` — runs the full issue→PR workflow end to end: select the
  issue, open a draft PR immediately, self-resolve design decisions and log
  them to the PR, implement in an isolated worktree via subagents, verify
  against the issue, mark the PR ready. Repo-agnostic — resolves the current
  repo dynamically.
