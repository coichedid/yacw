import Foundation
import SwiftUI
import YACWCore

let ptBR = Locale(identifier: "pt_BR")

enum Fmt {
    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "—" }
        let f = NumberFormatter(); f.locale = ptBR; f.numberStyle = .currency; f.currencyCode = "USD"
        return f.string(from: v as NSNumber) ?? "—"
    }
    static func money(_ v: Double, code: String) -> String {
        let f = NumberFormatter(); f.locale = ptBR; f.numberStyle = .currency; f.currencyCode = code
        return f.string(from: v as NSNumber) ?? "—"
    }
    /// Whole units, rounded down ("R$ 25" for 25.60): the label never overstates the balance.
    static func moneyWhole(_ v: Double, code: String) -> String {
        let f = NumberFormatter(); f.locale = ptBR; f.numberStyle = .currency; f.currencyCode = code
        f.maximumFractionDigits = 0; f.roundingMode = .down
        return f.string(from: v as NSNumber) ?? "—"
    }
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        let f = NumberFormatter(); f.locale = ptBR; f.maximumFractionDigits = 1
        if d >= 1e9 { return (f.string(from: d / 1e9 as NSNumber) ?? "") + " bi" }
        if d >= 1e6 { return (f.string(from: d / 1e6 as NSNumber) ?? "") + " mi" }
        if d >= 1e3 { return (f.string(from: d / 1e3 as NSNumber) ?? "") + " mil" }
        return "\(n)"
    }
    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)min") : "\(m)min"
    }
    static func time(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = ptBR
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE dd/MM HH:mm"
        return f.string(from: d)
    }
    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = ptBR; f.dateFormat = "dd/MM/yy HH:mm"; return f.string(from: d)
    }
    static func countdown(to d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "\(days)d \(h)h" }
        return h > 0 ? "\(h)h \(m)min" : "\(m)min"
    }
    static func shortModel(_ m: String?) -> String {
        guard let m else { return "—" }
        return m.replacingOccurrences(of: "claude-", with: "")
    }
}

/// green < 70, yellow 70–89, red >= 90 (SPEC).
func levelColor(_ p: Double?) -> Color {
    guard let p else { return .secondary }
    return p >= 90 ? .red : (p >= 70 ? .yellow : .green)
}
func levelNSColor(_ p: Double?) -> NSColor {
    guard let p else { return .secondaryLabelColor }
    return p >= 90 ? .systemRed : (p >= 70 ? .systemYellow : .systemGreen)
}
