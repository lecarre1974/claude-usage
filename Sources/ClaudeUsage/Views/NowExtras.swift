import SwiftUI
import Charts

// MARK: - Plan limits (real numbers from Anthropic)

struct PlanLimitsCard: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let p = store.plan
        if !p.limits.isEmpty {
            Card(padding: 11) {
                SectionHeader(title: "Plan limits" + (p.plan.map { " · \($0)" } ?? ""),
                              trailing: p.fetchedAt.map { "updated \(Fmt.ago($0))" })
                ForEach(p.limits) { l in LimitBar(limit: l) }
                if let err = p.error {
                    Label(err, systemImage: "exclamationmark.triangle").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LimitBar: View {
    let limit: PlanLimit
    var body: some View {
        let f = limit.percent / 100
        let color = f >= 0.9 ? Palette.critical : f >= 0.7 ? Palette.serious : Palette.series[0]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if f >= 0.9 { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.critical).font(.system(size: 10)) }
                else if f >= 0.7 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.serious).font(.system(size: 10)) }
                Text(limit.label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                if let r = limit.resetsAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("resets \(r.timeIntervalSinceNow < 86400 ? "in " + Fmt.duration(r.timeIntervalSinceNow, short: true) : r.formatted(.dateTime.weekday().hour()))")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(f, 1)))
                }
            }
            .frame(height: 6)
        }
    }
}

/// First-run opt-in for plan limits (they need Claude Code's login from the Keychain).
struct PlanLimitsOptIn: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.planLimits) private var planLimits = false
    @AppStorage(Prefs.planLimitsAsked) private var asked = false

    var body: some View {
        if !planLimits && !asked && !UsageStore.isSandboxed {
            Card(padding: 11) {
                HStack(alignment: .top, spacing: 10) {
                    Text("📊").font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("See your real plan limits?").font(.system(size: 12, weight: .semibold))
                        Text("Shows the same 5-hour and weekly % as /usage. To do that, Claude Usage reads Claude Code's login from your Keychain and asks api.anthropic.com — nothing else is sent, and your login is never changed. The endpoint is unofficial and may stop working.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Turn on") {
                                planLimits = true; asked = true
                                Task { await store.refreshPlan() }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("No thanks") { asked = true }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Waiting on you

struct WaitingSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let waiting = store.waiting
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "⏳ Waiting on you", trailing: "\(waiting.count) idle · click to jump")
                Card(padding: 8) {
                    ForEach(waiting) { s in WaitingRow(live: s) }
                }
            }
        }
    }
}

struct WaitingRow: View {
    @Environment(UsageStore.self) private var store
    let live: LiveSession
    @State private var hover = false

    var body: some View {
        let summary = store.session(for: live)
        Button { UsageStore.focus(pid: live.pid) } label: {
            HStack(spacing: 8) {
                ColorDot(color: Palette.series(store.slots[live.project]), size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProjectPath.name(of: live.project)).font(.system(size: 11.5, weight: .semibold))
                    Text(summary?.title ?? live.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let w = Date().timeIntervalSince(live.statusUpdatedAt)
                    Text(Fmt.duration(w, short: true))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(w > 3600 ? .secondary : Palette.accent)
                }
                Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Palette.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Bring this session's terminal to the front")
    }
}

// MARK: - Context meter

struct ContextMeter: View {
    let session: SessionSummary
    var body: some View {
        let f = session.contextFraction
        let color = f >= 0.85 ? Palette.critical : f >= 0.7 ? Palette.serious : Palette.series[2]
        HStack(spacing: 6) {
            Image(systemName: "brain").font(.system(size: 9)).foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline)
                    Capsule().fill(color).frame(width: max(3, g.size.width * min(f, 1)))
                }
            }
            .frame(height: 5)
            Text("\(Fmt.tokens(session.context ?? 0)) / \(Fmt.tokens(session.contextWindow ?? 0))")
                .font(.system(size: 9.5)).foregroundStyle(.secondary).monospacedDigit()
            if f >= 0.85 {
                Text("compacting soon").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.critical)
            }
            if let c = session.compactions, c > 0 {
                Text("🗜️\(c)").font(.system(size: 9.5)).help("Auto-compacted \(c) time\(c == 1 ? "" : "s")")
            }
        }
        .help("Context window: how much of the model's memory this conversation is using. Near full, Claude Code compacts (summarizes) older history.")
    }
}

// MARK: - Timeline

struct TimelineCard: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let lanes = laneOrder(store.timeline)
        let segs = store.timeline.filter { lanes.contains($0.lane) }
        Card {
            SectionHeader(title: "Today's timeline", trailing: "when each session was working")
            if segs.isEmpty {
                EmptyHint(symbol: "calendar.day.timeline.left", text: "Nothing yet today")
            } else {
                let start = Calendar.current.startOfDay(for: Date())
                let firstSeg = segs.map(\.start).min() ?? start
                let domainStart = max(start, Calendar.current.dateInterval(of: .hour, for: firstSeg)!.start.addingTimeInterval(-1800))
                Chart(segs) { s in
                    RectangleMark(xStart: .value("Start", s.start),
                                  xEnd: .value("End", max(s.end, s.start.addingTimeInterval(90))),
                                  y: .value("Session", s.lane), height: .fixed(10))
                        .foregroundStyle(Palette.series(store.slots[s.project]).opacity(s.live ? 0.55 : 1))
                        .cornerRadius(3)
                }
                .chartXScale(domain: domainStart...Date())
                .chartYScale(domain: lanes)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: hourStride(domainStart))) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisValueLabel { if let s = v.as(String.self) { Text(s).font(.system(size: 9)).lineLimit(1) } }
                    }
                }
                .frame(height: CGFloat(max(lanes.count, 1)) * 22 + 24)
                if segs.contains(where: \.live) {
                    Text("Faded = working right now").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func hourStride(_ start: Date) -> Int {
        max(1, Int(ceil(Date().timeIntervalSince(start) / 3600 / 6)))
    }

    private func laneOrder(_ segs: [TimelineSegment]) -> [String] {
        var firstSeen: [String: Date] = [:]
        for s in segs { firstSeen[s.lane] = min(firstSeen[s.lane] ?? s.start, s.start) }
        return firstSeen.sorted { $0.value < $1.value }.map(\.key).suffix(7)
    }
}

// MARK: - Search

struct SearchResults: View {
    @Environment(UsageStore.self) private var store
    let query: String
    @State private var copied: String?

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sessions = q.isEmpty ? [] : store.snapshot.sessions.values.filter { s in
            [s.title, s.lastPrompt, s.branch, ProjectPath.name(of: s.project)].compactMap { $0 }.contains { $0.lowercased().contains(q) }
        }.sorted { $0.end > $1.end }
        let prompts = q.isEmpty ? [] : store.snapshot.prompts.reversed().filter { $0.text.lowercased().contains(q) }.prefix(40)

        VStack(alignment: .leading, spacing: 10) {
            if q.isEmpty {
                EmptyHint(symbol: "magnifyingglass", text: "Search every prompt and session you've ever had")
            } else if sessions.isEmpty && prompts.isEmpty {
                EmptyHint(symbol: "questionmark.circle", text: "Nothing matches “\(query)”")
            }
            if !sessions.isEmpty {
                SectionHeader(title: "Sessions", trailing: "\(sessions.count) · click to copy resume command")
                Card(padding: 8) {
                    ForEach(sessions.prefix(15)) { s in
                        resultRow(title: s.title ?? s.lastPrompt ?? "Untitled", sub: "\(ProjectPath.name(of: s.project)) · \(Fmt.ago(s.end)) · \(Fmt.money(s.cost))",
                                  project: s.project, session: s)
                    }
                }
            }
            if !prompts.isEmpty {
                SectionHeader(title: "Prompts", trailing: "\(prompts.count)\(prompts.count == 40 ? "+" : "")")
                Card(padding: 8) {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { _, p in
                        resultRow(title: p.text, sub: "\(ProjectPath.name(of: p.project)) · \(Fmt.ago(p.time))",
                                  project: p.project, session: store.snapshot.sessions[p.sessionId])
                    }
                }
            }
        }
    }

    private func resultRow(title: String, sub: String, project: String, session: SessionSummary?) -> some View {
        Button {
            guard let s = session, let cmd = UsageStore.resumeCommand(cwd: s.cwd, sessionId: s.id) else { return }
            UsageStore.copy(cmd)
            copied = s.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ColorDot(color: Palette.series(store.slots[project]), size: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    highlighted(title).font(.system(size: 11)).lineLimit(2)
                    Text(sub).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                if copied != nil, copied == session?.id {
                    Text("Copied!").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.good)
                }
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func highlighted(_ text: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let r = text.range(of: q, options: .caseInsensitive) else { return Text(text) }
        return Text(text[..<r.lowerBound]) + Text(text[r]).bold().foregroundColor(Palette.accent) + Text(text[r.upperBound...])
    }
}
