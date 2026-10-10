import SwiftUI
import Charts

/// Cost per time bucket, stacked by project, with a hover crosshair + tooltip.
struct StackedUsageChart: View {
    let stats: RangeStats
    let slots: [String: Int]
    var height: CGFloat = 150
    var compactAxis = false
    var showLegend = true
    @State private var hoverDate: Date?

    private var seriesOrder: [String] {
        let present = Set(stats.buckets.map(\.series))
        var order = slots.sorted { $0.value < $1.value }.map(\.key).filter(present.contains)
        if present.contains(StatsEngine.otherKey) { order.append(StatsEngine.otherKey) }
        return order
    }

    private func name(_ series: String) -> String {
        series == StatsEngine.otherKey ? "Other" : ProjectPath.name(of: series)
    }

    private var domain: ClosedRange<Date> {
        let iv = stats.interval
        let cal = Calendar.current
        let start = cal.dateInterval(of: stats.bucketUnit, for: iv.start)?.start ?? iv.start
        var end = cal.dateInterval(of: stats.bucketUnit, for: iv.end)?.end ?? iv.end
        if stats.range == .today { end = cal.day(iv.end, plus: 1) }
        return start...end
    }

    var body: some View {
        let order = seriesOrder
        VStack(alignment: .leading, spacing: 6) {
            if stats.buckets.isEmpty {
                EmptyHint(symbol: "chart.bar", text: "No usage in this period").frame(height: height)
            } else {
                Chart {
                    ForEach(stats.buckets) { b in
                        BarMark(x: .value("Time", b.date, unit: stats.bucketUnit),
                                y: .value("Cost", b.cost))
                            .foregroundStyle(by: .value("Project", b.series))
                            .cornerRadius(2)
                            .opacity(hoverDate == nil || sameBucket(hoverDate!, b.date) ? 1 : 0.45)
                    }
                    if let hoverDate {
                        RuleMark(x: .value("Time", hoverDate, unit: stats.bucketUnit))
                            .foregroundStyle(Color.primary.opacity(0.08))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .zIndex(-1)
                            .annotation(position: .top, alignment: .center, spacing: 2,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(for: hoverDate, order: order)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: order, range: order.map { Palette.series(slots[$0]) })
                .chartLegend(.hidden)
                .chartXScale(domain: domain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: compactAxis ? 6 : 7)) { v in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: axisFormat)
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(Fmt.money(d, compact: true)).font(.system(size: 9)) }
                        }
                    }
                }
                .chartXSelection(value: $hoverDate)
                .frame(height: height)

                if showLegend && order.count > 1 {
                    legend(order)
                }
            }
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch stats.bucketUnit {
        case .hour: return .dateTime.hour(.defaultDigits(amPM: .narrow))
        case .weekOfYear: return .dateTime.month(.abbreviated).day()
        default: return stats.range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month(.defaultDigits).day()
        }
    }

    private func sameBucket(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, equalTo: b, toGranularity: stats.bucketUnit)
    }

    @ViewBuilder
    private func tooltip(for date: Date, order: [String]) -> some View {
        let items = stats.buckets.filter { sameBucket($0.date, date) }
        let total = items.reduce(0) { $0 + $1.cost }
        VStack(alignment: .leading, spacing: 3) {
            Text(date, format: stats.bucketUnit == .hour ? .dateTime.weekday().hour() : .dateTime.weekday().month().day())
                .font(.system(size: 10, weight: .semibold))
            ForEach(order.filter { s in items.contains { $0.series == s } }, id: \.self) { s in
                let b = items.first { $0.series == s }!
                HStack(spacing: 5) {
                    ColorDot(color: Palette.series(slots[s]), size: 6)
                    Text(name(s)).font(.system(size: 10))
                    Spacer(minLength: 8)
                    Text(Fmt.money(b.cost)).font(.system(size: 10)).monospacedDigit()
                }
            }
            if items.count > 1 {
                Divider()
                HStack { Text("Total").font(.system(size: 10, weight: .medium)); Spacer(); Text(Fmt.money(total)).font(.system(size: 10, weight: .medium)).monospacedDigit() }
            }
            if items.isEmpty { Text("No usage").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(7)
        .frame(minWidth: 130)
        .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 4, y: 1))
    }

    private func legend(_ order: [String]) -> some View {
        let totals = Dictionary(grouping: stats.buckets, by: \.series).mapValues { $0.reduce(0) { $0 + $1.cost } }
        return FlowLayout(spacing: 10, lineSpacing: 4) {
            ForEach(order, id: \.self) { s in
                HStack(spacing: 4) {
                    ColorDot(color: Palette.series(slots[s]), size: 7)
                    Text(name(s)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Fmt.money(totals[s] ?? 0, compact: true)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Wrapping horizontal layout for legends and chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: width, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}

struct UsageTab: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let s = store.rangeStats
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                StatTile(label: "Spend", value: Fmt.money(s.cost), sub: s.prevCost.map { "prev \(Fmt.money($0, compact: true))" }, delta: s.delta,
                         help: "API-equivalent cost vs the previous period of the same length")
                StatTile(label: "Tokens", value: Fmt.tokens(s.tokens), sub: "\(Fmt.tokens(s.output)) out")
                StatTile(label: "Claude time", value: Fmt.duration(s.activeMs / 1000), sub: "\(s.prompts) prompts",
                         help: "Wall-clock time Claude spent working on your turns")
                StatTile(label: "Sessions", value: "\(s.sessions)", sub: "\(Fmt.number(s.messages)) replies")
                StatTile(label: "Cache hit rate", value: Fmt.percent(s.cacheHitRate), sub: "saved \(Fmt.money(s.cacheSavings, compact: true))",
                         help: "Share of input served from prompt cache, and what those tokens would have cost uncached")
                StatTile(label: "Per prompt", value: s.prompts > 0 ? Fmt.money(s.cost / Double(s.prompts)) : "–",
                         sub: s.prompts > 0 ? "\(Fmt.tokens(s.tokens / max(s.prompts, 1))) tok" : nil)
            }

            Card {
                SectionHeader(title: "Spend by project", trailing: s.range.rawValue)
                StackedUsageChart(stats: s, slots: store.slots, height: 160)
            }

            Card {
                SectionHeader(title: "Where the tokens go")
                CompositionBar(parts: [
                    .init(id: "Cache read", value: Double(s.cacheRead), color: Palette.series[0], detail: Fmt.tokens(s.cacheRead)),
                    .init(id: "Cache write", value: Double(s.cacheWrite), color: Palette.series[1], detail: Fmt.tokens(s.cacheWrite)),
                    .init(id: "Output", value: Double(s.output), color: Palette.series[2], detail: Fmt.tokens(s.output)),
                    .init(id: "Fresh input", value: Double(s.input), color: Palette.series[3], detail: Fmt.tokens(s.input)),
                ])
                if s.thinking > 0 {
                    Text("\(Fmt.percent(Double(s.thinking) / Double(max(s.output, 1)))) of output was thinking (\(Fmt.tokens(s.thinking)))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            WastedCacheCard()

            HStack(spacing: 8) {
                StatTile(label: "Subagents", value: Fmt.percent(s.cost > 0 ? s.subagentCost / s.cost : 0), sub: Fmt.money(s.subagentCost),
                         help: "Share of spend from Task/Agent subagents")
                StatTile(label: "Web searches", value: "\(s.webSearches)")
                StatTile(label: "Fast mode", value: Fmt.money(s.fastCost), sub: s.fastCost > 0 ? Fmt.percent(s.fastCost / max(s.cost, 0.01)) : "unused")
            }

            Card {
                SectionHeader(title: "Top tools", trailing: "\(Fmt.number(s.tools.reduce(0) { $0 + $1.count })) calls")
                let top = Array(s.tools.prefix(8))
                if top.isEmpty { EmptyHint(symbol: "wrench.and.screwdriver", text: "No tool calls") }
                ForEach(top, id: \.name) { t in
                    BarListRow(label: t.name, value: Double(t.count), maxValue: Double(top.first?.count ?? 1),
                               valueText: Fmt.number(t.count))
                }
            }
        }
    }
}

/// Idle gaps let the prompt cache expire; the next reply pays to rewrite the whole context.
struct WastedCacheCard: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let rb = store.rebuilds
        let total = rb.reduce(0) { $0 + $1.premium }
        let bySession = Dictionary(grouping: rb, by: \.sessionId)
            .map { (id: $0.key, premium: $0.value.reduce(0) { $0 + $1.premium }, count: $0.value.count, project: $0.value[0].project) }
            .sorted { $0.premium > $1.premium }
        Card {
            SectionHeader(title: "🧊 Cache rebuilds after breaks", trailing: store.rangeStats.range.rawValue)
            if rb.isEmpty {
                Text("No expensive cache rebuilds — your cache stayed warm. Nice.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.money(total)).font(.system(size: 18, weight: .semibold))
                    Text("extra across \(rb.count) rebuild\(rb.count == 1 ? "" : "s") (\(Fmt.percent(total / max(store.rangeStats.cost, 0.01))) of spend)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Text("When you step away long enough for the prompt cache to expire, the next message rewrites the whole context at write prices instead of reading it at cache prices. Long-paused, huge sessions cost the most — consider /compact or a fresh session before a break.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                ForEach(bySession.prefix(4), id: \.id) { s in
                    HStack(spacing: 6) {
                        ColorDot(color: Palette.series(store.slots[s.project]), size: 6)
                        Text(store.snapshot.sessions[s.id]?.title ?? ProjectPath.name(of: s.project)).font(.system(size: 10.5)).lineLimit(1)
                        Spacer()
                        Text("\(s.count)×").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(Fmt.money(s.premium)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    }
                }
            }
        }
    }
}
