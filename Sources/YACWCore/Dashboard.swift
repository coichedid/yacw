import Foundation

public enum DashboardPeriod: String, CaseIterable, Sendable, Identifiable {
    case days7, days30, all
    public var id: String { rawValue }
    public var title: String { switch self { case .days7: return "7 dias"; case .days30: return "30 dias"; case .all: return "Tudo" } }
    public func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .days7: return now.addingTimeInterval(-7 * 86_400)
        case .days30: return now.addingTimeInterval(-30 * 86_400)
        case .all: return nil
        }
    }
}

/// Everything the extended panel shows, precomputed off the main thread.
/// Rankings, tokens, heatmap and cache hit follow `period`; the daily chart is always the last 30 days.
public struct Dashboard: Sendable {
    public var period: DashboardPeriod = .days30
    public var periodLabel = ""
    public var topCost: [WorkSession] = []
    public var mostRecent: [WorkSession] = []
    public var longest: [WorkSession] = []
    public var daily: [DailyCost] = []
    public var byModel: [Slice] = []
    public var byProject: [Slice] = []
    public var heatmap: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var cacheHitRate: Double?
    public var offMac = Insights.OffMacResult(status: .unavailableWithoutEndpoint)
    /// Points attributed to outside use in the last 24h (nil unless the heuristic has enough data).
    public var offMacPoints24h: Double?
    public init() {}

    public static func make(state: MeterState, history: HistoryStore?, pricing: PricingTable,
                            period: DashboardPeriod = .days30, origin: SessionOrigin? = nil,
                            meta metaOverride: [String: SessionMeta]? = nil, now: Date = Date()) -> Dashboard {
        var d = Dashboard()
        d.period = period
        let cutoff = period.cutoff(now: now)
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "dd/MM/yyyy"
        d.periodLabel = cutoff.map { "Últimos \(period.title) (desde \(f.string(from: $0)))" } ?? "Todo o período"
        let meta = metaOverride ?? SessionMetadata.shared.snapshot(now: now)
        var recs = cutoff.map { c in state.records.filter { $0.timestamp >= c } } ?? state.records
        // Origin filter applies to rankings, tokens, heatmap and cache; the daily chart and off-Mac heuristic stay global.
        if let origin {
            let by = Aggregation.origins(of: state.records, meta: meta)
            recs = recs.filter { by[$0.sessionId] == origin }
        }
        // Sessions are rebuilt from the period's records, so costs and tokens reflect the selected period only.
        let sessions = Aggregation.sessions(from: recs, pricing: pricing, meta: meta)
        d.topCost = Aggregation.topByCost(sessions)
        d.mostRecent = Aggregation.mostRecent(sessions)
        d.longest = Aggregation.longest(sessions)
        d.daily = Insights.dailyCost(state.records, pricing: pricing, now: now)
        d.byModel = Insights.tokensByModel(recs)
        d.byProject = Insights.tokensByProject(recs)
        d.heatmap = Insights.heatmap(recs)
        d.cacheHitRate = Aggregation.cacheHitRate(sessions.reduce(into: TokenUsage()) { $0 += $1.usage })
        if let history, let s = try? history.samples(since: now.addingTimeInterval(-30 * 86_400), kind: .fiveHour) {
            d.offMac = Insights.offMacActivity(samples: s, records: state.records, pricing: pricing)
            if d.offMac.status == .ok {
                d.offMacPoints24h = d.offMac.intervals.filter { $0.to >= now.addingTimeInterval(-86_400) }.reduce(0) { $0 + $1.points }
            }
        }
        return d
    }
}
