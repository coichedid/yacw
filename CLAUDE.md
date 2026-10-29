# CLAUDE.md — YACW

macOS (Sonoma+) menu bar app that shows Claude usage limits and consumption. Read `docs/ARCHITECTURE.md` and `docs/DATA_SOURCES.md` first.

## Rules
- Keep it simple and fast: go straight to the code, small commits.
- No endpoint, field or format "from memory": only what is confirmed by a (synthetic, same-shape) sample in `docs/samples/` or observed in local logs. Everything else is a hypothesis and must be called one.
- Never read browser cookies. Never print or commit tokens. Read-only. Credentials stay inside the app's WebView data store.
- Swift Package Manager, no external dependencies. Logic in `YACWCore` (no SwiftUI), UI in `YACWApp`.
- Names: `LimitWindow` (5h / 7-day window) and `WorkSession` (a Claude Code session). Never just "Session".
- UI strings in Brazilian Portuguese; code and comments in English.
- If something blocks (unconfirmed source, missing sample), stop and ask the maintainer instead of assuming.
- Samples committed to the repo must be synthetic. Run `scripts/privacy-check.sh` before committing.

## Commands
- `swift build`, `swift run yacw-cli selftest` (same checks as `swift test`, which needs XCTest)
- `./scripts/bundle.sh` builds `YACW.app` and `dist/yacw-<version>.zip` (notifications need a bundle)
- `open YACW.app --args --demo` for synthetic data
