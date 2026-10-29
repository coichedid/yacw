import SwiftUI
import Charts
import YACWCore

struct ExtendedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Picker("Período", selection: $model.period) {
                        ForEach(DashboardPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 240)
                    Text(model.dashboard.periodLabel).font(.callout).foregroundColor(.secondary)
                    Picker("Origem", selection: $model.originFilter) {
                        Text("Todas as origens").tag(SessionOrigin?.none)
                        ForEach(SessionOrigin.allCases) { Text($0.label).tag(SessionOrigin?.some($0)) }
                    }
                    .frame(width: 220)
                }
                Text("Só sessões com log local (Claude Code e Cowork neste Mac). Chats e Projects do claude.ai, tarefas agendadas na nuvem e uso em outras máquinas não deixam log aqui. Custo é estimado (tokens × tabela de preços) e fica ~9% abaixo do contabilizado pelo próprio Claude Code.")
                    .font(.caption).foregroundColor(.secondary)
                breakdownBlock
                ranking("Sessões mais caras", model.dashboard.topCost)
                ranking("Sessões mais recentes", model.dashboard.mostRecent)
                ranking("Sessões mais longas (duração ativa)", model.dashboard.longest)
                dailyChart
                HStack(alignment: .top, spacing: 24) {
                    slices("Tokens por modelo", model.dashboard.byModel.map { ($0.name.replacingOccurrences(of: "claude-", with: ""), $0.tokens) })
                    slices("Tokens por projeto", Array(model.dashboard.byProject.prefix(10)).map { ($0.name, $0.tokens) })
                }
                cacheBlock
                heatmap
                offMac
            }
            .padding(20)
        }
        .frame(minWidth: 820, minHeight: 640)
    }

    private func ranking(_ title: String, _ rows: [WorkSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if rows.isEmpty { Text("Sem dados.").foregroundColor(.secondary) } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Sessão", "Origem", "Projeto", "Modelo", "Início", "Duração", "Msgs", "Tokens", "Custo"], id: \.self) {
                            Text($0).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows, id: \.id) { s in
                        GridRow {
                            Text(s.title ?? s.project).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                            Text(s.origin.label)
                            Text(s.project).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                            Text(Fmt.shortModel(s.dominantModel)).lineLimit(1)
                            Text(Fmt.dateTime(s.start))
                            Text(Fmt.duration(s.activeDuration))
                            Text("\(s.messages)")
                            Text(Fmt.tokens(s.usage.total))
                            Text(Fmt.usd(s.costUSD) + (s.hasUnpricedModel ? " *" : ""))
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    /// Weekly share by product as reported by source C (`seven_day_breakdown.rows`), whole account, not just this Mac.
    @ViewBuilder private var breakdownBlock: some View {
        if let rows = model.state.snapshot?.breakdown, !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Janela semanal por produto (conta toda, fonte C)").font(.headline)
                Text(rows.sorted { $0.percent > $1.percent }.map { "\($0.name) \(Fmt.percent($0.percent))" }.joined(separator: " · "))
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custo diário (30 dias, estimado em US$)").font(.headline)
            Chart(model.dashboard.daily) { d in
                BarMark(x: .value("Dia", d.day, unit: .day), y: .value("US$", d.costUSD)).foregroundStyle(.blue)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine(); AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                }
            }
            .environment(\.locale, ptBR)
            .frame(height: 180)
        }
    }

    private func slices(_ title: String, _ items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            let maxV = Double(items.map(\.1).max() ?? 1)
            ForEach(items, id: \.0) { name, v in
                HStack {
                    Text(name).lineLimit(1).frame(width: 140, alignment: .leading)
                    GeometryReader { g in
                        Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width: g.size.width * Double(v) / maxV)
                    }.frame(height: 10)
                    Text(Fmt.tokens(v)).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cacheBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Acerto de cache").font(.headline)
            Text(model.dashboard.cacheHitRate.map { Fmt.percent($0 * 100) } ?? "—")
                .font(.title2.monospacedDigit())
            Text("cache read ÷ (input + cache write + cache read), todas as sessões locais.").font(.caption).foregroundColor(.secondary)
        }
    }

    private var heatmap: some View {
        let grid = model.dashboard.heatmap
        let maxV = Double(grid.flatMap { $0 }.max() ?? 1)
        let days = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Mapa de calor (respostas por dia × hora, hora local)").font(.headline)
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 2) {
                    Text(days[d]).font(.caption).frame(width: 30, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        Rectangle()
                            .fill(Color.accentColor.opacity(grid[d][h] == 0 ? 0.06 : 0.2 + 0.8 * Double(grid[d][h]) / maxV))
                            .frame(width: 22, height: 16)
                            .help("\(days[d]) \(h)h: \(grid[d][h]) respostas")
                    }
                }
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 32)
                ForEach(0..<24, id: \.self) { h in Text(h % 3 == 0 ? "\(h)" : "").font(.system(size: 9)).frame(width: 22) }
            }
        }
    }

    private var offMac: some View {
        let r = model.dashboard.offMac
        return VStack(alignment: .leading, spacing: 6) {
            Text("Atividade fora deste Mac (heurística)").font(.headline)
            Text("Compara o aumento do % da janela de 5h com o custo local do intervalo; salto grande com custo local pequeno é atribuído a outro lugar (outra máquina, chat web, celular). Calibração em %/US$ pelo histórico da fonte C. É estimativa.")
                .font(.caption).foregroundColor(.secondary)
            switch r.status {
            case .unavailableWithoutEndpoint:
                Text("Indisponível sem a fonte C.").foregroundColor(.secondary)
            case .insufficient(let h, let n):
                Text("Dados insuficientes: \(h) de \(n) intervalos calibráveis. Deixe a fonte C ativa por mais tempo.").foregroundColor(.secondary)
            case .ok:
                if let k = r.percentPerUSD { Text("Razão calibrada: \(String(format: "%.1f", k).replacingOccurrences(of: ".", with: ",")) pts de 5h por US$ local.").font(.caption) }
                if r.intervals.isEmpty { Text("Nenhum período suspeito nos últimos 30 dias.").foregroundColor(.secondary) }
                ForEach(r.intervals.suffix(10).reversed()) { i in
                    Text("\(Fmt.dateTime(i.from)) → \(Fmt.dateTime(i.to)): +\(Int(i.deltaPercent.rounded())) pts, \(Fmt.usd(i.localCostUSD)) local → ~\(Int(i.points.rounded())) pts fora")
                        .font(.callout.monospacedDigit())
                }
            }
        }
    }
}
