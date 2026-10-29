import Foundation

public enum SourceStatus: Equatable, Sendable {
    case ok(SourceKind)
    case stale(SourceKind, age: TimeInterval)
    case estimated
    case error(String)
}

/// Health of source C (account endpoint). Every case is shown in the UI; none is silent.
public enum EndpointStatus: Equatable, Sendable {
    case off
    case active(lastSuccess: Date)
    case sessionExpired(String)
    case endpointChanged(String)
    case offline
    case error(String)
}

public enum ProjectionState: Equatable, Sendable {
    case none
    case ready(Projection)
    /// Fewer than 2 samples (spanning >= 5 min) in the last hour for this window.
    case collecting(samples: Int)
    case staleSource
    /// Weekly window younger than the minimum needed for a meaningful pace.
    case tooEarly(elapsed: TimeInterval, need: TimeInterval)
}

public struct CompareRecord: Sendable {
    public var at: Date
    public var bAge: TimeInterval
    public var windows: [(kind: LimitWindowKind, c: Double, b: Double)]
}

public struct MeterState: Sendable {
    public var snapshot: UsageSnapshot?
    public var status: SourceStatus = .error("sem dados")
    public var endpoint: EndpointStatus = .off
    public var updatedAt: Date?
    public var projection5h: ProjectionState = .none
    public var projection7d: ProjectionState = .none
    public var estimatedWindow: (start: Date, end: Date)?
    public var records: [UsageRecord] = []
    public var sessions: [WorkSession] = []
    public var pricingWarning: String?
    /// Per-window problems in source C's last answer (only that window is degraded); empty when all is well.
    public var degraded: [LimitWindowKind: String] = [:]
    /// Degraded windows that were filled from source B.
    public var filledFromB: Set<LimitWindowKind> = []
    /// Set when a manual refresh could not call the remote source yet (30s minimum between calls).
    public var throttleNote: String?
    /// Seconds until a throttled manual refresh may call the remote source.
    public var throttleRetryAfter: TimeInterval?
    public init() {}
}

/// Pulls limits from providers (first success wins; the remote source C goes first when enabled, the statusLine is the
/// fallback), falls back to the local estimate, records history, computes projections and alerts.
/// Polling: 60s (15s with popover open), per-source backoff on errors, remote source never called more than once every 30s.
public final class UpdateCoordinator: @unchecked Sendable {
    public struct Entry {
        public var provider: LimitsProvider
        public var minInterval: TimeInterval
        public var isRemote: Bool
        public init(_ provider: LimitsProvider, minInterval: TimeInterval = 0, isRemote: Bool = false) {
            self.provider = provider; self.minInterval = minInterval; self.isRemote = isRemote
        }
    }
    struct EntryState { var lastAttempt: Date?; var cache: UsageSnapshot?; var failures = 0 }

    public static let staleAfter: TimeInterval = 600
    public static let remoteMinGap: TimeInterval = 30

    private let entries: [Entry]
    private let logIndex: LogIndex
    private let history: HistoryStore?
    private let pricing: PricingTable
    private let alerts = AlertEngine()
    private let lock = NSLock()
    private var entryStates: [Int: EntryState] = [:]
    private var endpointStatus: EndpointStatus = .off
    private var lastSampleTs: [LimitWindowKind: Date] = [:]
    private var lastSamplePct: [LimitWindowKind: Double] = [:]
    private var lastCompared: Date?
    private var cachedSessions: (count: Int, sessions: [WorkSession])?
    private var failures = 0
    private var task: Task<Void, Never>?

    public var popoverOpen = false
    public var onAlerts: (([MeterAlert]) -> Void)?
    public var onCompare: ((CompareRecord) -> Void)?

    public init(entries: [Entry], logIndex: LogIndex = LogIndex(), history: HistoryStore?, pricing: PricingTable) {
        self.entries = entries; self.logIndex = logIndex; self.history = history; self.pricing = pricing
    }

    /// Call when the user signs in or flips the source C switch: clears the remote error backoff and cached reading so
    /// the next refresh queries source C right away (the 30s minimum between remote calls still applies).
    public func resetRemote() {
        sync {
            for (i, e) in entries.enumerated() where e.isRemote {
                entryStates[i]?.failures = 0; entryStates[i]?.cache = nil
            }
            failures = 0
        }
    }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    private func sessions(for records: [UsageRecord]) -> [WorkSession] {
        sync {
            if cachedSessions?.count != records.count { cachedSessions = (records.count, Aggregation.sessions(from: records, pricing: pricing)) }
            return cachedSessions!.sessions
        }
    }

    /// `force` is a manual refresh: it skips the polling cadence but still honors the 30s minimum between remote calls.
    public func refresh(now: Date = Date(), force: Bool = false) async -> MeterState {
        var state = MeterState()
        logIndex.refresh()
        let records = logIndex.records
        state.records = records
        state.sessions = sessions(for: records)
        state.pricingWarning = state.sessions.contains { $0.hasUnpricedModel } ? "Há modelos sem preço em pricing.json; custo parcial." : nil
        state.estimatedWindow = LocalEstimate.currentFiveHourWindow(records: records, now: now)

        var snap: UsageSnapshot?
        var lastError: String?
        var filled: Set<LimitWindowKind> = []
        for (i, e) in entries.enumerated() {
            // A switched-off source must never be served from its cache: turning C off falls back to B right away.
            if let ep = e.provider as? UsageEndpointProvider, !ep.isEnabled {
                sync { endpointStatus = .off; entryStates[i] = nil }
                continue
            }
            let st = sync { entryStates[i] ?? EntryState() }
            // A manual refresh skips the error backoff but never the 30s minimum between remote calls.
            let wait: TimeInterval = (st.failures > 0 && !(force && e.isRemote))
                ? min(max(e.minInterval, Self.remoteMinGap) * pow(2, Double(st.failures - 1)), 600)
                : (force && e.isRemote ? Self.remoteMinGap : e.minInterval)
            if let last = st.lastAttempt, now.timeIntervalSince(last) < wait {
                if e.isRemote && force {
                    let left = wait - now.timeIntervalSince(last)
                    state.throttleNote = "Aguarde \(Int(left) + 1)s: no máximo 1 consulta a cada 30s à fonte C."
                    state.throttleRetryAfter = left + 1
                }
                if st.failures == 0, let c = st.cache { snap = c; break }
                continue   // backing off: the problem is already visible in `endpointStatus`
            }
            do {
                var s = try await e.provider.fetch()
                if e.isRemote, !s.degraded.isEmpty { filled = await fillFromStatusline(&s, now: now) }
                sync { entryStates[i] = EntryState(lastAttempt: now, cache: s, failures: 0); if e.isRemote { endpointStatus = .active(lastSuccess: now) } }
                snap = s
                if e.isRemote { await compareWithStatusLine(c: s, now: now) }
                break
            } catch ProviderError.disabled {
                if e.isRemote { sync { endpointStatus = .off; entryStates[i] = nil } }
                continue
            } catch ProviderError.missingState {
                lastError = "state.json ainda não existe (abra o Claude Code)"
            } catch {
                sync {
                    var s = entryStates[i] ?? EntryState(); s.lastAttempt = now; s.failures += 1; entryStates[i] = s
                    if e.isRemote { endpointStatus = Self.classify(error) }
                }
                lastError = "\(error)"
            }
        }
        state.endpoint = sync { endpointStatus }

        if var s = snap {
            // Windows that already ended are dropped, like Claude Code does.
            if let w = s.fiveHour, w.resetsAt <= now { s.fiveHour = nil }
            if let w = s.sevenDay, w.resetsAt <= now { s.sevenDay = nil }
            state.snapshot = s
            state.degraded = s.degraded; state.filledFromB = filled
            let age = now.timeIntervalSince(s.fetchedAt)
            state.status = age > Self.staleAfter ? .stale(s.source, age: age) : .ok(s.source)
            state.updatedAt = s.fetchedAt
            recordHistory(s)
            if s.fiveHour == nil && s.sevenDay == nil && state.estimatedWindow != nil { state.status = .estimated }
            if let w = s.fiveHour { state.projection5h = projection(for: w, stale: age > Self.staleAfter, now: now) }
            if let w = s.sevenDay { state.projection7d = projection(for: w, stale: age > Self.staleAfter, now: now) }
            let a = alerts.evaluate(s)
            if !a.isEmpty { onAlerts?(a) }
            sync { failures = 0 }
        } else if state.estimatedWindow != nil {
            state.status = .estimated
            state.updatedAt = now
            sync { failures = 0 }
        } else {
            state.status = .error(lastError ?? "sem dados")
            sync { failures += 1 }
        }
        return state
    }

    static func classify(_ error: Error) -> EndpointStatus {
        switch error {
        case ProviderError.sessionExpired(let m): return .sessionExpired(m)
        case ProviderError.endpointChanged(let m): return .endpointChanged(m)
        case ProviderError.offline: return .offline
        case ProviderError.http(let c): return .error("HTTP \(c)")
        case ProviderError.message(let m): return .error(m)
        case let u as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(u.code): return .offline
        default: return .error("\(error)")
        }
    }

    private func projection(for w: LimitWindow, stale: Bool, now: Date) -> ProjectionState {
        if stale { return .staleSource }
        if w.kind == .sevenDay {
            guard let history, let smp = try? history.samples(since: now.addingTimeInterval(-8 * 86_400), kind: .sevenDay) else { return .none }
            return Insights.weeklyProjection(samples: smp, current: w, now: now)
        }
        guard let history, let smp = try? history.samples(since: now.addingTimeInterval(-5 * 3600), kind: w.kind) else { return .none }
        return Insights.projection(samples: smp, current: w, now: now)
    }

    /// A window that failed validation in C is taken from a fresh statusLine reading; the rest of C is kept.
    private func fillFromStatusline(_ s: inout UsageSnapshot, now: Date) async -> Set<LimitWindowKind> {
        var filled: Set<LimitWindowKind> = []
        for e in entries where !e.isRemote && e.provider is StatuslineProvider {
            guard let b = try? await e.provider.fetch(), now.timeIntervalSince(b.fetchedAt) <= Self.staleAfter else { continue }
            for kind in s.degraded.keys {
                let w = kind == .fiveHour ? b.fiveHour : b.sevenDay
                guard let w else { continue }
                if kind == .fiveHour { s.fiveHour = w } else { s.sevenDay = w }
                filled.insert(kind)
            }
        }
        return filled
    }

    /// Item 14: when C answered and the statusLine file is fresh, log both percentages side by side.
    private func compareWithStatusLine(c: UsageSnapshot, now: Date) async {
        guard let hook = onCompare else { return }
        for e in entries where !e.isRemote && e.provider is StatuslineProvider {
            guard let b = try? await e.provider.fetch(), now.timeIntervalSince(b.fetchedAt) <= 300,
                  sync({ lastCompared != b.fetchedAt }) else { continue }
            var rows: [(LimitWindowKind, Double, Double)] = []
            if let cw = c.fiveHour, let bw = b.fiveHour { rows.append((.fiveHour, cw.usedPercent, bw.usedPercent)) }
            if let cw = c.sevenDay, let bw = b.sevenDay { rows.append((.sevenDay, cw.usedPercent, bw.usedPercent)) }
            guard !rows.isEmpty else { continue }
            sync { lastCompared = b.fetchedAt }
            hook(CompareRecord(at: now, bAge: now.timeIntervalSince(b.fetchedAt), windows: rows.map { (kind: $0.0, c: $0.1, b: $0.2) }))
        }
    }

    /// Samples are stamped with the time the source observed them, so a stale file never fakes a flat rate.
    private func recordHistory(_ s: UsageSnapshot) {
        guard let history else { return }
        var batch: [HistorySample] = []
        for w in [s.fiveHour, s.sevenDay].compactMap({ $0 }) {
            let (lastTs, lastPct) = sync { (lastSampleTs[w.kind], lastSamplePct[w.kind]) }
            if let lastTs, s.fetchedAt <= lastTs { continue }
            if let lastTs, let lastPct, lastPct == w.usedPercent, s.fetchedAt.timeIntervalSince(lastTs) < 300 { continue }
            batch.append(HistorySample(ts: s.fetchedAt, kind: w.kind, percent: w.usedPercent, resetsAt: w.resetsAt, source: s.source))
            sync { lastSampleTs[w.kind] = s.fetchedAt; lastSamplePct[w.kind] = w.usedPercent }
        }
        if !batch.isEmpty { try? history.append(batch) }
    }

    public var nextDelay: TimeInterval {
        sync {
            let base: TimeInterval = popoverOpen ? 15 : 60
            return min(base * pow(2, Double(min(failures, 4))), 600)
        }
    }

    public func start(onUpdate: @escaping @Sendable (MeterState) -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                onUpdate(await self.refresh())
                try? await Task.sleep(nanoseconds: UInt64(self.nextDelay * 1_000_000_000))
            }
        }
    }
    public func stop() { task?.cancel() }
}
