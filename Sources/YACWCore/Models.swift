import Foundation

public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    /// Total cache writes; the 1h part (if reported) is in `cacheWrite1h`.
    public var cacheWrite = 0
    public var cacheWrite1h = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite; self.cacheWrite1h = cacheWrite1h
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var promptTokens: Int { input + cacheRead + cacheWrite }

    public static func += (l: inout TokenUsage, r: TokenUsage) {
        l.input += r.input; l.output += r.output; l.cacheRead += r.cacheRead
        l.cacheWrite += r.cacheWrite; l.cacheWrite1h += r.cacheWrite1h
    }
}

/// One deduplicated API response found in a Claude Code log.
public struct UsageRecord: Equatable, Sendable {
    public var sessionId: String
    public var messageId: String
    public var requestId: String
    public var timestamp: Date
    public var cwd: String?
    public var model: String
    public var usage: TokenUsage
    public var isSidechain: Bool
    /// Where the log was found (set by `LogIndex`): desktop sandboxes are Cowork, everything else Code.
    public var origin: SessionOrigin = .code
    public init(sessionId: String, messageId: String, requestId: String, timestamp: Date, cwd: String?,
                model: String, usage: TokenUsage, isSidechain: Bool = false) {
        self.sessionId = sessionId; self.messageId = messageId; self.requestId = requestId; self.timestamp = timestamp
        self.cwd = cwd; self.model = model; self.usage = usage; self.isSidechain = isSidechain
    }
}

/// A Claude Code working session (not to be confused with a `LimitWindow`).
public struct WorkSession: Sendable {
    public var id: String
    public var project: String
    public var origin: SessionOrigin = .code
    /// Label written by the desktop app (Cowork / Code tab); nil for CLI sessions.
    public var title: String?
    public var start: Date
    public var end: Date
    /// Time between consecutive records, ignoring gaps longer than the idle cutoff.
    public var activeDuration: TimeInterval
    public var messages: Int
    public var usage: TokenUsage
    public var costUSD: Double?
    public var tokensByModel: [String: Int]
    public var dominantModel: String?
    public var hasUnpricedModel: Bool
}

public enum LimitWindowKind: String, Sendable, Hashable { case fiveHour, sevenDay }

/// A rate-limit window (5h / 7d) as reported by a source.
public struct LimitWindow: Equatable, Sendable {
    public var kind: LimitWindowKind
    /// 0...100
    public var usedPercent: Double
    public var resetsAt: Date
    public init(kind: LimitWindowKind, usedPercent: Double, resetsAt: Date) {
        self.kind = kind; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct ExtraUsage: Equatable, Sendable {
    public var currency: String
    /// Amount in major units (e.g. 42.50 for 4250 minor units, exponent 2).
    public var used: Double
    public init(currency: String, used: Double) { self.currency = currency; self.used = used }
}

public enum SourceKind: String, Sendable { case statusLine, usageEndpoint, localEstimate }

public struct BreakdownRow: Equatable, Sendable {
    public var key: String, name: String, percent: Double
    public init(key: String, name: String, percent: Double) { self.key = key; self.name = name; self.percent = percent }
}

public struct UsageSnapshot: Sendable {
    public var source: SourceKind
    public var fetchedAt: Date
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    /// Optional per-model weekly windows. Hypothesis: same shape as `seven_day`; both were `null` in every sample.
    public var sevenDayOpus: LimitWindow?
    public var sevenDaySonnet: LimitWindow?
    public var extraUsage: ExtraUsage?
    /// Share of the 7-day window by product (`seven_day_breakdown.rows`: key, display_name, percent). Empty if absent.
    public var breakdown: [BreakdownRow] = []
    /// Windows the source reported with `resets_at: null` ("starts with your first message"): 0%, no reset time.
    public var notStarted: Set<LimitWindowKind> = []
    /// Windows whose data failed validation (field-level message). Only that window is degraded; the rest is kept.
    public var degraded: [LimitWindowKind: String] = [:]
    public init(source: SourceKind, fetchedAt: Date, fiveHour: LimitWindow? = nil, sevenDay: LimitWindow? = nil,
                sevenDayOpus: LimitWindow? = nil, sevenDaySonnet: LimitWindow? = nil, extraUsage: ExtraUsage? = nil) {
        self.source = source; self.fetchedAt = fetchedAt; self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus; self.sevenDaySonnet = sevenDaySonnet; self.extraUsage = extraUsage
    }
}

public protocol LimitsProvider: Sendable {
    func fetch() async throws -> UsageSnapshot
}
