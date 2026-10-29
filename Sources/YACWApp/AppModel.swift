import Foundation
import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import YACWCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = MeterState()
    @Published var dashboard = Dashboard()
    @Published var loginItemEnabled = false
    @Published var notice: String?
    @Published var refreshMessage: String?
    @Published var refreshing = false
    @Published var sourceCEnabled: Bool { didSet { applySourceC() } }
    /// Text of the menu bar prefix: "Claude" (default) or "YACW".
    @Published var prefixName: String { didSet { UserDefaults.standard.set(prefixName, forKey: "prefixName") } }
    @Published var showPrefix: Bool { didSet { UserDefaults.standard.set(showPrefix, forKey: "showPrefix") } }
    /// Origin filter of the extended panel (nil = all).
    @Published var originFilter: SessionOrigin? {
        didSet { UserDefaults.standard.set(originFilter?.rawValue, forKey: "originFilter"); recomputeDashboard() }
    }
    @Published var credits = CreditsState()
    /// Account endpoint URLs pasted by the user (UserDefaults only). Empty credits URL = derived from the usage URL.
    @Published var usageURLText: String { didSet { UserDefaults.standard.set(usageURLText, forKey: "usageURL") } }
    @Published var creditsURLText: String { didSet { UserDefaults.standard.set(creditsURLText, forKey: "creditsURL") } }
    /// Synthetic data only (no ~/.claude, no network): `--demo` launch argument or the Settings switch.
    @Published var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode"); applyDemo() } }
    @Published var showBalanceInBar: Bool { didSet { UserDefaults.standard.set(showBalanceInBar, forKey: "showBalanceInBar") } }
    /// Balance colors: yellow below `creditsYellow`, red below `creditsRed` (account currency units).
    @Published var creditsYellow: Double { didSet { UserDefaults.standard.set(creditsYellow, forKey: "creditsYellow") } }
    @Published var creditsRed: Double { didSet { UserDefaults.standard.set(creditsRed, forKey: "creditsRed") } }
    @Published var period: DashboardPeriod { didSet { UserDefaults.standard.set(period.rawValue, forKey: "period"); recomputeDashboard() } }

    private let coordinator: UpdateCoordinator
    private let endpoint: UsageEndpointProvider
    private let creditsService: CreditsService
    private let history: HistoryStore?
    private let pricing: PricingTable
    private var messageTask: Task<Void, Never>?

    init() {
        AppPaths.migrateLegacy()      // moves the pre-rename support folder (state.json, history…) once
        let loaded = try? PricingTable.load()
        pricing = loaded ?? PricingTable(source: "", fetchedOn: "", models: [:])
        if loaded == nil { notice = "Tabela de preços não encontrada no app: custos indisponíveis. Reinstale o YACW." }
        history = try? SQLiteHistoryStore()
        sourceCEnabled = UserDefaults.standard.bool(forKey: "sourceCEnabled")          // off by default
        prefixName = UserDefaults.standard.string(forKey: "prefixName") == "YACW" ? "YACW" : "Claude"
        showPrefix = UserDefaults.standard.object(forKey: "showPrefix") as? Bool ?? true     // on by default
        originFilter = UserDefaults.standard.string(forKey: "originFilter").flatMap(SessionOrigin.init(rawValue:))
        usageURLText = UserDefaults.standard.string(forKey: "usageURL") ?? ""
        creditsURLText = UserDefaults.standard.string(forKey: "creditsURL") ?? ""
        demoMode = CommandLine.arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "demoMode")
        showBalanceInBar = UserDefaults.standard.bool(forKey: "showBalanceInBar")          // off by default
        creditsYellow = UserDefaults.standard.object(forKey: "creditsYellow") as? Double ?? 25
        creditsRed = UserDefaults.standard.object(forKey: "creditsRed") as? Double ?? 10
        // Last known balance survives restarts so the popover is never blank (an amount, no credential).
        let ud = UserDefaults.standard
        let lastBalance = ud.string(forKey: "creditsCurrency").map {
            CreditBalance(currency: $0, amount: ud.double(forKey: "creditsAmount"), fetchedAt: Date(timeIntervalSince1970: ud.double(forKey: "creditsAt")))
        }
        creditsService = CreditsService(initial: lastBalance) {
            guard let url = ClaudeWebSession.configuredURL(credits: true) else {
                throw ProviderError.message("URL de créditos não configurada (Configurações)")
            }
            return try await ClaudeWebSession.shared.fetchUsage(url: url, label: "credits")
        }
        credits = CreditsState(balance: lastBalance)
        period = DashboardPeriod(rawValue: UserDefaults.standard.string(forKey: "period") ?? "") ?? .days30

        // Source C: opt-in. The transport runs a same-origin fetch inside the app's WKWebView (see WebSession).
        endpoint = UsageEndpointProvider(isEnabled: false) {
            guard let url = ClaudeWebSession.configuredURL(credits: false) else {
                throw ProviderError.message("URL da fonte C não configurada (Configurações)")
            }
            return try await ClaudeWebSession.shared.fetchUsage(url: url)
        }
        coordinator = UpdateCoordinator(
            entries: [.init(endpoint, minInterval: UpdateCoordinator.remoteMinGap, isRemote: true), .init(StatuslineProvider())],
            history: history, pricing: pricing)
        coordinator.onAlerts = { alerts in Notifier.send(alerts) }
        coordinator.onCompare = { CompareLog.append($0) }
        endpoint.isEnabled = sourceCEnabled
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        Notifier.requestAuthorization()
        if demoMode { loadDemo() } else { startPolling() }
    }

    private func startPolling() {
        let hist = history, pr = pricing
        coordinator.start { [model = self] st in
            Task { @MainActor in
                let p = model.period, o = model.originFilter
                let dash = await Task.detached { Dashboard.make(state: st, history: hist, pricing: pr, period: p, origin: o) }.value
                model.state = st; model.dashboard = dash
                await model.updateCredits(force: false)
            }
        }
    }

    private var demoMeta: [String: SessionMeta] = [:]

    private func loadDemo() {
        let d = DemoData.make(pricing: pricing)
        demoMeta = d.meta
        state = d.state; credits = d.credits
        dashboard = Dashboard.make(state: d.state, history: nil, pricing: pricing, period: period, origin: originFilter, meta: d.meta)
    }

    /// Switching demo on stops all polling (no reads of local logs, no network); switching it off resumes normal operation.
    private func applyDemo() {
        if demoMode {
            coordinator.stop(); loadDemo()
        } else {
            state = MeterState(); dashboard = Dashboard(); demoMeta = [:]
            credits = CreditsState(balance: storedBalance())
            startPolling()
        }
    }

    private func storedBalance() -> CreditBalance? {
        let ud = UserDefaults.standard
        return ud.string(forKey: "creditsCurrency").map {
            CreditBalance(currency: $0, amount: ud.double(forKey: "creditsAmount"), fetchedAt: Date(timeIntervalSince1970: ud.double(forKey: "creditsAt")))
        }
    }

    /// Credits are a second call to claude.ai through the same WebView: every 5 min, or at once on a manual refresh.
    /// Only while source C is on. The last known balance is kept on failure.
    func updateCredits(force: Bool) async {
        guard sourceCEnabled, !demoMode else { return }
        let st = await creditsService.refresh(force: force)
        guard st != credits else { return }
        credits = st
        if let b = st.balance {
            let ud = UserDefaults.standard
            ud.set(b.currency, forKey: "creditsCurrency"); ud.set(b.amount, forKey: "creditsAmount"); ud.set(b.fetchedAt.timeIntervalSince1970, forKey: "creditsAt")
        }
    }

    /// Flipping the switch takes effect immediately, in both directions: the provider is (de)activated, the remote
    /// backoff is cleared and a refresh runs now (C becomes the active source, or B takes over again).
    private func applySourceC() {
        UserDefaults.standard.set(sourceCEnabled, forKey: "sourceCEnabled")
        endpoint.isEnabled = sourceCEnabled
        sourceChanged()
    }

    /// After login ("Concluir") or after the switch changes: query source C now instead of waiting for the next cycle.
    func sourceChanged() {
        guard !demoMode else { return }
        coordinator.resetRemote()
        Task { await creditsService.reset(); await updateCredits(force: true) }
        refreshNow(manual: sourceCEnabled)
    }

    private func recomputeDashboard() {
        if demoMode { dashboard = Dashboard.make(state: state, history: nil, pricing: pricing, period: period, origin: originFilter, meta: demoMeta); return }
        let st = state, hist = history, pr = pricing, p = period, o = originFilter
        Task.detached { [model = self] in
            let dash = Dashboard.make(state: st, history: hist, pricing: pr, period: p, origin: o)
            await MainActor.run { model.dashboard = dash }
        }
    }

    /// Manual refresh gives feedback; with source C on it forces a new query (still >= 30s apart).
    func refreshNow(manual: Bool = false) {
        if demoMode { loadDemo(); return }
        let prevUpdated = state.updatedAt
        if manual { refreshing = true }
        Task.detached { [coordinator, history, pricing, model = self] in
            let p = await model.period, o = await model.originFilter
            let st = await coordinator.refresh(force: manual)
            if manual { await model.updateCredits(force: true) }
            let dash = Dashboard.make(state: st, history: history, pricing: pricing, period: p, origin: o)
            await MainActor.run {
                model.state = st; model.dashboard = dash
                if manual { model.refreshing = false; model.showRefreshResult(st, previous: prevUpdated) }
                // A throttled forced refresh retries by itself once the 30s minimum has passed.
                if manual, let wait = st.throttleRetryAfter {
                    Task { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); model.refreshNow(manual: true) }
                }
            }
        }
    }

    private func showRefreshResult(_ st: MeterState, previous: Date?) {
        var msg = "Atualizado."
        if let n = st.throttleNote { msg = n }
        else if case .active(let t) = st.endpoint { msg = "Fonte C consultada às \(Fmt.time(t))." }
        else if st.snapshot?.source == .statusLine, let u = st.updatedAt, u == previous {
            msg = "Sem dados novos desde \(Fmt.time(u)) — a fonte B só atualiza quando o Claude Code responde neste Mac."
        }
        refreshMessage = msg
        messageTask?.cancel()
        messageTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { refreshMessage = nil } }
    }

    func setPopoverOpen(_ open: Bool) { coordinator.popoverOpen = open; if open { refreshNow() } }

    func toggleLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            notice = nil
        } catch { notice = "Início no login indisponível: \(error.localizedDescription)" }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "yacw-sessoes.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Insights.csv(state.sessions).write(to: url, atomically: true, encoding: .utf8); notice = nil }
        catch { notice = "Falha ao exportar: \(error.localizedDescription)" }
    }

    /// Primary text color above the yellow threshold; yellow below `creditsYellow`, red below `creditsRed`.
    func creditsColor(_ amount: Double) -> Color {
        amount < creditsRed ? .red : (amount < creditsYellow ? Color(nsColor: .systemYellow) : .primary)
    }

    /// Label for the menu bar: "S 42% · W 18%", or an estimate when no percentage exists.
    var labelParts: [(String, Color)] {
        let ns = state.snapshot?.notStarted ?? []
        let s = state.snapshot?.fiveHour ?? (ns.contains(.fiveHour) ? LimitWindow(kind: .fiveHour, usedPercent: 0, resetsAt: .distantFuture) : nil)
        let w = state.snapshot?.sevenDay ?? (ns.contains(.sevenDay) ? LimitWindow(kind: .sevenDay, usedPercent: 0, resetsAt: .distantFuture) : nil)
        // Mid-gray reads on both light and dark menu bars (the label is rendered to a fixed, non-template image).
        let gray = Color(white: 0.62)
        let prefix: [(String, Color)] = showPrefix ? [(prefixName + " ", gray)] : []
        if s == nil && w == nil {
            if let e = state.estimatedWindow { return prefix + [("S ~\(Fmt.time(e.end))", gray)] }
            return prefix + [("S: — W: —", gray)]
        }
        var parts = prefix + [("S: " + (s.map { Fmt.percent($0.usedPercent) } ?? "—"), levelColor(s?.usedPercent)),
                              (" ", gray),
                              ("W: " + (w.map { Fmt.percent($0.usedPercent) } ?? "—"), levelColor(w?.usedPercent))]
        if showBalanceInBar, let b = credits.balance {
            parts += [(" ", gray), (Fmt.moneyWhole(b.amount, code: b.currency), creditsColor(b.amount))]
        }
        return parts
    }
}

/// Side-by-side percentages from source C and the statusLine file (only fresh pairs). No credentials involved.
enum CompareLog {
    static let url = AppPaths.file("compare.log")
    static func append(_ r: CompareRecord) {
        var lines = ""
        for w in r.windows {
            lines += "\(ISO8601DateFormatter().string(from: r.at)) \(w.kind == .fiveHour ? "5h" : "7d") C=\(w.c) B=\(w.b) delta=\(w.c - w.b) bAge=\(Int(r.bAge))s\n"
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(lines.utf8)); try? h.close() }
        else { try? lines.write(to: url, atomically: true, encoding: .utf8) }
    }
}

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }  // notifications need a bundle

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func send(_ alerts: [MeterAlert]) {
        guard available else { return }
        for a in alerts {
            let c = UNMutableNotificationContent(); c.title = a.title; c.body = a.body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
        }
    }
}
