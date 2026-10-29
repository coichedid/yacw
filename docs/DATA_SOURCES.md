# Data sources

None of these is an official, documented API except where stated. Each can change.

| | Source | Gives | Needs | Main fragility |
|---|---|---|---|---|
| A | Claude Code / Cowork JSONL logs | sessions, tokens, models, cost estimate, projects, heat map | read access to the log folders | undocumented format |
| B | Claude Code `statusLine` | % and reset of the 5h and 7-day windows | `scripts/statusline-writer.py` installed | only updates while Claude Code responds on this Mac |
| C | Account endpoints on `claude.ai` (opt-in) | exact %, resets for the whole account, spend, prepaid balance, weekly share by product | login in the app + the endpoint URLs pasted in Settings | undocumented, can change or be restricted |
| D | Local estimate | estimated reset time of the current 5h window | A | no percentage |

## A — local logs
- Locations: `~/.claude/projects`, `$CLAUDE_CONFIG_DIR/projects`, and the Claude desktop app's Cowork sandboxes `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects` (same format; includes real sidechain/subagent logs).
- Used fields of `type: "assistant"` lines: `sessionId`, `timestamp`, `cwd`, `requestId`, `isSidechain`, `message.{id,model,usage}` (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `cache_creation.ephemeral_1h_input_tokens`).
- One response is written as several lines; `output_tokens` grows, so the last line per `(message.id, requestId)` wins.
- Not covered: claude.ai chats and Projects, cloud scheduled tasks, other machines. Cost is an estimate and sits ~9 % below Claude Code's own accounting.
- Session labels: the desktop app writes `local_*.json` next to its sessions (`Application Support/Claude/local-agent-mode-sessions/<id>/<id>/` for Cowork, `.../claude-code-sessions/<id>/<id>/` for the Code tab). `cliSessionId` equals the log `sessionId`; `title` is a short label. Nothing else is read.

## B — statusLine
Claude Code pipes a JSON document to the configured `statusLine` command (official docs: code.claude.com/docs/en/statusline). Fields used: `rate_limits.five_hour` and `rate_limits.seven_day` with `used_percentage` (0–100) and `resets_at` (epoch seconds). Present only for subscribers, after the first API response of a session; a window can be missing. The writer script keeps only `rate_limits` and a timestamp. See `scripts/README.md`.

## C — account endpoints (opt-in)
Two JSON calls on `https://claude.ai/api/organizations/<org-id>/…` (shape observed on one account; the organization id is personal, so you paste the URLs yourself):

- `…/usage` — `five_hour` and `seven_day` `{utilization, resets_at}` (`resets_at: null` = window not started); `spend.used {amount_minor, currency, exponent}`; `extra_usage`; `limits[]`; `seven_day_breakdown.rows[] {key, display_name, percent}`. Many other keys exist and are ignored. `seven_day_opus` / `seven_day_sonnet` were null in every sample.
- `…/prepaid/credits` — `balance.money {amount_minor, currency, exponent}`; `tranches[]` (purchase history) is not used.

Synthetic samples with the same shape: `docs/samples/*.example.json`. How to get the URLs: README, "Configuring source C". Requests run as same-origin `fetch` inside the app's WebView, at most one per 30 s per endpoint.

Fragilities: endpoints are undocumented and may change, be rate limited or restricted; a login session can expire (HTTP 401/403 → "sessão expirada"); the period of `spend.used` and the meaning of `seven_day_breakdown.percent` are not confirmed.

## D — local estimate
Start of the current 5h window = first local response after the previous window ended; end = start + 5 h. Shown only when no percentage source is available, and labelled as an estimate.
