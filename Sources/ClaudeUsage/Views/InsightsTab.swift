import SwiftUI
import Charts

struct InsightsTab: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let all = store.allStats
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatTile(label: "Current streak", value: "\(store.game.streak)d", sub: "longest \(store.game.longestStreak)d")
                StatTile(label: "Active days", value: "\(store.streaks.activeDays)",
                         sub: store.snapshot.events.first.map { "since \($0.time.formatted(.dateTime.month(.abbreviated).day()))" })
                StatTile(label: "Busiest day", value: Fmt.money(store.streaks.busiestDay?.cost ?? 0, compact: true),
                         sub: store.streaks.busiestDay?.date.formatted(.dateTime.month(.abbreviated).day()))
            }

            Card {
                SectionHeader(title: "Daily activity", trailing: "last 20 weeks")
                CalendarHeatmap(daily: store.daily, weeks: 20)
            }

            Card {
                SectionHeader(title: "When you work with Claude", trailing: "all time · by spend")
                PunchCard(grid: all.punchcard)
            }

            Card {
                SectionHeader(title: "5-hour blocks", trailing: "last 14")
                BlocksChart(blocks: Array(store.blocks.suffix(14)), reference: store.blockReference)
            }

            if !store.snapshot.prs.isEmpty {
                Card(padding: 10) {
                    SectionHeader(title: "Pull requests opened with Claude", trailing: "\(store.snapshot.prs.count)")
                    ForEach(store.prCosts.prefix(8)) { c in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 10)).foregroundStyle(Palette.series[6])
                            LinkText(text: "\(c.pr.repo) #\(c.pr.number)", url: c.pr.url).font(.system(size: 11))
                            Spacer()
                            Text(Fmt.money(c.cost)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                                .help("Spend in this session since its previous PR (or since it started)")
                            Text(Fmt.duration(c.claudeMs / 1000, short: true)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing).help("Claude working time")
                            Text(Fmt.ago(c.pr.time)).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
                        }
                    }
                    if !store.prCosts.isEmpty {
                        let avg = store.prCosts.reduce(0) { $0 + $1.cost } / Double(store.prCosts.count)
                        Text("Average \(Fmt.money(avg)) per PR").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            Card {
                SectionHeader(title: "Fun facts", trailing: "all time")
                funFacts(all)
            }
        }
    }

    @ViewBuilder
    private func funFacts(_ s: RangeStats) -> some View {
        let words = Double(s.output) * 0.75
        let novels = words / 90_000
        let facts: [(String, String)] = [
            ("text.book.closed", "Claude wrote ~\(Fmt.tokens(Int(words))) words for you — about \(String(format: "%.0f", novels)) novels' worth."),
            ("arrow.triangle.2.circlepath", "\(Fmt.tokens(s.cacheRead)) tokens were re-read from cache, saving \(Fmt.money(s.cacheSavings, compact: true)) vs. uncached input."),
            ("clock", "Claude has spent \(Fmt.duration(s.activeMs / 1000)) working on your prompts."),
            ("hammer", "\(Fmt.number(s.tools.reduce(0) { $0 + $1.count })) tool calls; favourite is \(s.tools.first?.name ?? "—")."),
            ("dollarsign.circle", "Average prompt costs \(Fmt.money(s.cost / Double(max(s.prompts, 1)))) and triggers \(s.messages / max(s.prompts, 1)) model replies."),
        ]
        VStack(alignment: .leading, spacing: 7) {
            ForEach(facts, id: \.1) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: f.0).font(.system(size: 11)).foregroundStyle(Palette.accent).frame(width: 16)
                    Text(f.1).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// GitHub-style calendar: columns are weeks, rows are weekdays, one-hue sequential ramp.
struct CalendarHeatmap: View {
    let daily: [Date: Double]
    let weeks: Int
    @State private var hovered: Date?

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekday = (cal.component(.weekday, from: today) + 5) % 7  // Mon=0
        let start = cal.day(today, plus: -(weeks - 1) * 7 - weekday)
        let cuts = Self.cuts(daily.filter { $0.key >= start }.map(\.value))
        let level = { (v: Double) -> Int in v <= 0 ? -1 : cuts.filter { v > $0 }.count }

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 3) {
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(r % 2 == 0 ? ["M", "T", "W", "T", "F", "S", "S"][r] : " ")
                            .font(.system(size: 8)).foregroundStyle(.tertiary).frame(height: 15)
                    }
                }
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = cal.day(start, plus: w * 7 + d)
                            let v = daily[date] ?? 0
                            let lv = level(v)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(date > today ? Color.clear : (lv < 0 ? Palette.emptyCell : Palette.sequential[lv]))
                                .frame(width: 15, height: 15)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(hovered == date ? 0.6 : 0), lineWidth: 1))
                                .onHover { inside in hovered = inside ? date : (hovered == date ? nil : hovered) }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                if let h = hovered {
                    Text(h.formatted(.dateTime.weekday(.wide).month().day())).font(.system(size: 10, weight: .medium))
                    Text(Fmt.money(daily[h] ?? 0)).font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Hover a day for details").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("Less").font(.system(size: 9)).foregroundStyle(.tertiary)
                RoundedRectangle(cornerRadius: 2).fill(Palette.emptyCell).frame(width: 9, height: 9)
                ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(Palette.sequential[i]).frame(width: 9, height: 9) }
                Text("More").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
}

extension CalendarHeatmap {
    /// Quintile thresholds over active days, so the ramp spreads across your own range.
    static func cuts(_ raw: [Double]) -> [Double] {
        let values = raw.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [0, 0, 0, 0] }
        return [0.2, 0.4, 0.6, 0.8].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }
}

/// Weekday x hour bubbles sized by spend.
struct PunchCard: View {
    let grid: [[Double]]
    @State private var hovered: (Int, Int)?

    var body: some View {
        let maxV = max(grid.flatMap { $0 }.max() ?? 0, 0.0001)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 0) {
                    Text(days[d]).font(.system(size: 8.5)).foregroundStyle(.tertiary).frame(width: 24, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let v = grid[d][h]
                        let r = v > 0 ? 3 + 9 * sqrt(v / maxV) : 2
                        Circle()
                            .fill(v > 0 ? Palette.series[0].opacity(0.35 + 0.65 * sqrt(v / maxV)) : Palette.emptyCell)
                            .frame(width: r, height: r)
                            .frame(maxWidth: .infinity, minHeight: 14)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { hovered = (d, h) } }
                    }
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 24)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p")
                        .font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let (d, h) = hovered {
                Text("\(days[d]) \(h):00–\(h + 1):00 · \(Fmt.money(grid[d][h]))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let peak = peakSlot {
                Text("Peak: \(days[peak.0]) around \(peak.1 % 12 == 0 ? 12 : peak.1 % 12)\(peak.1 < 12 ? "am" : "pm")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onHover { if !$0 { hovered = nil } }
    }

    private var peakSlot: (Int, Int)? {
        var best: (Int, Int)? = nil, bv = 0.0
        for d in 0..<7 { for h in 0..<24 where grid[d][h] > bv { bv = grid[d][h]; best = (d, h) } }
        return best
    }
}

struct BlocksChart: View {
    let blocks: [UsageBlock]
    let reference: Double
    @State private var hover: Int?

    var body: some View {
        if blocks.isEmpty {
            EmptyHint(symbol: "clock", text: "No blocks yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Chart {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                        BarMark(x: .value("Block", i), y: .value("Cost", b.cost), width: .fixed(14))
                            .foregroundStyle(b.isActive(now: Date()) ? Palette.accent : Palette.series[0])
                            .cornerRadius(3)
                            .opacity(hover == nil || hover == i ? 1 : 0.45)
                    }
                    RuleMark(y: .value("Reference", reference))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .leading) {
                            Text("gauge 100% = \(Fmt.money(reference, compact: true))").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                }
                .chartXScale(domain: -0.5...(Double(blocks.count) - 0.5))
                .chartXAxis {
                    AxisMarks(values: Array(stride(from: 0, to: blocks.count, by: max(1, blocks.count / 5)))) { v in
                        AxisValueLabel {
                            if let i = v.as(Int.self), i < blocks.count {
                                Text(blocks[i].start, format: .dateTime.month(.defaultDigits).day()).font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.money(d, compact: true)).font(.system(size: 9)) } }
                    }
                }
                .chartXSelection(value: $hover)
                .frame(height: 110)
                if let h = hover, h >= 0, h < blocks.count {
                    let b = blocks[h]
                    Text("\(b.start.formatted(.dateTime.weekday().month().day().hour())) · \(Fmt.money(b.cost)) · \(b.messages) replies · \(Fmt.tokens(b.tokens)) tok")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        HStack(spacing: 4) { ColorDot(color: Palette.accent, size: 7); Text("current") }
                        HStack(spacing: 4) { ColorDot(color: Palette.series[0], size: 7); Text("past") }
                        Spacer()
                        Text("hover a bar for details").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
