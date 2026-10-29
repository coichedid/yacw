import Foundation

public struct Projection: Equatable, Sendable {
    public var ratePerHour: Double
    /// Only set when exhaustion would happen before the window resets.
    public var exhaustsAt: Date?
    /// Whether the ETA deserves an alert (orange). When false the pace is shown in gray without an ETA.
    public var warn: Bool
    public init(ratePerHour: Double, exhaustsAt: Date?, warn: Bool = true) {
        self.ratePerHour = ratePerHour; self.exhaustsAt = exhaustsAt; self.warn = warn
    }
}

public struct DailyCost: Identifiable, Sendable { public var id: Date { day }; public var day: Date; public var costUSD: Double }
public struct Slice: Identifiable, Sendable { public var id: String { name }; public var name: String; public var tokens: Int }

public enum Insights {
    /// 5h window: pace averaged over the last 30 min (or since the window started, if younger), so an early spike cannot
    /// predict exhaustion. Not shown before `minElapsed` (15 min) of the window; the ETA only alerts when it falls before
    /// the reset AND usage is already above `alertAbove` percent. Otherwise the pace is plain information.
    public static func projection(samples: [HistorySample], current: LimitWindow, now: Date = Date(),
                                  windowLength: TimeInterval = 5 * 3600, minElapsed: TimeInterval = 900,
                                  lookback: TimeInterval = 1800, alertAbove: Double = 20) -> ProjectionState {
        let start = current.resetsAt.addingTimeInterval(-windowLength)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minElapsed else { return .tooEarly(elapsed: max(0, elapsed), need: minElapsed) }
        let recent = samples.filter { $0.ts >= start && now.timeIntervalSince($0.ts) <= lookback && abs($0.resetsAt.timeIntervalSince(current.resetsAt)) < 120 }
            .sorted { $0.ts < $1.ts }
        var baseTs = start, basePct = 0.0
        if elapsed > lookback {
            guard let a = recent.first, let b = recent.last, b.ts.timeIntervalSince(a.ts) >= 300 else { return .collecting(samples: recent.count) }
            baseTs = a.ts; basePct = a.percent
        }
        let rate = (current.usedPercent - basePct) / (now.timeIntervalSince(baseTs) / 3600)
        guard rate > 0 else { return .ready(Projection(ratePerHour: 0, exhaustsAt: nil)) }
        let eta = now.addingTimeInterval((100 - current.usedPercent) / rate * 3600)
        let before = eta < current.resetsAt
        return .ready(Projection(ratePerHour: rate, exhaustsAt: before ? eta : nil, warn: before && current.usedPercent > alertAbove))
    }

    /// Weekly window: pace averaged over the last 24h (or since the window started, if that is shorter), so one busy hour
    /// cannot predict exhaustion. Baseline = the latest same-window sample at or before `now - 24h`, else the window start
    /// at 0%. Not shown until `minElapsed` of the window has passed: a few hours of data say nothing about a 7-day budget.
    public static func weeklyProjection(samples: [HistorySample], current: LimitWindow, now: Date = Date(),
                                        windowLength: TimeInterval = 7 * 86_400,
                                        minElapsed: TimeInterval = 12 * 3600) -> ProjectionState {
        let start = current.resetsAt.addingTimeInterval(-windowLength)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minElapsed else { return .tooEarly(elapsed: max(0, elapsed), need: minElapsed) }
        var baseTs = start, basePct = 0.0
        if elapsed > 86_400 {
            let target = now.addingTimeInterval(-86_400)
            let same = samples.filter { abs($0.resetsAt.timeIntervalSince(current.resetsAt)) < 120 && $0.ts >= start }
            if let b = same.filter({ $0.ts <= target }).max(by: { $0.ts < $1.ts }) { baseTs = b.ts; basePct = b.percent }
        }
        let hours = now.timeIntervalSince(baseTs) / 3600
        guard hours > 0 else { return .none }
        let rate = (current.usedPercent - basePct) / hours
        guard rate > 0 else { return .ready(Projection(ratePerHour: 0, exhaustsAt: nil)) }
        let eta = now.addingTimeInterval((100 - current.usedPercent) / rate * 3600)
        return .ready(Projection(ratePerHour: rate, exhaustsAt: eta < current.resetsAt ? eta : nil))
    }

    /// Cost per local day for the last `days` days (days with no cost are included as 0).
    public static func dailyCost(_ records: [UsageRecord], pricing: PricingTable, days: Int = 30,
                                 now: Date = Date(), calendar: Calendar = .current) -> [DailyCost] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: Double] = [:]
        for r in records {
            let d = calendar.startOfDay(for: r.timestamp)
            byDay[d, default: 0] += pricing.cost(model: r.model, usage: r.usage) ?? 0
        }
        return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { DailyCost(day: $0, costUSD: byDay[$0] ?? 0) }
    }

    public static func tokensByModel(_ records: [UsageRecord]) -> [Slice] {
        slices(Dictionary(grouping: records, by: \.model).mapValues { $0.reduce(0) { $0 + $1.usage.total } })
    }
    public static func tokensByProject(_ records: [UsageRecord]) -> [Slice] {
        slices(Dictionary(grouping: records, by: { ProjectResolver.shared.project(for: $0.cwd) })
            .mapValues { $0.reduce(0) { $0 + $1.usage.total } })
    }
    private static func slices(_ d: [String: Int]) -> [Slice] {
        d.map { Slice(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
    }

    /// weekday (0 = Sunday) × hour counts of responses, local time.
    public static func heatmap(_ records: [UsageRecord], calendar: Calendar = .current) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for r in records {
            let c = calendar.dateComponents([.weekday, .hour], from: r.timestamp)
            grid[(c.weekday ?? 1) - 1][c.hour ?? 0] += 1
        }
        return grid
    }

    public struct OffMacInterval: Identifiable, Sendable {
        public var id: Date { from }
        public var from: Date, to: Date
        /// % points above what the local cost explains.
        public var points: Double
        public var localCostUSD: Double
        public var deltaPercent: Double
    }

    public struct OffMacResult: Sendable {
        public enum Status: Equatable, Sendable {
            /// No samples from the account endpoint (source C): the statusLine only updates when this Mac responds.
            case unavailableWithoutEndpoint
            case insufficient(have: Int, need: Int)
            case ok
        }
        public var status: Status
        public var intervals: [OffMacInterval] = []
        /// Calibrated 5h-window points per local US$ (median over intervals with local cost).
        public var percentPerUSD: Double?
        public init(status: Status) { self.status = status }
    }

    /// HEURISTIC. Between consecutive account-endpoint samples of the same 5h window, compares the % increase with the
    /// local estimated cost of that interval. The %/US$ ratio is calibrated as the median over intervals that had local
    /// cost; an interval whose increase is >= 2 points and at least twice what the ratio explains is attributed to
    /// usage outside this Mac (other machine, chat web, mobile). Assumes a roughly constant %/US$ ratio; local cost is
    /// itself an underestimate (~9%), so small excesses are noise by design.
    public static func offMacActivity(samples: [HistorySample], records: [UsageRecord], pricing: PricingTable,
                                      minCalibration: Int = 10) -> OffMacResult {
        let s = samples.filter { $0.source == .usageEndpoint && $0.kind == .fiveHour }.sorted { $0.ts < $1.ts }
        guard s.count >= 2 else { return OffMacResult(status: .unavailableWithoutEndpoint) }
        let recs = records.sorted { $0.timestamp < $1.timestamp }
        func localCost(_ a: Date, _ b: Date) -> Double {
            var lo = 0, hi = recs.count
            while lo < hi { let m = (lo + hi) / 2; if recs[m].timestamp <= a { lo = m + 1 } else { hi = m } }
            var c = 0.0, i = lo
            while i < recs.count, recs[i].timestamp <= b { c += pricing.cost(model: recs[i].model, usage: recs[i].usage) ?? 0; i += 1 }
            return c
        }
        struct Obs { var a: Date; var b: Date; var delta: Double; var cost: Double }
        var obs: [Obs] = []
        for (x, y) in zip(s, s.dropFirst()) where abs(x.resetsAt.timeIntervalSince(y.resetsAt)) < 120 {
            let gap = y.ts.timeIntervalSince(x.ts)
            guard gap >= 60, gap <= 3 * 3600 else { continue }
            obs.append(Obs(a: x.ts, b: y.ts, delta: y.percent - x.percent, cost: localCost(x.ts, y.ts)))
        }
        let ratios = obs.filter { $0.delta > 0 && $0.cost >= 0.05 }.map { $0.delta / $0.cost }.sorted()
        guard ratios.count >= minCalibration else { return OffMacResult(status: .insufficient(have: ratios.count, need: minCalibration)) }
        let ratio = ratios[ratios.count / 2]
        var r = OffMacResult(status: .ok); r.percentPerUSD = ratio
        for o in obs where o.delta >= 2 {
            let excess = o.delta - ratio * o.cost
            if excess >= 2 && ratio * o.cost <= 0.5 * o.delta {
                r.intervals.append(OffMacInterval(from: o.a, to: o.b, points: excess, localCostUSD: o.cost, deltaPercent: o.delta))
            }
        }
        return r
    }

    public static func csv(_ sessions: [WorkSession]) -> String {
        var out = "session_id,project,model,start,end,active_minutes,messages,input,output,cache_read,cache_write,cost_usd_estimated\n"
        let f = ISO8601DateFormatter()
        func esc(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            out += [s.id, esc(s.project), s.dominantModel ?? "", f.string(from: s.start), f.string(from: s.end),
                    String(format: "%.1f", s.activeDuration / 60), "\(s.messages)", "\(s.usage.input)", "\(s.usage.output)",
                    "\(s.usage.cacheRead)", "\(s.usage.cacheWrite)", s.costUSD.map { String(format: "%.4f", $0) } ?? ""]
                .joined(separator: ",") + "\n"
        }
        return out
    }
}
