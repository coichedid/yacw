import Foundation
import YACWCore
import YACWSelfTest

// Prints rankings from local Claude Code logs. Read-only. `yacw-cli selftest` runs the checks.
if CommandLine.arguments.dropFirst().first == "selftest" { exit(try SelfTest.run()) }
let pricing = try PricingTable.load()
let index = LogIndex()
index.refresh()
let records = index.records
let sessions = Aggregation.sessions(from: records, pricing: pricing)

func line(_ s: WorkSession) -> String {
    let cost = s.costUSD.map { String(format: "$%.2f", $0) } ?? "n/d"
    return String(format: "%@  %-28@  %-18@  %4d msgs  %6.0f min  %@",
                  ISO8601DateFormatter().string(from: s.start), String(s.project.prefix(28)) as NSString,
                  (s.dominantModel ?? "-") as NSString, s.messages, s.activeDuration / 60, cost)
}
if CommandLine.arguments.dropFirst().first == "origins" {
    // Metadata only: counts and dates per origin, plus the sessions of the last 7 days.
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
    for o in SessionOrigin.allCases {
        let ss = sessions.filter { $0.origin == o }
        print("\(o.label): \(ss.count) sessões, \(ss.filter { $0.title != nil }.count) com título, mais recente: \(ss.map(\.end).max().map(f.string) ?? "—"), últimos 7 dias: \(ss.filter { $0.end > Date().addingTimeInterval(-7 * 86400) }.count)")
    }
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "projects" {
    print("Raízes de log:"); index.activeRoots.forEach { print("  \($0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") }
    print("Respostas únicas: \(records.count), sessões: \(sessions.count), sidechains: \(records.filter(\.isSidechain).count)")
    let chart = Dictionary(uniqueKeysWithValues: Insights.tokensByProject(records).map { ($0.name, $0.tokens) })
    var list: [String: Int] = [:]
    for s in sessions { list[s.project, default: 0] += s.usage.total }
    print("\n\("projeto".padding(toLength: 26, withPad: " ", startingAt: 0)) lista(sessões) mi   gráfico mi")
    for k in Set(chart.keys).union(list.keys).sorted(by: { (list[$0] ?? 0) > (list[$1] ?? 0) }) {
        print("\(k.padding(toLength: 26, withPad: " ", startingAt: 0)) \(String(format: "%14.1f %12.1f", Double(list[k] ?? 0) / 1e6, Double(chart[k] ?? 0) / 1e6))")
    }
    print(String(format: "\ntotal lista %.1f mi, total gráfico %.1f mi", Double(list.values.reduce(0, +)) / 1e6, Double(chart.values.reduce(0, +)) / 1e6))
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "compare" {
    // Summarizes ~/Library/Application Support/YACW/compare.log (written by the app when source C and a fresh
    // statusLine reading exist at the same time). `--record` appends the summary to docs/DECISIONS.md.
    let url = AppPaths.file("compare.log")
    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
        print("Sem pares C×B ainda: ligue a fonte C, faça login e use o Claude Code (o par só é gravado com state.json recente)."); exit(0)
    }
    var out: [String] = []
    for w in ["5h", "7d"] {
        let deltas = text.split(separator: "\n").filter { $0.contains(" \(w) ") }.compactMap { l -> Double? in
            l.split(separator: " ").first { $0.hasPrefix("delta=") }.flatMap { Double($0.dropFirst(6)) }
        }
        guard !deltas.isEmpty else { continue }
        let mean = deltas.reduce(0, +) / Double(deltas.count), mx = deltas.map { abs($0) }.max()!
        out.append(String(format: "%@: %d pares, diferença média C−B %+.2f pt, máxima |Δ| %.1f pt", w, deltas.count, mean, mx))
    }
    out.forEach { print($0) }
    if CommandLine.arguments.contains("--record"), !out.isEmpty {
        let f = ISO8601DateFormatter().string(from: Date())
        let line = "- Conferência fonte C × B (\(f)): " + out.joined(separator: "; ") + ".\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "docs/DECISIONS.md")) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close(); print("registrado em docs/DECISIONS.md") }
    }
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "status" {
    let coord = UpdateCoordinator(entries: [.init(StatuslineProvider())], logIndex: index, history: try? SQLiteHistoryStore(), pricing: pricing)
    let st = await coord.refresh()
    print("status: \(st.status)")
    print("5h: \(st.snapshot?.fiveHour.map { "\($0.usedPercent)% reset \($0.resetsAt)" } ?? "—")")
    print("projeção 5h: \(st.projection5h)")
    print("projeção 7d: \(st.projection7d)")
    exit(0)
}
print("Sessões: \(sessions.count), respostas únicas: \(records.count)")
print("\n== Mais caras"); Aggregation.topByCost(sessions).forEach { print(line($0)) }
print("\n== Mais recentes"); Aggregation.mostRecent(sessions).forEach { print(line($0)) }
print("\n== Mais longas"); Aggregation.longest(sessions).forEach { print(line($0)) }
let total = sessions.reduce(into: TokenUsage()) { $0 += $1.usage }
if let h = Aggregation.cacheHitRate(total) { print(String(format: "\nCache hit: %.1f%%", h * 100)) }
