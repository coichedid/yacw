# Security and privacy

YACW is read-only and has no telemetry. This document says exactly what it reads, stores and sends.

## Credentials
- The app **never reads browser cookies** and never asks for your password or an API key.
- Source C (optional, off by default) uses a normal login inside the app's own `WKWebView`. The session cookie stays in WebKit's data store for this app. The app does not read, copy, print or save it: usage requests are same-origin `fetch` calls executed inside that WebView.
- No token or cookie is written to any file, log or the repository. The debug log records HTTP status codes and key *names* only.

## What the app reads
- Claude Code logs: `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, and the Claude desktop app's Cowork sandbox logs under `~/Library/Application Support/Claude/local-agent-mode-sessions`. Only token counts, model, timestamps, session id and working directory are used.
- Desktop session metadata files (`local_*.json`): only `cliSessionId` and `title` are read; prompts and everything else are ignored.
- `~/Library/Application Support/YACW/state.json`, written by the optional statusLine script.

## What the app writes (all local)
- `~/Library/Application Support/YACW/` (a folder from earlier pre-release builds is migrated into it): `state.json` (rate limits + timestamp), the history database (percentages over time), `debug.log`, `compare.log`.
- `UserDefaults` for the app: preferences, the two endpoint URLs you paste (they contain your organization id), and the last known credit balance.
- Optionally `~/.claude/settings.json` if you install the statusLine script yourself (see `scripts/README.md`).

## Network
Only when source C is on: HTTPS requests to `claude.ai` (hosts other than `claude.ai` are rejected), at most one per 30 s per endpoint. Nothing is sent anywhere else.

## Reporting a problem
Please use a private GitHub security advisory ("Report a vulnerability" on the Security tab) or contact the maintainer (Clovis Chedid) privately. Do **not** paste cookies, tokens, organization ids, or real API responses into public issues.
