import Foundation

public struct MeterAlert: Equatable, Sendable { public var id: String; public var title: String; public var body: String }

/// Decides which notifications to send. Pure logic; delivery happens in the app.
/// The first snapshot only seeds the state (no alerts for thresholds already crossed before launch).
public final class AlertEngine: @unchecked Sendable {
    public static let levels = [50, 75, 90]
    private var lastPercent: [LimitWindowKind: Double] = [:]
    private var lastReset: [LimitWindowKind: Date] = [:]
    private var notified: Set<String> = []
    public init() {}

    public func evaluate(_ snap: UsageSnapshot) -> [MeterAlert] {
        var alerts: [MeterAlert] = []
        for w in [snap.fiveHour, snap.sevenDay].compactMap({ $0 }) {
            let name = w.kind == .fiveHour ? "Limite de 5h" : "Limite semanal"
            defer { lastPercent[w.kind] = w.usedPercent; lastReset[w.kind] = w.resetsAt }
            guard let prev = lastPercent[w.kind], let prevReset = lastReset[w.kind] else { continue }  // seed
            if w.resetsAt.timeIntervalSince(prevReset) > 120 && w.usedPercent < prev {
                if w.kind == .fiveHour {
                    alerts.append(MeterAlert(id: "reset-\(w.resetsAt.timeIntervalSince1970)", title: "Janela de 5h renovada",
                                             body: "O limite de 5h foi renovado (\(Int(w.usedPercent))% usado)."))
                }
                continue
            }
            for lvl in Self.levels where prev < Double(lvl) && w.usedPercent >= Double(lvl) {
                let id = "\(w.kind.rawValue)-\(Int(w.resetsAt.timeIntervalSince1970))-\(lvl)"
                if notified.insert(id).inserted {
                    alerts.append(MeterAlert(id: id, title: "\(name): \(lvl)%", body: "Uso em \(Int(w.usedPercent))%."))
                }
            }
        }
        return alerts
    }
}
