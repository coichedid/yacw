# Changelog

## 0.1.0 — unreleased

First public version.

- Menu bar label (`Claude S: 64% W: 23%`, colored by band, optional balance) and popover with the 5h and 7-day limit windows, reset countdowns, pace projection and alerts.
- Sources: A (Claude Code / Cowork logs), B (statusLine), C (account endpoints, opt-in), D (local estimate).
- Prepaid credit balance with configurable yellow/red thresholds.
- Extended panel: rankings by cost / recency / duration with origin and title, daily cost chart, tokens by model and project, cache hit rate, heat map, off-Mac activity heuristic, weekly share by product.
- Notifications at 50/75/90 % and on renewal, CSV export, launch at login.
- Demo mode (`--demo`) with fully synthetic data.
- The support folder `~/Library/Application Support/YACW` replaces the pre-release folder name; existing files (state.json, history) are migrated on first launch.
- `scripts/bundle.sh` builds an ad-hoc signed `.app` and a release zip.
