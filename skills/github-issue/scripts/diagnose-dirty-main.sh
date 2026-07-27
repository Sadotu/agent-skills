#!/usr/bin/env bash
# Read-only diagnosis for Phase 2 ("Synchronize and Isolate") of
# skills/github-issue/SKILL.md, run when isolate.sh's dirty-primary-tree
# guard trips.
#
# Never mutates: only `git rev-parse --is-inside-work-tree`, `git status
# --porcelain` (plain, to gate clean/dirty), `git status --porcelain
# --ignored -z` (to enumerate untracked/ignored paths, NUL-delimited so
# quoted/escaped paths parse correctly), `git diff --cached --name-status`
# (staged), `git diff --name-status` (unstaged changes to tracked files),
# and `git check-ignore -v` per untracked path. Reports a staged / unstaged
# / untracked breakdown so an agent can tell "genuinely untracked scaffold
# .gitignore doesn't cover yet" apart from "should already be ignored but
# isn't on this checkout" instead of freelancing a fix on shared main.
#
# Usage: diagnose-dirty-main.sh
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: diagnose-dirty-main.sh" >&2
  exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null

plain_porcelain="$(git status --porcelain)"

if [ -z "$plain_porcelain" ]; then
  echo "(clean — no staged, unstaged, or untracked changes)"
  exit 0
fi

echo "=== Staged changes ==="
staged="$(git diff --cached --name-status)"
if [ -n "$staged" ]; then
  echo "$staged"
else
  echo "(none)"
fi

echo
echo "=== Unstaged changes to tracked files ==="
unstaged="$(git diff --name-status)"
if [ -n "$unstaged" ]; then
  echo "$unstaged"
else
  echo "(none)"
fi

echo
echo "=== Untracked paths ==="
untracked=()
while IFS= read -r -d '' entry; do
  case "$entry" in
    '??'*|'!!'*) untracked+=("${entry:3}") ;;
  esac
done < <(git status --porcelain --ignored -z)

if [ "${#untracked[@]}" -eq 0 ]; then
  echo "(none)"
else
  for path in "${untracked[@]}"; do
    if verdict="$(git check-ignore -v -- "$path" 2>/dev/null)"; then
      echo "${path}: ignored (${verdict%%$'\t'*})"
    else
      echo "${path}: NOT ignored — genuinely untracked"
    fi
  done
fi
