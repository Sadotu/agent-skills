---
name: setup
description: "Use when connecting this repo to the GitHub App — the /setup flow. Verifies the App's credentials are present, detects whether the App is installed on the current repo (surfacing the install URL to request it when it isn't), mints a short-lived installation token with the baked helper, confirms git/gh authenticate as the App, and reminds the never-gh-auth-login rule. Repo-agnostic; never prints or commits the private key or any token."
---

# Setup — Connect this repo to the GitHub App

Get the current repository talking to the configured GitHub App and prove it end
to end. The container authenticates to GitHub as the App via short-lived
installation tokens minted from its private key — never a user PAT, never
`gh auth login`. This skill is the manual verify-and-activate path for that: it
checks the credentials landed, requests the App install on the repo when it is
missing (the one step no script can do — it needs a human with admin), mints a
token, and confirms `git`/`gh` work as the App.

**Secrets rule (non-negotiable):** the private key and every minted token are
read but **never** printed to the terminal, written to a tracked file, logged,
or committed. Redact anything token-shaped in output you show the user.

This skill is repo-agnostic — it always operates on the repo it is invoked from.
Resolve that repo dynamically; never hardcode an owner/repo.

---

## Phase 1 — Resolve context

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
  || git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
WORKSPACE="$(git rev-parse --show-toplevel)"
```

Locate the token helper. In the container it is baked at
`/opt/agent-devcontainer/gh-app-token.sh`; fall back to the repo copy for
host/dev use:

```bash
HELPER=/opt/agent-devcontainer/gh-app-token.sh
[ -x "$HELPER" ] || HELPER="$WORKSPACE/.devcontainer/gh-app-token.sh"
[ -x "$HELPER" ] || { echo "setup: gh-app-token.sh helper not found"; exit 1; }
```

Locate the credentials directory — mirror the helper's own resolution order
(persisted volume first, then the `/tmp` seed):

```bash
APP_DIR="${GITHUB_APP_DIR:-$HOME/.config/github-app}"
[ -r "$APP_DIR/app-id" ] || { [ -r /tmp/github-app/app-id ] && APP_DIR=/tmp/github-app; }
```

---

## Phase 2 — Verify credentials are present

The only secret needed is the App ID and its private key:

```bash
[ -r "$APP_DIR/app-id" ]          || { echo "setup: missing $APP_DIR/app-id"; MISSING=1; }
[ -r "$APP_DIR/private-key.pem" ] || { echo "setup: missing $APP_DIR/private-key.pem"; MISSING=1; }
```

If either is missing, **stop** — nothing downstream can work without the key.
Point the user at how `setup-agents.sh` supplies them, and do not try to
fabricate them:

- Bitwarden: set `BW_GITHUB_APP_ITEM_ID` to a vault item with custom text fields
  `app-id` and `private-key-b64` (the `.pem` run through `base64 -w0`), then
  rebuild — `setup-agents.sh` fetches them into the persisted volume.
- Manual drop (only needed once, survives plain rebuilds):
  ```bash
  printf '%s\n' '<APP_ID>' > ~/.config/github-app/app-id
  cp /path/to/private-key.pem ~/.config/github-app/private-key.pem
  chmod 600 ~/.config/github-app/private-key.pem
  ```

Never print the contents of `private-key.pem`.

---

## Phase 3 — Introspect the App and its installation

Sign one short-lived App JWT and use it read-only: `GET /app` proves the key is
valid and yields the App's identity (slug + install URL); `GET
/repos/$REPO/installation` reports whether the App is installed on this repo
(`200` = installed, `404` = not). This cleanly separates "not installed" from
"bad key / network", which a plain mint attempt cannot.

```bash
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
APP_ID="$(tr -d '[:space:]' < "$APP_DIR/app-id")"
now=$(date +%s)
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)"
signing_input="${header}.${payload}"
sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$APP_DIR/private-key.pem" | b64url)"
JWT="${signing_input}.${sig}"
jwtapi() { curl -s -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" "$@"; }

APP_JSON="$(jwtapi https://api.github.com/app)"
APP_SLUG="$(printf '%s' "$APP_JSON" | jq -r '.slug // empty')"
APP_HTML="$(printf '%s' "$APP_JSON" | jq -r '.html_url // empty')"
[ -n "$APP_SLUG" ] || { echo "setup: App JWT rejected — check the private key / App ID"; exit 1; }
echo "setup: App '$APP_SLUG' (id $APP_ID), key valid."

INST_STATUS="$(jwtapi -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$REPO/installation")"
```

Do not print `$JWT`.

---

## Phase 4 — Request the App install on the repo (only if not installed)

If `INST_STATUS` is `404`, the App is not installed on `$REPO`. The agent has no
admin rights and cannot install it — surface the install URL and ask the human
to do it, then wait and re-check. Loop until installed:

```bash
if [ "$INST_STATUS" = 404 ]; then
  echo "setup: GitHub App '$APP_SLUG' is NOT installed on $REPO."
  echo "       Install it (needs a repo/org admin), granting access to $REPO:"
  echo "         ${APP_HTML}/installations/new"
  echo "       Then re-run /setup (or press on and I'll re-check)."
fi
```

Re-check with the same `GET /repos/$REPO/installation` call after the human
confirms. Any status other than `200`/`404` (e.g. `401`) means the key or App ID
is wrong — stop and report it rather than looping.

---

## Phase 5 — Mint a token and wire git

Once installed, get a real installation token from the **baked helper** — the
single source of truth for tokens; this skill never mints the installation token
itself:

```bash
GH_TOKEN="$(GITHUB_APP_REPO="$REPO" "$HELPER")" \
  gh api "repos/$REPO/installation" -q '.app_slug' >/dev/null \
  && echo "setup: installation token minted and gh authenticates as the App." \
  || { echo "setup: token mint / gh check failed for $REPO"; exit 1; }
```

Ensure `git push`/`git fetch` use the App via the credential helper. Check it,
and wire it if absent (the same line `setup-agents.sh` sets):

```bash
CUR="$(git config --global --get credential.https://github.com.helper || true)"
case "$CUR" in
  *git-credential-github-app.sh*) echo "setup: git credential helper already wired." ;;
  *)
    CRED="$(dirname "$HELPER")/git-credential-github-app.sh"
    git config --global credential.https://github.com.helper "!$CRED"
    echo "setup: wired git credential helper -> $CRED"
    ;;
esac
```

---

## Phase 6 — Confirm and remind

Report the connection succinctly:

- App: `$APP_SLUG` (id `$APP_ID`)
- Repo: `$REPO` — App installed, token mints, `gh` authenticates, `git` credential
  helper wired.

Then restate the standing rule for this container:

- **Never** run `gh auth login` or `gh auth setup-git` — GitHub access is the App
  exclusively. `gh`/`git push` work automatically now.
- For any `gh` command, mint per-call:
  `GH_TOKEN="$(GITHUB_APP_REPO="$REPO" "$HELPER")" gh <cmd> --repo "$REPO"`.

---

## Non-Negotiable Rules

- Never print, log, or commit the private key or any minted token; redact
  token-shaped strings before showing output.
- The baked `gh-app-token.sh` is the only thing that mints installation tokens;
  the inline JWT here is read-only introspection, never a push credential.
- The agent cannot install the App — it can only surface the install URL and
  request a human with admin do it.
- Resolve the repo dynamically; never hardcode owner/repo.
- Never `gh auth login` / `gh auth setup-git` in this container.
