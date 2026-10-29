import Foundation

public enum Aggregation {
    /// Gaps longer than this are not counted as active time.
    public static let idleCutoff: TimeInterval = 5 * 60

    /// Origin per session id: Cowork if any record came from a desktop sandbox, "Code (app)" if the desktop app's Code tab
    /// owns the session (matched by `cliSessionId`), else plain Code.
    public static func origins(of records: [UsageRecord], meta: [String: SessionMeta]) -> [String: SessionOrigin] {
        var out: [String: SessionOrigin] = [:]
        for r in records {
            if out[r.sessionId] == .cowork { continue }
            out[r.sessionId] = r.origin == .cowork ? .cowork : (meta[r.sessionId]?.origin == .codeDesktop ? .codeDesktop : .code)
        }
        return out
    }

    public static func sessions(from records: [UsageRecord], pricing: PricingTable,
                                meta: [String: SessionMeta] = SessionMetadata.shared.snapshot()) -> [WorkSession] {
        let origins = origins(of: records, meta: meta)
        // The same response can appear in several files (e.g. resumed sessions): dedup across files too.
        var seen = Set<String>(); var unique: [UsageRecord] = []
        for r in records where seen.insert(r.messageId + "|" + r.requestId).inserted { unique.append(r) }

        return Dictionary(grouping: unique, by: \.sessionId).map { id, recs in
            let recs = recs.sorted { $0.timestamp < $1.timestamp }
            var usage = TokenUsage(), cost = 0.0, unpriced = false
            var byModel: [String: Int] = [:]
            for r in recs {
                usage += r.usage
                byModel[r.model, default: 0] += r.usage.total
                if let c = pricing.cost(model: r.model, usage: r.usage) { cost += c } else { unpriced = true }
            }
            var active: TimeInterval = 0
            for (a, b) in zip(recs, recs.dropFirst()) {
                let gap = b.timestamp.timeIntervalSince(a.timestamp)
                if gap <= idleCutoff { active += gap }
            }
            // Project = repo root with the most tokens in this session (a session can wander across subfolders).
            var byProject: [String: Int] = [:]
            for r in recs { byProject[ProjectResolver.shared.project(for: r.cwd), default: 0] += r.usage.total }
            let title = meta[id]?.title
            return WorkSession(id: id, project: byProject.max { $0.value < $1.value }?.key ?? "—",
                               origin: origins[id] ?? .code, title: (title?.isEmpty ?? true) ? nil : title,
                               start: recs.first!.timestamp, end: recs.last!.timestamp,
                               activeDuration: active, messages: recs.count, usage: usage,
                               costUSD: unpriced && cost == 0 ? nil : cost, tokensByModel: byModel,
                               dominantModel: byModel.max { $0.value < $1.value }?.key,
                               hasUnpricedModel: unpriced)
        }
    }

    public static func topByCost(_ s: [WorkSession], _ n: Int = 10) -> [WorkSession] {
        Array(s.filter { $0.costUSD != nil }.sorted { $0.costUSD! > $1.costUSD! }.prefix(n))
    }
    public static func mostRecent(_ s: [WorkSession], _ n: Int = 10) -> [WorkSession] {
        Array(s.sorted { $0.end > $1.end }.prefix(n))
    }
    public static func longest(_ s: [WorkSession], _ n: Int = 10) -> [WorkSession] {
        Array(s.sorted { $0.activeDuration > $1.activeDuration }.prefix(n))
    }

    /// cache read / (input + cache read + cache write); nil when there is no input at all.
    public static func cacheHitRate(_ u: TokenUsage) -> Double? {
        u.promptTokens > 0 ? Double(u.cacheRead) / Double(u.promptTokens) : nil
    }
}
