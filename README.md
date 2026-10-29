# YACW

**Yet Another Claude Watcher — a macOS menu bar meter for Claude usage limits**

[Português](README.pt-BR.md)

A macOS menu bar app that shows how much of your Claude usage limits you have used — the 5-hour and 7-day windows, when they reset, your prepaid balance — plus a panel with your most expensive, most recent and longest Claude Code sessions.

> **Unofficial.** YACW is an independent project, **not affiliated with, endorsed by or sponsored by Anthropic**. "Claude" is a trademark of Anthropic; this project uses no Anthropic or Claude logos. See [Disclaimers](#disclaimers).

![Menu bar](docs/images/menubar.png)

<p><img src="docs/images/popover.png" alt="Popover" width="340">

![Extended panel](docs/images/extended.png)

*Screenshots use demo mode (synthetic data).*

## Features
- Menu bar label such as `Claude S: 64% W: 23%`, colored by band (green < 70, yellow 70–89, red ≥ 90). The prefix can be "Claude" (default), "YACW" or hidden; the balance can be added.
- Popover: 5h and 7-day `LimitWindow` with reset time and countdown, pace projection ("exhausts ~17:21" only when it is actually likely), prepaid credit balance with configurable yellow/red thresholds, weekly share by product, cache hit rate, source status.
- Extended panel: rankings of Claude Code / Cowork sessions (cost, recency, active duration) with title, origin and project, daily cost chart, tokens by model and project, heat map, period and origin filters, an "off-Mac activity" heuristic.
- Notifications at 50/75/90 % and when a window renews, CSV export, launch at login.
- Demo mode with synthetic data for screenshots (`--demo`).

## Requirements
macOS 14 (Sonoma) or later. Swift 5.9+ toolchain to build (Command Line Tools are enough; Xcode is not required).

## Install
**From a release:** download `yacw-<version>.zip` from the Releases page, unzip, and move `YACW.app` to Applications.

#### First launch
The app is signed ad hoc, so macOS blocks the first launch on other Macs. Right click `YACW.app`, choose **Open**, and confirm; or, in Terminal:

```
xattr -dr com.apple.quarantine YACW.app
```
YACW is not notarized by Apple (that requires a paid developer account). The source code is open, so you can audit it and build it yourself (`swift build` / `scripts/bundle.sh`).

**From source:**
```
git clone <this repository> && cd yacw
./scripts/bundle.sh          # builds YACW.app and dist/yacw-<version>.zip
open YACW.app
```
Preview with fake data: `open YACW.app --args --demo`.

## Data sources (details in [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md))
Works out of the box from local Claude Code logs (sessions, cost estimate). For the real limit percentages you have two options:

1. **Source B — statusLine (no login).** Install the tiny script in [scripts/README.md](scripts/README.md); percentages update whenever Claude Code responds on this Mac.
2. **Source C — your account (opt-in, off by default).** Exact percentages for the whole account (chat, Cowork, other machines), spend and prepaid balance.

### Configuring source C
1. Settings (in the popover) > turn on "Fonte C" and click **Entrar** to sign in to claude.ai in the app's own window.
2. In your browser, open `claude.ai/settings/usage`, open DevTools > Network > Fetch/XHR, reload, and copy the URL of the request ending in `/usage`. It has the form `https://claude.ai/api/organizations/<your-org-id>/usage`.
3. Paste it in "URL de uso". The credits URL is derived from it (`…/prepaid/credits`, a shape observed for one account — paste it explicitly if yours differs).

The URLs contain your organization id: they are stored only in this app's preferences, never bundled or committed. Don't paste them in public issues. The endpoints are undocumented and may change — see limitations.

## Privacy and security
Read-only, no telemetry. The app never reads browser cookies, never asks for your password or an API key, and never writes a token or cookie anywhere: the login lives in the app's own WebView and requests run inside it. Network traffic exists only with source C on, and only to `claude.ai`. Full details: [SECURITY.md](SECURITY.md).

## Known limitations
- Rankings cover **only sessions with a local log** (Claude Code and Cowork on this Mac). claude.ai chats, Projects, cloud scheduled tasks and other machines leave no local log; they show up only as a percentage of the account window.
- Percentages from source C depend on **undocumented endpoints** that can change or be restricted at any time; the app then shows an "endpoint changed" state and falls back to source B.
- **Costs are estimates** (tokens × public prices), typically a few percent below Claude Code's own accounting. On a subscription they are a relative ruler, not a bill.
- Source B only updates while Claude Code is responding.
- The UI is in Brazilian Portuguese.
- Tests: the full check list runs with `swift run yacw-cli selftest` (works with Command Line Tools). `swift test` runs the same checks through an XCTest wrapper, which needs Xcode / a CI runner; neither XCTest nor Swift Testing is available with Command Line Tools only, so no Swift Testing migration was done. CI runs both.

## Disclaimers
- Unofficial, not affiliated with Anthropic. No Anthropic or Claude logos are used.
- It relies on undocumented endpoints and local file formats that may change or be restricted by Anthropic; using source C may be against the terms of service that apply to you. **Use at your own risk**; the authors are not responsible for account restrictions or any other consequence.
- Read-only: it never changes your account, settings or logs (the optional statusLine script only edits a setting you add yourself).

## Documentation
[Architecture](docs/ARCHITECTURE.md) · [Data sources](docs/DATA_SOURCES.md) · [Decisions](docs/DECISIONS.md) · [Scripts](scripts/README.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## License
MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Clovis Chedid.
