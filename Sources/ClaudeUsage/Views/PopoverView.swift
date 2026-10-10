import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case now = "Now", usage = "Usage", projects = "Projects", models = "Models", game = "Game", insights = "Insights"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .now: "dot.radiowaves.left.and.right"
        case .usage: "chart.bar.xaxis"
        case .projects: "folder"
        case .models: "cpu"
        case .game: "gamecontroller"
        case .insights: "sparkles"
        }
    }
    var usesRange: Bool { self == .usage || self == .projects || self == .models }
}

struct PopoverView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.defaultTab) private var tabRaw = Tab.now.rawValue
    @State private var showSettings = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Screenshots pin a tab without touching the user's saved one.
    var forcedTab: Tab? = nil

    private var tab: Tab { forcedTab ?? Tab(rawValue: tabRaw) ?? .now }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching {
                searchField
            } else {
                tabBar
                if tab.usesRange { rangeBar }
            }
            Divider().opacity(0.5)
            ZStack(alignment: .top) {
                ScrollView {
                    Group {
                        if searching {
                            SearchResults(query: query)
                        } else {
                            switch tab {
                            case .now: NowTab()
                            case .usage: UsageTab()
                            case .projects: ProjectsTab()
                            case .models: ModelsTab()
                            case .game: GameTab()
                            case .insights: InsightsTab()
                            }
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.never)
                if !store.loaded {
                    ProgressView("Reading transcripts…").controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial)
                }
                if let toast = store.toast {
                    Text(toast)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.regularMaterial).shadow(color: .black.opacity(0.2), radius: 8, y: 2))
                        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1))
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { tabRaw = Tab.game.rawValue }
                }
            }
            .animation(.spring(duration: 0.4), value: store.toast)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 460, height: 660)
        .overlay {
            if showSettings {
                SettingsPanel(isPresented: $showSettings)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showSettings)
        .background {
            // ⌘F searches, Esc leaves search.
            Button("") { startSearch() }.keyboardShortcut("f", modifiers: .command).hidden()
            Button("") { if searching { searching = false; query = "" } }.keyboardShortcut(.escape, modifiers: []).hidden()
        }
    }

    private func startSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.starburst(size: 16, rays: store.game.rays, core: store.game.level >= 41))
                .renderingMode(.template)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Usage").font(.system(size: 13, weight: .semibold))
                Text(statusLine).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { tabRaw = Tab.game.rawValue; searching = false } label: {
                HStack(spacing: 6) {
                    ZStack {
                        RingGauge(fraction: store.game.levelProgress, lineWidth: 2.5, color: Palette.accent)
                        Text("\(store.game.level)").font(.system(size: 9.5, weight: .bold))
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(store.game.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        Text("🔥 \(store.game.streak) · +\(store.game.todayXP) XP today").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Palette.accent.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Your level — open the Game tab")
            IconButton(symbol: searching ? "xmark" : "magnifyingglass", help: "Search sessions & prompts (⌘F)") {
                if searching { searching = false; query = "" } else { startSearch() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search prompts, titles, projects, branches…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.cardFill))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var statusLine: String {
        let busy = store.busyCount
        let liveCount = store.live.count
        if liveCount == 0 { return "No Claude sessions running" }
        let waiting = store.waiting.count
        return busy > 0 ? "\(busy) working · \(liveCount) open" + (waiting > 0 ? " · \(waiting) waiting" : "")
                        : "\(liveCount) open · all idle"
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { t in
                Button { tabRaw = t.rawValue } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.symbol).font(.system(size: 12))
                        Text(t.rawValue).font(.system(size: 10, weight: tab == t ? .semibold : .regular))
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tab == t ? Palette.hairline : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == t ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var rangeBar: some View {
        Picker("", selection: Binding(get: { store.range }, set: { store.range = $0 })) {
            ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let t = store.lastRefresh {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("Updated \(Fmt.ago(t)) · \(store.snapshot.filesScanned) transcripts" + (store.snapshot.archivedSessions > 0 ? " + \(store.snapshot.archivedSessions) archived" : ""))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if UserDefaults.standard.bool(forKey: Prefs.hotkey) {
                Text("⌥⌘C").font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                    .help("Global shortcut to open this popover")
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { Task { await store.refresh(); await store.refreshPlan() } }
            IconButton(symbol: "gearshape", help: "Settings") { showSettings = true }
            IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Now

struct NowTab: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(Prefs.dailyBudget) private var dailyBudget = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroRow
            PlanLimitsOptIn()
            PlanLimitsCard()
            WaitingSection()
            liveSection
            TimelineCard()
            todayChart
            recentPrompts
            recentSessions
        }
    }

    // MARK: Hero

    private var heroRow: some View {
        HStack(spacing: 8) {
            todayTile
            blockTile
            burnTile
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var todayTile: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Today").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(Fmt.money(store.today.cost)).font(.system(size: 22, weight: .semibold))
            if dailyBudget > 0 {
                let f = store.today.cost / dailyBudget
                Bar(value: min(f, 1), color: f >= 1 ? Palette.critical : f > 0.8 ? Palette.serious : Palette.series[0], height: 5)
                HStack(spacing: 3) {
                    if f >= 1 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical) }
                    Text("\(Fmt.percent(f)) of \(Fmt.money(dailyBudget)) budget")
                }
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
            } else {
                if let d = store.today.delta {
                    Text("\(Fmt.delta(d)) vs yesterday").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("\(Fmt.tokens(store.today.tokens)) tokens · \(store.today.messages) replies")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.cardFill))
    }

    private var blockTile: some View {
        let b = store.activeBlock
        let real = store.plan.fiveHour
        let f = real.map { $0.percent / 100 } ?? (b?.cost ?? 0) / store.blockReference
        let resets = real?.resetsAt ?? b?.end
        return HStack(spacing: 9) {
            ZStack {
                RingGauge(fraction: f, lineWidth: 6,
                          color: f >= 0.9 ? Palette.critical : f >= 0.7 ? Palette.serious : Palette.series[0])
                Text(real == nil && b == nil ? "–" : Fmt.percent(min(f, 9.99)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(real != nil ? "5h limit" : "5h block").font(.system(size: 10.5)).foregroundStyle(.secondary)
                if real != nil || b != nil {
                    Text(Fmt.money(b?.cost ?? 0)).font(.system(size: 14, weight: .semibold))
                    if let resets {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text("resets in \(Fmt.duration(resets.timeIntervalSinceNow, short: true))")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("Idle").font(.system(size: 14, weight: .semibold))
                    Text("starts on next msg").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.cardFill))
        .help(real != nil
              ? "Your real 5-hour plan usage from Anthropic (same as /usage in Claude Code)."
              : "Estimated: this 5-hour window's API-equivalent spend vs \(UserDefaults.standard.double(forKey: Prefs.blockBudget) > 0 ? "your block budget" : "your busiest window so far") (\(Fmt.money(store.blockReference))). Turn on plan limits in Settings for the real number.")
    }

    private var burnTile: some View {
        let b = store.activeBlock
        let elapsed = b.map { max(Date().timeIntervalSince($0.start), 600) } ?? 0
        let rate = b.map { $0.cost / elapsed * 3600 } ?? 0
        let projected = b.map { $0.cost + rate * max($0.end.timeIntervalSinceNow, 0) / 3600 } ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            Text("Burn rate").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(Fmt.money(store.burnPerHour) + "/h").font(.system(size: 16, weight: .semibold))
            Text("last 60 min").font(.system(size: 10)).foregroundStyle(.tertiary)
            if b != nil {
                Text("→ \(Fmt.money(projected)) by reset").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.cardFill))
    }

    private var todayChart: some View {
        Card {
            SectionHeader(title: "Today by hour", trailing: "\(store.today.prompts) prompts · \(Fmt.duration(store.today.activeMs / 1000)) Claude time")
            StackedUsageChart(stats: store.today, slots: store.slots, height: 92, compactAxis: true)
        }
    }

    // MARK: Live

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Running now", trailing: store.live.isEmpty ? nil : "\(store.live.count) sessions")
            if store.live.isEmpty {
                Card { EmptyHint(symbol: "moon.zzz", text: "No Claude Code sessions are open") }
            } else {
                ForEach(store.live) { s in LiveSessionRow(live: s) }
            }
        }
    }

    private var recentPrompts: some View {
        let prompts = store.snapshot.prompts.suffix(5).reversed()
        return VStack(alignment: .leading, spacing: 6) {
            if !prompts.isEmpty {
                SectionHeader(title: "Latest prompts")
                Card(padding: 10) {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                        HStack(alignment: .top, spacing: 8) {
                            ColorDot(color: Palette.series(store.slots[p.project]), size: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.text.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 11)).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(ProjectPath.name(of: p.project)) · \(Fmt.ago(p.time))")
                                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            }
                        }
                        if i < prompts.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private var recentSessions: some View {
        let recent = Array(store.recentSessions.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            if !recent.isEmpty {
                SectionHeader(title: "Recently closed", trailing: "last 3 days")
                Card(padding: 10) {
                    ForEach(recent) { s in
                        SessionLine(session: s)
                        if s.id != recent.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }
}

struct LiveSessionRow: View {
    @Environment(UsageStore.self) private var store
    let live: LiveSession
    @State private var hover = false

    var body: some View {
        let summary = store.session(for: live)
        let color = Palette.series(store.slots[live.project])
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PulsingDot(active: live.isBusy)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(ProjectPath.name(of: live.project)).font(.system(size: 12.5, weight: .semibold))
                        if let branch = summary?.branch { Chip(text: branch) }
                        if live.remote { Chip(text: "remote") }
                        if live.cwd.contains("/.claude/worktrees/") { Chip(text: "worktree") }
                    }
                    Text(summary?.title ?? live.name)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.money(summary?.cost ?? 0)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Text(statusText).font(.system(size: 10)).foregroundStyle(live.isBusy ? Palette.good : .secondary)
                    }
                }
            }
            if let p = summary?.lastPrompt {
                Text("“\(p.replacingOccurrences(of: "\n", with: " "))”")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(2)
                    .padding(.leading, 22)
            }
            HStack(spacing: 10) {
                if let s = summary {
                    Label(Fmt.tokens(s.tokens), systemImage: "number").help("Total tokens incl. cache reads")
                    Label("\(s.prompts)", systemImage: "text.bubble").help("Your prompts")
                    Label(Fmt.duration(s.activeMs / 1000, short: true), systemImage: "timer").help("Time Claude spent working")
                    if s.subagentCount > 0 { Label("\(s.subagentCount)", systemImage: "person.2").help("Subagents spawned") }
                    if let m = s.primaryModel { Label(Pricing.displayName(m), systemImage: "cpu") }
                }
                Spacer()
                if hover {
                    IconButton(symbol: "macwindow", help: "Bring its terminal to front") { UsageStore.focus(pid: live.pid) }
                    IconButton(symbol: "folder", help: "Reveal in Finder") { UsageStore.reveal(live.cwd) }
                    IconButton(symbol: "doc.on.doc", help: "Copy resume command") {
                        UsageStore.copy(UsageStore.resumeCommand(cwd: live.cwd, sessionId: live.sessionId))
                    }
                }
            }
            .labelStyle(CompactLabel())
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
            .frame(height: 22)
            if let summary, (summary.context ?? 0) > 0 {
                ContextMeter(session: summary).padding(.leading, 22)
            }
            if let summary, summary.cost > 0 {
                Sparkline(values: store.sessionSpark(summary.id, buckets: 30), color: color)
                    .frame(height: 22)
                    .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.cardFill)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10)
                }
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
        .onHover { hover = $0 }
    }

    private var statusText: String {
        let since = Fmt.duration(Date().timeIntervalSince(live.statusUpdatedAt), short: true)
        switch live.status {
        case "busy": return "working · \(since)"
        case "idle": return "idle · \(since)"
        default: return "\(live.status) · \(since)"
        }
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 9)); configuration.title }
    }
}

struct SessionLine: View {
    @Environment(UsageStore.self) private var store
    let session: SessionSummary
    var showProject = true
    var body: some View {
        HStack(spacing: 8) {
            ColorDot(color: Palette.series(store.slots[session.project]), size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title ?? session.lastPrompt ?? "Untitled session")
                    .font(.system(size: 11)).lineLimit(1)
                Text([showProject ? ProjectPath.name(of: session.project) : nil,
                      session.branch, Fmt.ago(session.end),
                      "\(session.prompts) prompts"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            ForEach(Array(Dictionary(session.prs.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.number > $1.number }.prefix(2)), id: \.url) { pr in
                LinkText(text: "#\(pr.number)", url: pr.url).font(.system(size: 10))
            }
            Text(Fmt.money(session.cost)).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .contextMenu {
            Button("Copy resume command") { UsageStore.copy(UsageStore.resumeCommand(cwd: session.cwd, sessionId: session.id)) }
            Button("Open folder in Terminal") { UsageStore.openInTerminal(session.cwd) }
            Button("Reveal in Finder") { UsageStore.reveal(session.cwd) }
        }
    }
}
