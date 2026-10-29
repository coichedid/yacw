# Contributing to YACW

Thanks for your interest. Please read this first, it will save us both time.

## Project status

YACW is a small side project, maintained on a best-effort basis by one person.
Issues and pull requests are welcome, but responses may take days or weeks, and
some will not be accepted even if they are good. That is about maintenance
capacity, not about your work.

## What fits the project

- Accurate display of Claude usage limits, reset times, credits, and local usage.
- Small, readable code with no external dependencies.
- Privacy by default: nothing leaves the Mac except the optional, user-enabled
  claude.ai query.

Things unlikely to be accepted: other platforms, cloud sync, telemetry of any
kind, reading browser cookies, or relying on undocumented endpoints beyond the
ones already documented in `docs/DATA_SOURCES.md`.

## Before you open an issue

- Search existing issues.
- For a bug, include macOS version, YACW version, which data source is active
  (A/B/C), and what you expected versus what happened.
- **Never paste tokens, cookies, `state.json`, or raw logs.** Use demo mode
  (`open YACW.app --args --demo`) or the synthetic samples in `docs/samples/`
  to reproduce.
- If the claude.ai endpoint changed and the app shows an error, say so: that is
  the most common breakage and is useful to know.

## Before you open a pull request

For anything beyond a small fix, open an issue first so we can agree on scope.

Development setup:

    swift build
    swift run yacw-cli selftest
    ./scripts/bundle.sh
    open -n ./YACW.app --args --demo

`swift run yacw-cli selftest` is the full check list and works with the Command
Line Tools alone. `swift test` runs the same checks through an XCTest wrapper
(`Tests/YACWCoreTests`), which needs Xcode; CI runs both.

Rules:

1. Swift Package Manager only, no external dependencies.
2. Logic goes in `YACWCore`, UI in the app target (`YACWApp`). Keep logic
   testable.
3. User-facing strings are in Portuguese (pt-BR) today. Localization to English
   and other languages is welcome and on the roadmap, with no timeline; please
   propose it as a separate change, not mixed with other work.
4. Do not invent endpoints or fields. Anything new about the claude.ai
   responses must be backed by a (sanitized) sample in `docs/samples/`.
5. Prices live in `Sources/YACWCore/Resources/pricing.json`. A price update is
   a welcome, small PR.
6. Run `scripts/privacy-check.sh` and make sure no personal data, real
   balances, or account identifiers are in the diff, samples, or screenshots.
7. Keep PRs focused: one change per PR, with a short description of what and
   why. Update `CHANGELOG.md`.

## Review

I will review when I can. I may ask for changes, ask to split the PR, or decline
it. If a PR sits idle with no reply from you for a month, I may close it.

## Security

Do not report vulnerabilities in public issues. See `SECURITY.md`.

## License

By contributing, you agree that your contributions are licensed under the MIT
License of this project.
