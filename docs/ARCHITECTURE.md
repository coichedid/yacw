# Architecture

macOS 14+ menu bar app (Swift 5.10, SwiftUI `MenuBarExtra`, SwiftPM, no dependencies).

## Targets
| Target | Role |
|---|---|
| `YACWCore` | Library, no SwiftUI. Parsers, pricing, aggregation, providers, coordinator, history, insights, demo data. |
| `YACWApp` | SwiftUI app: menu bar label, popover, extended panel, login window, WebView transport. |
| `YACWSelfTest` | The project's checks (also run by the XCTest wrapper in `Tests/`). |
| `yacw-cli` | `selftest`, `projects`, `origins`, `status`, `compare`; prints rankings from local logs. |

## Data flow
`LogIndex` (incremental reader, sources A) + providers (`UsageEndpointProvider` for C, `StatuslineProvider` for B) → `UpdateCoordinator` (backoff, caching, fallback, history, projections, alerts) → `MeterState` → `AppModel` → views. `CreditsService` handles the balance call separately. `Dashboard.make` precomputes everything the extended panel shows off the main thread.

```
logs ──▶ LogIndex ─┐
statusLine ▶ B ────┼▶ UpdateCoordinator ▶ MeterState ▶ AppModel ▶ Popover / Panel / Label
WebView ─▶ C ──────┘        │
                       SQLite history (180 days)
```

## What it shows
- **Menu bar label:** `Claude S: 64% W: 23%` (colors: green < 70, yellow 70–89, red ≥ 90), optional prefix, optional balance.
- **Popover:** 5h and 7-day `LimitWindow` with reset countdown and pace projection; prepaid balance (large) and spend; weekly share by product; cache hit rate; off-Mac activity; source status; refresh; settings.
- **Extended panel:** rankings (most expensive / most recent / longest `WorkSession`s) with session title, origin and project; daily cost chart; tokens by model and project; cache hit; heat map; off-Mac heuristic. Period (7 d / 30 d / all) and origin filters.
- **Extras:** notifications at 50/75/90 % and renewal, CSV export, launch at login, demo mode.

## Naming
`LimitWindow` is the 5h / 7-day rate-limit window; `WorkSession` is a Claude Code session. They are never both called "session".

## Constraints
Read-only; no telemetry; network only to `claude.ai` and only with source C on; ≤ 1 remote call per 30 s per endpoint; idle CPU < 1 %, memory < 80 MB; UI in Brazilian Portuguese, code and comments in English; costs are estimates.
