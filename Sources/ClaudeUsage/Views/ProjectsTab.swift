import SwiftUI
import Charts

struct ProjectsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var expanded: String?

    var body: some View {
        let s = store.rangeStats
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "\(s.projects.count) projects", trailing: "\(Fmt.money(s.cost)) · \(s.range.rawValue)")
            if s.projects.isEmpty {
                Card { EmptyHint(symbol: "folder", text: "No project activity in this period") }
            }
            ForEach(s.projects) { p in
                ProjectCard(project: p, total: s.cost, isExpanded: expanded == p.path) {
                    withAnimation(.snappy(duration: 0.22)) { expanded = expanded == p.path ? nil : p.path }
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(UsageStore.self) private var store
    let project: ProjectStat
    let total: Double
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        let color = Palette.series(store.slots[project.path])
        let isLive = store.live.contains { $0.project == project.path }
        let isBusy = store.live.contains { $0.project == project.path && $0.isBusy }
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ColorDot(color: color, size: 9)
                        Text(project.name).font(.system(size: 12.5, weight: .semibold))
                        if isLive { PulsingDot(active: isBusy).help(isBusy ? "Claude is working here" : "Session open") }
                        Spacer()
                        Text(Fmt.money(project.cost)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.hairline)
                            Capsule().fill(color).frame(width: max(3, g.size.width * project.cost / max(total, 0.0001)))
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 10) {
                        Text(Fmt.percent(project.cost / max(total, 0.0001))).fontWeight(.medium)
                        Label("\(project.sessions.count)", systemImage: "rectangle.stack")
                        Label("\(project.prompts)", systemImage: "text.bubble")
                        Label(Fmt.duration(project.activeMs / 1000, short: true), systemImage: "timer")
                        Label(Fmt.tokens(project.tokens), systemImage: "number")
                        Spacer()
                        Text(Fmt.ago(project.lastActive))
                    }
                    .labelStyle(CompactLabel())
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    if project.spark.count > 1 {
                        Sparkline(values: project.spark, color: color).frame(height: 24)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded { details(color: color) }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private func details(color: Color) -> some View {
        Divider().opacity(0.5)
        HStack(spacing: 6) {
            Text(ProjectPath.pretty(project.path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            IconButton(symbol: "terminal", help: "Open in Terminal") { UsageStore.openInTerminal(project.path) }
            IconButton(symbol: "folder", help: "Reveal in Finder") { UsageStore.reveal(project.path) }
        }
        let models = project.models.sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Models")
            ForEach(models, id: \.key) { m in
                BarListRow(label: Pricing.displayName(m.key), value: m.value, maxValue: models.first?.value ?? 1,
                           valueText: Fmt.money(m.value), color: Palette.series(store.modelSlots[m.key]))
            }
        }
        let tools = project.tools.reduce(into: [String: Int]()) { $0[StatsEngine.toolGroup($1.key), default: 0] += $1.value }
            .sorted { $0.value > $1.value }.prefix(6)
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Top tools")
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(Array(tools), id: \.key) { t in Chip(text: "\(t.key) \(t.value)") }
                }
            }
        }
        let sessions = store.sessions(in: project.path).prefix(8)
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "Sessions", trailing: "right-click for actions")
            ForEach(Array(sessions)) { s in SessionLine(session: s, showProject: false) }
        }
    }
}

struct ModelsTab: View {
    @Environment(UsageStore.self) private var store
    @State private var hoverAngle: Double?

    var body: some View {
        let s = store.rangeStats
        VStack(alignment: .leading, spacing: 12) {
            Card {
                SectionHeader(title: "Spend by model", trailing: s.range.rawValue)
                if s.models.isEmpty {
                    EmptyHint(symbol: "cpu", text: "No model usage in this period")
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        donut(s).frame(width: 150, height: 150)
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(s.models.prefix(7)) { m in
                                HStack(spacing: 6) {
                                    ColorDot(color: Palette.series(store.modelSlots[m.model]))
                                    Text(Pricing.displayName(m.model)).font(.system(size: 11))
                                    Spacer()
                                    Text(Fmt.money(m.cost)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                                    Text(Fmt.percent(m.cost / max(s.cost, 0.0001))).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        .frame(width: 32, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }

            ForEach(s.models) { m in
                Card(padding: 10) {
                    HStack {
                        ColorDot(color: Palette.series(store.modelSlots[m.model]))
                        Text(Pricing.displayName(m.model)).font(.system(size: 12, weight: .semibold))
                        Text(m.model).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(Fmt.money(m.cost)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    HStack(spacing: 0) {
                        miniStat("Replies", Fmt.number(m.messages))
                        miniStat("Output", Fmt.tokens(m.output))
                        miniStat("Cache read", Fmt.tokens(m.cacheRead))
                        miniStat("Per reply", Fmt.money(m.cost / Double(max(m.messages, 1))))
                    }
                    let p = Pricing.price(for: m.model)
                    Text("List price $\(trim(p.input)) in · $\(trim(p.output)) out · $\(trim(p.cacheRead)) cache read per MTok")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func trim(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func donut(_ s: RangeStats) -> some View {
        let models = Array(s.models.prefix(6))
        let selected = selectedModel(models)
        return Chart(models) { m in
            SectorMark(angle: .value("Cost", m.cost), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(Palette.series(store.modelSlots[m.model]))
                .opacity(selected == nil || selected?.model == m.model ? 1 : 0.4)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $hoverAngle)
        .chartBackground { _ in
            VStack(spacing: 1) {
                if let m = selected {
                    Text(Pricing.displayName(m.model)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Fmt.money(m.cost)).font(.system(size: 15, weight: .semibold))
                } else {
                    Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Fmt.money(s.cost)).font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    private func selectedModel(_ models: [ModelStat]) -> ModelStat? {
        guard let a = hoverAngle else { return nil }
        var acc = 0.0
        for m in models { acc += m.cost; if a <= acc { return m } }
        return nil
    }
}
