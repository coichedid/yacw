import Foundation

public enum ProviderError: Error, Equatable {
    case missingState, stale, disabled, decoding(String)
    /// HTTP 401/403 or no login yet: the user must sign in again.
    case sessionExpired(String)
    /// The response no longer looks like the sample the decoder was modeled on.
    case endpointChanged(String)
    case offline
    case http(Int)
    case message(String)
}

/// Source B: reads the file written by `scripts/statusline-writer.py`.
/// Format of state.json: `{"updated_at": epoch, "rate_limits": {"five_hour": {"used_percentage", "resets_at"}, ...}}`
/// (rate_limits fields confirmed in the official statusLine docs; real-world payload not yet sampled).
public struct StatuslineProvider: LimitsProvider {
    public var url: URL
    public init(url: URL = AppPaths.file("state.json")) { self.url = url }

    public func fetch() async throws -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url) else { throw ProviderError.missingState }
        return try Self.decode(data)
    }

    public static func decode(_ data: Data) throws -> UsageSnapshot {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = (o["updated_at"] as? NSNumber)?.doubleValue,
              let rl = o["rate_limits"] as? [String: Any] else { throw ProviderError.decoding("state.json") }
        func window(_ key: String, _ kind: LimitWindowKind) -> LimitWindow? {
            guard let w = rl[key] as? [String: Any],
                  let p = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let r = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(kind: kind, usedPercent: p, resetsAt: Date(timeIntervalSince1970: r))
        }
        return UsageSnapshot(source: .statusLine, fetchedAt: Date(timeIntervalSince1970: updated),
                             fiveHour: window("five_hour", .fiveHour), sevenDay: window("seven_day", .sevenDay),
                             sevenDayOpus: nil, sevenDaySonnet: nil, extraUsage: nil)
    }
}

/// Source C decoder, modeled on docs/samples/usage-response*.example.json.
/// Only fields present in the samples are read. `seven_day_opus/sonnet` were null in both samples,
/// so the per-model windows are decoded optionally assuming the `seven_day` shape (unverified).
public enum UsageEndpointDecoder {
    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("usage response")
        }
        func window(_ key: String, _ kind: LimitWindowKind) -> LimitWindow? {
            if case .ok(let w) = parseWindow(o, key, kind) { return w }
            return nil
        }
        var extra: ExtraUsage?
        if let s = o["spend"] as? [String: Any], let u = s["used"] as? [String: Any],
           let minor = (u["amount_minor"] as? NSNumber)?.doubleValue,
           let cur = u["currency"] as? String, let exp = (u["exponent"] as? NSNumber)?.intValue {
            extra = ExtraUsage(currency: cur, used: minor / pow(10, Double(exp)))
        }
        var snap = UsageSnapshot(source: .usageEndpoint, fetchedAt: fetchedAt,
                             fiveHour: window("five_hour", .fiveHour), sevenDay: window("seven_day", .sevenDay),
                             sevenDayOpus: window("seven_day_opus", .sevenDay),
                             sevenDaySonnet: window("seven_day_sonnet", .sevenDay), extraUsage: extra)
        // Optional: malformed rows are skipped, the section may be absent.
        if let rows = (o["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] {
            snap.breakdown = rows.compactMap { r in
                guard let k = r["key"] as? String, let n = r["display_name"] as? String, let p = (r["percent"] as? NSNumber)?.doubleValue else { return nil }
                return BreakdownRow(key: k, name: n, percent: p)
            }
        }
        return snap
    }
}

extension UsageEndpointDecoder {
    enum WindowParse { case ok(LimitWindow), notStarted, invalid(String) }

    static func describe(_ v: Any?) -> String {
        switch v {
        case nil: return "ausente"
        case is NSNull: return "nulo"
        case is String: return "texto"
        case is NSNumber: return "número"
        case is [String: Any]: return "objeto"
        default: return "de outro tipo"
        }
    }

    /// `resets_at: null` is a legitimate state (window not started yet), not an endpoint change.
    static func parseWindow(_ o: [String: Any], _ key: String, _ kind: LimitWindowKind) -> WindowParse {
        guard let raw = o[key] else { return .invalid("\(key) ausente") }
        guard let w = raw as? [String: Any] else { return .invalid("\(key) \(describe(raw)), esperado objeto") }
        guard let r = w["resets_at"] else { return .invalid("\(key).resets_at ausente") }
        if r is NSNull { return .notStarted }
        guard let rs = r as? String, let date = LogParser.parseDate(rs) else {
            return .invalid("\(key).resets_at \(describe(r)), esperado data ISO")
        }
        let uAny = w["utilization"]
        guard let u = (uAny as? NSNumber)?.doubleValue else { return .invalid("\(key).utilization \(describe(uAny)), esperado número") }
        guard u >= 0, u <= 100 else { return .invalid("\(key).utilization fora de 0–100") }
        return .ok(LimitWindow(kind: kind, usedPercent: u, resetsAt: date))
    }

    /// Used for live responses. Structural failures (invalid JSON, both windows unusable) throw `endpointChanged`
    /// naming the field and whether it was null or another type; a single bad window only degrades that window.
    public static func decodeStrict(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.endpointChanged("resposta não é um objeto JSON")
        }
        var snap: UsageSnapshot
        do { snap = try decode(data, fetchedAt: fetchedAt) } catch { throw ProviderError.endpointChanged("decodificação falhou") }
        var bad: [String] = []
        for (key, kind) in [("five_hour", LimitWindowKind.fiveHour), ("seven_day", .sevenDay)] {
            switch parseWindow(o, key, kind) {
            case .ok: break
            case .notStarted: snap.notStarted.insert(kind)
            case .invalid(let m): snap.degraded[kind] = m; bad.append(m)
            }
        }
        if snap.degraded.count == 2 { throw ProviderError.endpointChanged(bad.joined(separator: "; ")) }
        return snap
    }
}

/// Source C provider. Disabled by default: the endpoint URL and credential handling are not
/// confirmed yet, so the transport is injected by the caller instead of hardcoded here.
public final class UsageEndpointProvider: LimitsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    public var transport: @Sendable () async throws -> Data

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    public init(isEnabled: Bool = false, transport: @escaping @Sendable () async throws -> Data) {
        self.enabled = isEnabled; self.transport = transport
    }

    public func fetch() async throws -> UsageSnapshot {
        guard isEnabled else { throw ProviderError.disabled }
        return try UsageEndpointDecoder.decodeStrict(try await transport())
    }
}
