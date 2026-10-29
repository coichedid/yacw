# Contributing

Small, focused pull requests are welcome.

- Build: `swift build`. Checks: `swift run yacw-cli selftest` (works with Command Line Tools) or `swift test` (needs XCTest/Xcode; it runs the same checks).
- Logic goes in `Sources/YACWCore` (no SwiftUI); UI in `Sources/YACWApp`. Code and comments in English, UI strings in Brazilian Portuguese.
- No external dependencies.
- No endpoint, field or format "from memory": base changes on a real (anonymized) sample or mark them as a hypothesis. Samples in `docs/samples/` must be **synthetic** (`*.example.json`).
- Never commit cookies, tokens, organization ids, real API responses, real session titles or project names. Run `scripts/privacy-check.sh` before pushing.
- Use the two names consistently: `LimitWindow` (the 5h / 7-day window) and `WorkSession` (a Claude Code session).
