# Decisions

One line per decision, newest areas last. Personal numbers are intentionally absent.

## Data and cost
- Cost is an estimate (tokens × `pricing.json`, prices from the official pricing page, date in the file). Validated against Claude Code's own per-session cost state: prices match; local totals run ~9 % below Claude Code's accounting (calls not written to the log, hypothesis). Treat cost as a floor / relative ruler.
- Log dedup: one API response is written as several lines with the same `(message.id, requestId)` and a growing `output_tokens`; the **last** line wins, globally across files. `<synthetic>` placeholder records are skipped; a missing `requestId` keys on `message.id` alone.
- Log reading is incremental by byte offset in 1 MB chunks (desktop-app logs reach tens of MB); roots are rediscovered every 5 minutes. Memory ~50 MB, CPU ~0 % idle.
- Project = repository root (`/.claude/worktrees/` pattern, then `.git` directory = root, `.git` file = linked worktree → main repo); a session uses the root with most tokens. Desktop sandbox working directories are labelled "Cowork (app desktop)".
- `audit.jsonl` and `plan-usage-history.json` of the desktop app are not used (different format / unconfirmed fields).
- Per-model weekly gauges were dropped: `seven_day_opus` / `seven_day_sonnet` were `null` in every sample (fields stay optional in the decoder).

## Sources
- Source B (statusLine) is confirmed against the official statusLine docs and a real payload; it only updates while Claude Code is responding. "Stale" after 10 min; a window whose `resets_at` is in the past is dropped (like Claude Code does).
- Source C is opt-in and off by default. Login happens in the app's own `WKWebView`; requests are same-origin `fetch` calls inside a hidden WebView, so the app never reads, copies or logs cookies or tokens. Only HTTP status codes and key *names* are logged. Host must be exactly `claude.ai`.
- Source C endpoint URLs contain the organization id, so they are **not** bundled or versioned. They are pasted in Settings and stored in `UserDefaults`. Discovering the organization automatically was not done: no confirmed sample shows an organization-listing call. The credits URL is derived from the usage URL (`…/usage` → `…/prepaid/credits`, the shape observed for one account — a hypothesis for others) unless set explicitly.
- With C active it is the primary source and B the fallback; a C failure is always shown in the popover even when B fills in. Per-source backoff 30 s, 60 s, 120 s … up to 10 min; never more than one remote call per 30 s per endpoint; polling 60 s (15 s with the popover open). A manual refresh skips error backoff but not the 30 s minimum.
- Switching source (login finished, toggle on/off) resets remote backoff and cache and refreshes immediately. A switched-off source is never served from cache.
- Strict decoder for live responses. 401/403 = session expired; 404 = endpoint changed; network failure = offline. `resets_at: null` on a window means "window not started" (0 %, no reset time), not an endpoint change. A single invalid window degrades only that window (filled from B when fresh) while the rest of C — spend, balance, breakdown — is kept. Only invalid JSON or both windows unusable is reported as "endpoint changed", naming the field and whether it was null or another type.
- Credits balance (`balance.money.amount_minor` ÷ 10^`exponent`, currency from the response) is a second call, every 5 min and on manual refresh, ≥ 30 s apart. On failure the last known balance stays visible with "desatualizado desde HH:MM". The purchase history in the response (`tranches[]`) exists and is not used.
- "Used" credits come from `spend.used`; its period is not confirmed by the sample, so the UI says "usados" without "no mês".
- The usage response also carries `seven_day_breakdown.rows[] {key, display_name, percent}` (claude_code, chat, cowork, other). Hypothesis: shares of the weekly consumption (sum 100). Shown as an optional "week by product" line.
- Desktop-app session labels: `local_*.json` files hold `title` and `cliSessionId` (equal to the log `sessionId`). Only those two fields are read; the title replaces the project as the session name and the file location decides the origin (Code, Code (app), Cowork).
- Chats / Projects on claude.ai and cloud scheduled tasks leave no local token log; they only appear as a percentage of the account window. The panel says "only sessions with a local log".
- "Off-Mac activity" is a heuristic: consecutive source-C samples, %/US$ ratio calibrated by the median (≥ 10 calibration intervals); unavailable without source C.

## Projection and alerts
- 5h window: pace averaged over the last 30 min of samples (window younger than 30 min: average since the start); hidden before 15 min of window; orange only when exhaustion falls before the reset **and** usage is above 20 %, otherwise the pace is shown in gray.
- 7-day window: pace averaged over 24 h (or since the reset if younger); hidden before 12 h of window; alert only if exhaustion falls before the reset.
- Alerts at 50/75/90 % and on renewal; the first reading after launch only seeds state.

## UI
- Menu bar label is rendered with `ImageRenderer` into a non-template image because SwiftUI colors are flattened in the menu bar. Format `Claude S: 64% W: 23%`, optional prefix and optional balance.
- Balance color: yellow / red below configurable thresholds (defaults 25 / 10 in the account currency).
- Panel: period 7 d / 30 d / all, origin filter, daily chart always 30 days.
- Demo mode (`--demo` or Settings): fully synthetic data, no reads of `~/.claude`, no history database, no network.

## Build and repository
- SwiftPM only, no dependencies; SQLite3 from the system for the 180-day history.
- Tests: neither XCTest nor Swift Testing exists in a Command-Line-Tools-only setup. All checks live in `YACWSelfTest` and run via `yacw-cli selftest`; `Tests/` has a thin XCTest wrapper that runs the same function, executed by CI where XCTest exists.
- `bundle.sh` builds an ad-hoc signed `.app` and a zip; bundle id defaults to `local.yacw` (override with `BUNDLE_ID`). No binaries are versioned.
- Public repository: history was recreated as a single initial commit because earlier commits contained real API responses and personal names. `docs/samples/` holds synthetic `*.example.json` only; `scripts/privacy-check.sh` guards against regressions.

## Rename
- The project is now **YACW** ("Yet Another Claude Watcher"). Technical name `yacw` (package, `yacw-cli`, zip `dist/yacw-<version>.zip`), display name `YACW` (`YACW.app`, window titles). Modules: `YACWCore`, `YACWSelfTest`, `YACWApp`; tests in `Tests/YACWCoreTests`. No compatibility alias for the old CLI name: nothing was ever released.
- Bundle id default `local.yacw` (override with `BUNDLE_ID`). A new bundle id means a new preferences domain and a new WebKit data store, so the saved login is lost and the app asks to sign in again; preferences (including the pasted endpoint URLs) were copied from the old domain once, locally.
- Support folder is `~/Library/Application Support/YACW`. `AppPaths.migrateLegacy` renames the pre-rename folder on first launch, or moves only the missing files if both exist (nothing is overwritten); `statusline-writer.py` writes to the new folder. The old folder name is assembled from parts in one place so the repository no longer spells it.
- Menu bar prefix: "Claude" by default, optionally "YACW" (Settings), or hidden.
- Copyright holder: Clovis Chedid (MIT).

## Packaging
- Resources are located through `Bundle.main.resourceURL/yacw_YACWCore.bundle` (`Resources.url`); the SwiftPM `Bundle.module` accessor is used only outside an .app (swift run / test), because it looks in the app root or the absolute build path and calls `fatalError` otherwise — which crashed the app on machines other than the build machine. A missing bundle now yields a clear message ("pricing.json não encontrado…", costs unavailable) instead of a crash.
- `bundle.sh` signs with `--deep` and verifies (`codesign --verify --deep --strict`). `scripts/check-bundle.sh` copies the app to a temp folder, hides `.build` and runs `YACW --check-resources`; CI runs it.
- Screenshots (`docs/images/*.png`, demo mode) were reviewed: only synthetic data, each under 500 KB.

## Contributing and first launch
- CONTRIBUTING.md rewritten: best-effort maintenance, scope and non-goals (other platforms, cloud sync, telemetry, browser cookies, undocumented endpoints beyond `docs/DATA_SOURCES.md`), issue and PR rules. Commands and file references were checked against the repo: the price table is `Sources/YACWCore/Resources/pricing.json` (not at the root), the app target is `YACWApp`, and `swift test` is documented as the XCTest wrapper that needs Xcode.
- READMEs gained a "First launch" / "Primeira abertura" section: the ad-hoc signed zip is blocked by Gatekeeper on other Macs (right click > Open, or `xattr -dr com.apple.quarantine`); the app is not notarized (no paid developer account) and the source is open for audit and local build.
