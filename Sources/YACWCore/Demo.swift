import Foundation

/// 100% synthetic data for `--demo` (public screenshots): fictional limits, balance, projects and sessions.
/// Nothing here reads `~/.claude`, the desktop app folders, the history database or the network.
public enum DemoData {
    public struct Bundle: Sendable {
        public var state: MeterState
        public var meta: [String: SessionMeta]
        public var credits: CreditsState
    }

    public static func make(pricing: PricingTable, now: Date = Date()) -> Bundle {
        var seed: UInt64 = 42
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let projects = ["/Users/demo/projects/acme-api", "/Users/demo/projects/weather-bot", "/Users/demo/projects/dotfiles"]
        let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        let titles = ["Refactor billing module", "Weekly report draft", "Fix flaky integration test", "Plan release notes", "Summarize research papers", "Migrate config to TOML"]
        var records: [UsageRecord] = []
        var meta: [String: SessionMeta] = [:]
        let cal = Calendar.current
        var n = 0
        for day in 0..<30 {
            let dayStart = cal.startOfDay(for: now.addingTimeInterval(-Double(day) * 86_400))
            for _ in 0..<(1 + rnd(3)) {
                n += 1
                let sid = "demo-\(n)"
                let kind = rnd(5)                                   // 0 = Cowork, 1 = Code (app), else CLI
                var t = dayStart.addingTimeInterval(Double(9 + rnd(9)) * 3600 + Double(rnd(50)) * 60)
                let cwd = kind == 0 ? "/sessions/demo" : projects[rnd(projects.count)]
                let model = models[rnd(models.count)]
                if kind == 0 { meta[sid] = SessionMeta(title: titles[rnd(titles.count)], origin: .cowork) }
                if kind == 1 { meta[sid] = SessionMeta(title: titles[rnd(titles.count)], origin: .codeDesktop) }
                for i in 0..<(8 + rnd(40)) {
                    t = t.addingTimeInterval(Double(60 + rnd(180)))
                    guard t < now else { break }
                    var r = UsageRecord(sessionId: sid, messageId: "m\(n)-\(i)", requestId: "r\(n)-\(i)", timestamp: t, cwd: cwd, model: model,
                                        usage: TokenUsage(input: 3 + rnd(30), output: 400 + rnd(3000), cacheRead: 20_000 + rnd(130_000),
                                                          cacheWrite: 1_000 + rnd(9_000)))
                    r.origin = kind == 0 ? .cowork : .code
                    records.append(r)
                }
            }
        }

        var st = MeterState()
        var snap = UsageSnapshot(source: .usageEndpoint, fetchedAt: now,
                                 fiveHour: LimitWindow(kind: .fiveHour, usedPercent: 64, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
                                 sevenDay: LimitWindow(kind: .sevenDay, usedPercent: 23, resetsAt: now.addingTimeInterval(4 * 86_400 + 3 * 3600)),
                                 extraUsage: ExtraUsage(currency: "USD", used: 42.50))
        snap.breakdown = [BreakdownRow(key: "claude_code", name: "Claude Code", percent: 35), BreakdownRow(key: "chat", name: "Chats", percent: 20),
                          BreakdownRow(key: "cowork", name: "Cowork", percent: 40), BreakdownRow(key: "other", name: "Other", percent: 5)]
        st.snapshot = snap
        st.status = .ok(.usageEndpoint); st.endpoint = .active(lastSuccess: now); st.updatedAt = now
        st.projection5h = .ready(Projection(ratePerHour: 18.5, exhaustsAt: now.addingTimeInterval(115 * 60), warn: true))
        st.projection7d = .ready(Projection(ratePerHour: 0.6, exhaustsAt: nil))
        st.records = records
        st.sessions = Aggregation.sessions(from: records, pricing: pricing, meta: meta)
        return Bundle(state: st, meta: meta,
                      credits: CreditsState(balance: CreditBalance(currency: "USD", amount: 25.00, fetchedAt: now)))
    }
}
