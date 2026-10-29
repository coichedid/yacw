import SwiftUI
import YACWCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                header
                endpointBlock(now: ctx.date)
                if let s = model.state.snapshot, s.fiveHour != nil || s.sevenDay != nil || !s.notStarted.isEmpty {
                    if let w = s.fiveHour { meter("Limite de 5h", w, projection: model.state.projection5h, now: ctx.date) }
                    else if s.notStarted.contains(.fiveHour) { notStartedMeter("Limite de 5h") }
                    if let w = s.sevenDay { meter("Limite semanal (7 dias)", w, projection: model.state.projection7d, now: ctx.date) }
                    else if s.notStarted.contains(.sevenDay) { notStartedMeter("Limite semanal (7 dias)") }
                    degradedNote
                    if !s.breakdown.isEmpty {
                        Text("Semana por produto: " + s.breakdown.sorted { $0.percent > $1.percent }.filter { $0.percent >= 1 }
                            .map { "\($0.name) \(Fmt.percent($0.percent))" }.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    estimateBlock(now: ctx.date)
                }
                creditsBlock(now: ctx.date)
                if let h = model.dashboard.cacheHitRate { row("Acerto de cache", Fmt.percent(h * 100)) }
                row("Fora deste Mac (24h)", offMacText)
                    .help("Heurística: salto de % maior que o custo local explica. Só com a fonte C, que vê o uso da conta toda.")
                Divider()
                footer(now: ctx.date)
            }
            .padding(14)
            .frame(width: 350)
        }
        .onAppear { model.setPopoverOpen(true) }
        .onDisappear { model.setPopoverOpen(false) }
    }

    /// Balance first and large; spend as secondary text; the last known balance stays visible when a query fails.
    @ViewBuilder private func creditsBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Saldo").font(.subheadline)
                Spacer()
                if let b = model.credits.balance {
                    Text(Fmt.money(b.amount, code: b.currency)).font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundColor(model.creditsColor(b.amount))
                } else {
                    Text("indisponível").font(.subheadline).foregroundColor(.secondary)
                }
            }
            if let x = model.state.snapshot?.extraUsage {
                Text("\(Fmt.money(x.used, code: x.currency)) usados").font(.caption).foregroundColor(.secondary)
            }
            if !model.sourceCEnabled {
                Text(model.credits.balance == nil ? "Fonte C desligada: sem saldo." : "Fonte C desligada: saldo de \(Fmt.time(model.credits.balance!.fetchedAt, now: now)).")
                    .font(.caption).foregroundColor(.secondary)
            } else if let f = model.credits.failure {
                let since = model.credits.balance.map { " · desatualizado desde \(Fmt.time($0.fetchedAt, now: now))" } ?? ""
                Text(creditsFailureText(f) + since).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func creditsFailureText(_ f: ProviderError) -> String {
        switch f {
        case .sessionExpired: return "Saldo: sessão expirada"
        case .endpointChanged(let m): return "Saldo: o endpoint de créditos mudou (\(m))"
        case .offline: return "Saldo: sem conexão"
        case .message(let m): return m
        default: return "Saldo: consulta falhou"
        }
    }

    private var offMacText: String {
        switch model.dashboard.offMac.status {
        case .unavailableWithoutEndpoint: return "Indisponível sem a fonte C"
        case .insufficient(let h, let n): return "calibrando (\(h)/\(n))"
        case .ok: return "+\(Int((model.dashboard.offMacPoints24h ?? 0).rounded())) pts (estimado)"
        }
    }

    private var header: some View {
        HStack {
            Text("YACW").font(.headline)
            Spacer()
            statusChip
        }
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            if model.demoMode { return ("demonstração · dados fictícios", .purple) }
            switch model.state.status {
            case .ok(let k): return ("ok · \(k == .statusLine ? "Claude Code (B)" : "conta (C)")", .green)
            case .stale(_, let age): return ("desatualizado · \(Fmt.duration(age))", .orange)
            case .estimated: return ("estimado", .orange)
            case .error(let m): return ("erro · \(m)", .red)
            }
        }()
        return Text(text).font(.caption).foregroundColor(color).lineLimit(1)
    }

    /// Every state of source C is spelled out; none is silent.
    @ViewBuilder private func endpointBlock(now: Date) -> some View {
        switch model.state.endpoint {
        case .off:
            EmptyView()
        case .active(let t):
            Text("Fonte C ativa · consultada \(Fmt.time(t, now: now))").font(.caption).foregroundColor(.green)
        case .sessionExpired(let m):
            VStack(alignment: .leading, spacing: 4) {
                Text("Fonte C: sessão expirada ou sem login (\(m)). Usando a fonte B.").font(.caption).foregroundColor(.red)
                Button("Entrar de novo") { openLogin() }.controlSize(.small)
            }
        case .endpointChanged(let m):
            Text("Fonte C: o endpoint mudou (\(m)). Dados da C ignorados; usando a fonte B.").font(.caption).foregroundColor(.red)
        case .offline:
            Text("Fonte C: sem conexão com claude.ai. Usando a fonte B.").font(.caption).foregroundColor(.orange)
        case .error(let m):
            Text("Fonte C: erro (\(m)). Usando a fonte B.").font(.caption).foregroundColor(.red)
        }
    }

    private func meter(_ title: String, _ w: LimitWindow, projection: ProjectionState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(Fmt.percent(w.usedPercent)).font(.title3.monospacedDigit()).foregroundColor(levelColor(w.usedPercent))
            }
            ProgressView(value: min(w.usedPercent, 100), total: 100).tint(levelColor(w.usedPercent))
            Text("Renova \(Fmt.time(w.resetsAt, now: now)) · em \(Fmt.countdown(to: w.resetsAt, now: now))")
                .font(.caption).foregroundColor(.secondary)
            projectionLine(projection, weekly: w.kind == .sevenDay, now: now)
        }
    }

    /// `resets_at: null` from source C: legitimate, the window has not started.
    private func notStartedMeter(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("0%").font(.title3.monospacedDigit()).foregroundColor(levelColor(0))
            }
            ProgressView(value: 0, total: 100).tint(levelColor(0))
            Text("Começa na sua primeira mensagem").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var degradedNote: some View {
        ForEach(model.state.degraded.keys.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { k in
            let name = k == .fiveHour ? "5h" : "semanal"
            Text("Fonte C: janela \(name) inválida (\(model.state.degraded[k] ?? "")). "
                 + (model.state.filledFromB.contains(k) ? "Usando a fonte B para ela." : "Sem dado para ela."))
                .font(.caption).foregroundColor(.orange)
        }
    }

    private func rate(_ r: Double) -> String { String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",") + "%/h" }

    @ViewBuilder private func projectionLine(_ p: ProjectionState, weekly: Bool, now: Date) -> some View {
        projectionText(p, weekly: weekly, now: now).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func projectionText(_ p: ProjectionState, weekly: Bool, now: Date) -> some View {
        switch p {
        case .ready(let pr):
            if pr.warn, let eta = pr.exhaustsAt {
                Text("Ritmo \(rate(pr.ratePerHour)) · esgota ~\(Fmt.time(eta, now: now))").font(.caption).foregroundColor(.orange)
            } else {
                Text(pr.ratePerHour <= 0 ? "Sem consumo recente"
                     : (pr.exhaustsAt == nil ? "Ritmo \(rate(pr.ratePerHour)) · dura até a renovação" : "Ritmo \(rate(pr.ratePerHour))"))
                    .font(.caption).foregroundColor(.secondary)
            }
        case .collecting(let n):
            Text("Projeção: \(n) amostra(s) nos últimos 30 min, preciso de 2 com 5 min de intervalo. A fonte B só amostra quando o Claude Code responde.")
                .font(.caption).foregroundColor(.secondary)
        case .staleSource:
            Text("Projeção indisponível: fonte desatualizada.").font(.caption).foregroundColor(.secondary)
        case .tooEarly(let elapsed, let need):
            Text((weekly ? "Projeção semanal em " : "Projeção em ") + Fmt.duration(need - elapsed)).font(.caption).foregroundColor(.secondary)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private func estimateBlock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sem porcentagem real").font(.subheadline)
            if let e = model.state.estimatedWindow {
                Text("Janela de 5h estimada (só uso deste Mac): renova ~\(Fmt.time(e.end, now: now)), em \(Fmt.countdown(to: e.end, now: now)).")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Nenhuma janela de 5h ativa nos logs locais. Abra o Claude Code para o statusLine gravar os limites.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.subheadline); Spacer(); Text(v).font(.subheadline.monospacedDigit()).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }

    /// Yellow after 15 min, red after 60 min without a new reading.
    private func updatedColor(_ updated: Date?, now: Date) -> Color {
        guard let updated else { return .secondary }
        let age = now.timeIntervalSince(updated)
        return age > 3600 ? .red : (age > 900 ? Color(nsColor: .systemYellow) : .secondary)
    }

    /// Text field that flags a URL that would be rejected (wrong host or path) instead of failing silently later.
    private func urlField(_ title: String, _ text: Binding<String>, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: text).textFieldStyle(.roundedBorder).font(.caption)
            if !text.wrappedValue.isEmpty && EndpointURL.validate(text.wrappedValue) == nil {
                Text("URL inválida: precisa ser https://claude.ai/api/organizations/…").font(.caption2).foregroundColor(.red)
            } else if required && text.wrappedValue.isEmpty {
                Text("Cole a URL da chamada de uso (veja o README).").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func openLogin() { openWindow(id: "login"); NSApp.activate(ignoringOtherApps: true) }

    private func footer(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.state.updatedAt.map { "Atualizado \(Fmt.time($0, now: now))" } ?? "Sem atualização")
                    .font(.caption).foregroundColor(updatedColor(model.state.updatedAt, now: now))
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button("Atualizar") { model.refreshNow(manual: true) }.controlSize(.small).disabled(model.refreshing)
            }
            if let m = model.refreshMessage { Text(m).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            Button("Abrir painel estendido") { openWindow(id: "extended"); NSApp.activate(ignoringOtherApps: true) }
            DisclosureGroup("Configurações", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Fonte C: conta claude.ai (login neste app)", isOn: $model.sourceCEnabled).font(.caption).disabled(model.demoMode)
                    if model.sourceCEnabled && !model.demoMode {
                        urlField("URL de uso (https://claude.ai/api/organizations/…/usage)", $model.usageURLText, required: true)
                        urlField("URL de créditos (vazia = derivada da URL de uso)", $model.creditsURLText, required: false)
                        Button("Entrar / entrar de novo no claude.ai") { openLogin() }.controlSize(.small)
                    }
                    Toggle("Modo demonstração (dados fictícios, sem rede)", isOn: $model.demoMode).font(.caption)
                    Toggle("Mostrar prefixo na barra de menu", isOn: $model.showPrefix).font(.caption)
                    if model.showPrefix {
                        Picker("Prefixo", selection: $model.prefixName) {
                            Text("Claude").tag("Claude"); Text("YACW").tag("YACW")
                        }.pickerStyle(.segmented).font(.caption).frame(width: 200)
                    }
                    Toggle("Mostrar saldo na barra", isOn: $model.showBalanceInBar).font(.caption)
                    Stepper("Saldo amarelo abaixo de \(Int(model.creditsYellow))", value: $model.creditsYellow, in: 1...1000, step: 5)
                        .font(.caption).onChange(of: model.creditsYellow) { _, v in if model.creditsRed > v { model.creditsRed = v } }
                    Stepper("Saldo vermelho abaixo de \(Int(model.creditsRed))", value: $model.creditsRed, in: 0...1000, step: 5)
                        .font(.caption).onChange(of: model.creditsRed) { _, v in if model.creditsYellow < v { model.creditsYellow = v } }
                    Toggle("Iniciar no login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.toggleLoginItem($0) }))
                        .toggleStyle(.checkbox).font(.caption)
                    Button("Exportar CSV…") { model.exportCSV() }.controlSize(.small)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            HStack { Spacer(); Button("Sair") { NSApp.terminate(nil) }.controlSize(.small) }
            if let n = model.notice { Text(n).font(.caption).foregroundColor(.red) }
            if let w = model.state.pricingWarning { Text(w).font(.caption).foregroundColor(.orange) }
        }
    }
}
