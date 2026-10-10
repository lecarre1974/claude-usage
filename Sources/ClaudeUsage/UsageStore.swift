import Foundation
import SwiftUI
import UserNotifications
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconOnly = "Icon only"
    case sessions = "Session count"
    case todayCost = "Today's cost"
    case block = "5-hour block"
    case burn = "Burn rate"
    case sparkline = "12h sparkline"
    var id: String { rawValue }
}

enum Prefs {
    static let menuBarStyle = "menuBarStyle"
    static let dailyBudget = "dailyBudget"
    static let blockBudget = "blockBudget"
    static let refreshSeconds = "refreshSeconds"
    static let notifyFinished = "notifyFinished"
    static let notifyBudget = "notifyBudget"
    static let animateIcon = "animateIcon"
    static let defaultTab = "lastTab"
    static let planLimits = "planLimits"
    static let notifyRunaway = "notifyRunaway"
    static let runawayDollars = "runawayDollars"
    static let notifyGame = "notifyGame"
    static let hotkey = "hotkey"
    static let planLimitsAsked = "planLimitsAsked"
    static let notifyShowText = "notifyShowText"

    static func register() {
        UserDefaults.standard.register(defaults: [
            menuBarStyle: MenuBarStyle.iconOnly.rawValue,
            dailyBudget: 0.0,
            blockBudget: 0.0,
            refreshSeconds: 5.0,
            notifyFinished: true,
            notifyBudget: true,
            animateIcon: true,
            planLimits: false,            // opt-in: reads Claude Code's login from the Keychain
            planLimitsAsked: false,
            notifyShowText: true,
            notifyRunaway: true,
            runawayDollars: 25.0,
            notifyGame: true,
            hotkey: false,                // ⌥⌘C would shadow that shortcut in other apps; opt-in
        ])
        if UsageStore.isSandboxed {
            // Registration domain is volatile: show features "on" in demo/screenshots without saving anything.
            UserDefaults.standard.register(defaults: [planLimits: true, hotkey: true, dailyBudget: 40.0,
                                                      menuBarStyle: MenuBarStyle.sessions.rawValue])
        }
    }
}

@Observable
@MainActor
final class UsageStore {
    private(set) var snapshot = Snapshot()
    private(set) var live: [LiveSession] = []
    private(set) var slots: [String: Int] = [:]
    private(set) var modelSlots: [String: Int] = [:]
    private(set) var rangeStats = RangeStats()
    private(set) var today = RangeStats()
    private(set) var blocks: [UsageBlock] = []
    private(set) var daily: [Date: Double] = [:]
    private(set) var streaks = Streaks()
    private(set) var burnPerHour = 0.0
    private(set) var last12h: [Double] = []
    private(set) var lastRefresh: Date?
    private(set) var loaded = false
    private(set) var game = GameState()
    private(set) var prCosts: [PRCost] = []
    private(set) var rebuilds: [CacheRebuild] = []
    private(set) var timeline: [TimelineSegment] = []
    private(set) var plan = PlanStatus()
    private(set) var allStats = RangeStats()
    /// Transient celebratory banner shown at the top of the popover.
    private(set) var toast: String?

    var range: TimeRange = .week { didSet { recompute() } }

    private let scanner = TranscriptScanner(persist: !UsageStore.isSandboxed)
    private var lastStatus: [Int32: (status: String, since: Date)] = [:]
    private var budgetNotifiedDay: Date?

    /// `--demo`: synthetic data, no file reads, no Keychain, no notifications.
    /// `--snapshot` renders demo data unless `--real` is also given.
    nonisolated static let isSnapshot = CommandLine.arguments.contains("--snapshot")
    nonisolated static let isDemo = CommandLine.arguments.contains("--demo") || (isSnapshot && !CommandLine.arguments.contains("--real"))
    /// No side effects (Keychain, notifications, persisted prefs) in demo or snapshot runs.
    nonisolated static var isSandboxed: Bool { isDemo || isSnapshot }

    init() {
        Prefs.register()
        Task { await loop() }
        if !Self.isSandboxed { Task { await planLoop() } }
    }

    // MARK: Plan limits

    private func planLoop() async {
        while true {
            if UserDefaults.standard.bool(forKey: Prefs.planLimits) { await refreshPlan() }
            try? await Task.sleep(for: .seconds(plan.error == nil ? 180 : 600))
        }
    }

    func refreshPlan() async {
        guard !Self.isSandboxed else { return }
        guard UserDefaults.standard.bool(forKey: Prefs.planLimits) else { plan = PlanStatus(); return }
        let s = await Task.detached { await PlanLimitsClient.fetch() }.value
        // Keep the last good numbers if a refresh fails transiently.
        if s.limits.isEmpty && !plan.limits.isEmpty { plan.error = s.error } else { plan = s }
    }

    /// Called when the popover opens.
    func refreshPlanIfStale() {
        guard UserDefaults.standard.bool(forKey: Prefs.planLimits) else { return }
        if plan.fetchedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { Task { await refreshPlan() } }
    }

    // MARK: Refresh loop

    private func loop() async {
        while true {
            await refresh()
            let secs = max(2, UserDefaults.standard.double(forKey: Prefs.refreshSeconds))
            try? await Task.sleep(for: .seconds(secs))
        }
    }

    func refresh() async {
        if Self.isDemo {
            if !loaded { snapshot = DemoData.snapshot(); plan = DemoData.plan() }
            live = DemoData.live(snapshot)
            lastRefresh = Date()
            recompute()
            loaded = true
            return
        }
        let snap = await scanner.scan()
        let liveNow = LiveSessionReader.read()
        let changed = snap.bytesScanned > 0 || !loaded
        detectTransitions(liveNow)
        if live != liveNow { live = liveNow }
        lastRefresh = Date()
        // Skip the full rollup when no transcript grew; time-based numbers still tick every 30s.
        if changed || Date().timeIntervalSince(lastRecompute) > 30 {
            if changed { snapshot = snap }
            recompute()
            lastRecompute = Date()
        }
        loaded = true
        checkBudget()
        checkRunaway()
    }

    func recompute() {
        let now = Date()
        if slots.isEmpty || snapshot.generatedAt != lastSlotsAt {
            slots = StatsEngine.colorSlots(snapshot)
            var m: [String: Double] = [:]
            for e in snapshot.events { m[e.model, default: 0] += e.cost }
            modelSlots = Dictionary(m.sorted { $0.value > $1.value }.prefix(7).enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
            lastSlotsAt = snapshot.generatedAt
        }
        rangeStats = StatsEngine.compute(snapshot, range: range, slots: slots, now: now)
        today = range == .today ? rangeStats : StatsEngine.compute(snapshot, range: .today, slots: slots, now: now)
        blocks = StatsEngine.blocks(snapshot.events)
        daily = StatsEngine.dailyCosts(snapshot.events)
        streaks = StatsEngine.streaks(daily: daily, now: now)
        burnPerHour = StatsEngine.trailingCost(snapshot.events, seconds: 3600, now: now)

        let cal = Calendar.current
        let hourStart = cal.dateInterval(of: .hour, for: now)!.start
        var hours = Array(repeating: 0.0, count: 12)
        for e in StatsEngine.slice(snapshot.events, DateInterval(start: hourStart.addingTimeInterval(-11 * 3600), end: now), \.time) {
            let i = 11 - Int(hourStart.timeIntervalSince(cal.dateInterval(of: .hour, for: e.time)!.start) / 3600)
            if (0..<12).contains(i) { hours[i] += e.cost }
        }
        last12h = hours

        allStats = range == .all ? rangeStats : StatsEngine.compute(snapshot, range: .all, slots: slots, now: now)
        let days = Analytics.days(snapshot)
        prCosts = Analytics.prCosts(snapshot)
        game = Game.compute(snapshot, days: days, prCosts: prCosts, now: now)
        rebuilds = Analytics.cacheRebuilds(StatsEngine.slice(snapshot.events, rangeStats.interval, \.time))
        timeline = Analytics.timeline(snapshot, live: live, day: now)
        checkGame()
    }
    private var lastSlotsAt = Date.distantPast
    private var lastRecompute = Date.distantPast

    // MARK: Derived

    var activeBlock: UsageBlock? {
        guard let b = blocks.last, b.isActive(now: Date()) else { return nil }
        return b
    }

    /// The reference for the block gauge: user setting, else the busiest block seen.
    var blockReference: Double {
        let custom = UserDefaults.standard.double(forKey: Prefs.blockBudget)
        if custom > 0 { return custom }
        return max(blocks.map(\.cost).max() ?? 1, 1)
    }

    var busyCount: Int { live.filter(\.isBusy).count }

    /// Sessions that finished and are sitting idle, longest-waiting first.
    var waiting: [LiveSession] {
        live.filter { $0.status == "idle" && Date().timeIntervalSince($0.statusUpdatedAt) < 3 * 86400 }
            .sorted { $0.statusUpdatedAt < $1.statusUpdatedAt }
    }

    func session(for live: LiveSession) -> SessionSummary? { snapshot.sessions[live.sessionId] }

    func sessionSpark(_ id: String, buckets: Int = 24) -> [Double] {
        guard let s = snapshot.sessions[id] else { return [] }
        let span = max(s.end.timeIntervalSince(s.start), 60)
        var out = Array(repeating: 0.0, count: buckets)
        for e in StatsEngine.slice(snapshot.events, DateInterval(start: s.start, end: s.end), \.time) where e.sessionId == id {
            let i = min(buckets - 1, Int(e.time.timeIntervalSince(s.start) / span * Double(buckets)))
            out[i] += e.cost
        }
        return out
    }

    var recentSessions: [SessionSummary] {
        let liveIds = Set(live.map(\.sessionId))
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        return snapshot.sessions.values
            .filter { $0.end > cutoff && !liveIds.contains($0.id) && $0.cost > 0 }
            .sorted { $0.end > $1.end }
    }

    func sessions(in project: String) -> [SessionSummary] {
        snapshot.sessions.values.filter { $0.project == project }.sorted { $0.end > $1.end }
    }

    // MARK: Menu bar label

    var menuBarText: String? {
        let style = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: Prefs.menuBarStyle) ?? "") ?? .iconOnly
        switch style {
        case .iconOnly, .sparkline: return nil
        case .sessions: return busyCount > 0 ? "\(busyCount)" : "\(live.count)"
        case .todayCost: return loaded ? Fmt.money(today.cost) : "…"
        case .burn: return loaded ? Fmt.money(burnPerHour) + "/h" : "…"
        case .block:
            if let f = plan.fiveHour { return "\(Int(f.percent.rounded()))%" }
            guard let b = activeBlock else { return "idle" }
            return "\(Fmt.percent(min(b.cost / blockReference, 9.99))) · \(Fmt.duration(b.end.timeIntervalSinceNow, short: true))"
        }
    }

    // MARK: Notifications

    static var canNotify: Bool { !isSandboxed && Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String, id: String = UUID().uuidString) {
        guard Self.canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    private func detectTransitions(_ now: [LiveSession]) {
        defer {
            lastStatus = Dictionary(now.map { s in
                let prev = lastStatus[s.pid]
                return (s.pid, (s.status, prev?.status == s.status ? prev!.since : Date()))
            }, uniquingKeysWith: { a, _ in a })
        }
        guard loaded, UserDefaults.standard.bool(forKey: Prefs.notifyFinished) else { return }
        for s in now {
            guard let prev = lastStatus[s.pid], prev.status == "busy", !s.isBusy else { continue }
            let worked = Date().timeIntervalSince(prev.since)
            guard worked > 20 else { continue }
            let summary = snapshot.sessions[s.sessionId]
            let title = summary?.title ?? summary?.lastPrompt ?? s.name
            let showText = UserDefaults.standard.bool(forKey: Prefs.notifyShowText)
            notify("✻ \(ProjectPath.name(of: s.project)) is waiting for you",
                   "Worked \(Fmt.duration(worked))" + (showText ? " · \(title)" : ""), id: "done-\(s.pid)")
        }
    }

    private var runawayNotified: [String: Date] = [:]
    private var longRunNotified = Set<String>()

    /// Fire when a session burns unusually fast, or has been working a very long time.
    private func checkRunaway() {
        guard loaded, UserDefaults.standard.bool(forKey: Prefs.notifyRunaway) else { return }
        let threshold = UserDefaults.standard.double(forKey: Prefs.runawayDollars)
        let now = Date()
        let recent = StatsEngine.slice(snapshot.events, DateInterval(start: now.addingTimeInterval(-600), end: now), \.time)
        for s in live where s.isBusy {
            let name = ProjectPath.name(of: s.project)
            let burn = recent.filter { $0.sessionId == s.sessionId }.reduce(0) { $0 + $1.cost }
            if threshold > 0, burn >= threshold, now.timeIntervalSince(runawayNotified[s.sessionId] ?? .distantPast) > 3600 {
                runawayNotified[s.sessionId] = now
                notify("🔥 \(name) is running hot", "\(Fmt.money(burn)) in the last 10 minutes. Might be worth a peek.")
            }
            let busyFor = now.timeIntervalSince(s.statusUpdatedAt)
            let key = "\(s.sessionId)-\(s.statusUpdatedAt.timeIntervalSince1970)"
            if busyFor > 45 * 60, longRunNotified.insert(key).inserted {
                notify("🏃 \(name) has been working \(Fmt.duration(busyFor)) straight",
                       "Long run! Check it's not stuck in a loop.")
            }
        }
    }

    private func showToast(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(6)); if toast == text { toast = nil } }
    }

    /// Achievement / level / quest notifications. The first run seeds silently with one welcome.
    private func checkGame() {
        guard loaded, !Self.isSandboxed else { return }
        let d = UserDefaults.standard
        let notifyOn = d.bool(forKey: Prefs.notifyGame)
        let tiers = Set(game.achievements.flatMap { a in (0..<a.tier).map { "\(a.id):\($0)" } })
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())   // local day, not UTC
        let dayKey = String(format: "questsDone-%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("questsDone-") && k != dayKey { d.removeObject(forKey: k) }
        let questsDone = Set(game.dailyQuests.filter(\.done).map(\.id))
        let wk = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let weekKey = "weeklyDone-\(wk.yearForWeekOfYear ?? 0)-\(wk.weekOfYear ?? 0)"

        guard let seen = d.array(forKey: "seenAchievementTiers") as? [String] else {
            d.set(Array(tiers), forKey: "seenAchievementTiers")
            d.set(game.level, forKey: "lastLevel")
            d.set(Array(questsDone), forKey: dayKey)
            if game.weeklyQuest?.done == true { d.set(true, forKey: weekKey) }
            if notifyOn {
                notify("🎮 Game on!", "You're level \(game.level) — \(game.title) — with \(game.unlockedCount) achievements already unlocked. Check the Game tab.")
            }
            return
        }
        let newTiers = tiers.subtracting(seen)
        for key in newTiers.sorted() {
            let parts = key.split(separator: ":")
            guard let a = game.achievements.first(where: { $0.id == parts[0] }), let t = Int(parts[1]) else { continue }
            let tierName = a.tiers.count > 1 ? " (\(Achievement.tierNames[min(t, 2)]))" : ""
            if notifyOn { notify("🏆 \(a.emoji) \(a.name)\(tierName)", a.blurb) }
            showToast("\(a.emoji) Unlocked \(a.name)\(tierName)!")
        }
        if !newTiers.isEmpty { d.set(Array(tiers.union(seen)), forKey: "seenAchievementTiers") }

        let lastLevel = d.integer(forKey: "lastLevel")
        if game.level > lastLevel {
            d.set(game.level, forKey: "lastLevel")
            if notifyOn { notify("⬆️ Level \(game.level)!", "You're now a \(game.title). Keep shipping.") }
            showToast("⬆️ Level \(game.level) — \(game.title)!")
        }

        let doneBefore = Set(d.array(forKey: dayKey) as? [String] ?? [])
        for id in questsDone.subtracting(doneBefore) {
            let q = game.dailyQuests.first { $0.id == id }
            if let q, notifyOn { notify("✅ Quest complete: \(q.emoji) \(q.title)", "+\(q.xp) XP") }
            if let q { showToast("✅ \(q.title) +\(q.xp) XP") }
        }
        if !questsDone.subtracting(doneBefore).isEmpty { d.set(Array(questsDone.union(doneBefore)), forKey: dayKey) }

        if let w = game.weeklyQuest, w.done, !d.bool(forKey: weekKey) {
            d.set(true, forKey: weekKey)
            for k in d.dictionaryRepresentation().keys where k.hasPrefix("weeklyDone-") && k != weekKey { d.removeObject(forKey: k) }
            if notifyOn { notify("🏆 Weekly quest complete: \(w.emoji) \(w.title)", "+\(w.xp) XP") }
            showToast("🏆 \(w.title) +\(w.xp) XP")
        }
    }

    private func checkBudget() {
        let budget = UserDefaults.standard.double(forKey: Prefs.dailyBudget)
        guard budget > 0, today.cost >= budget, UserDefaults.standard.bool(forKey: Prefs.notifyBudget) else { return }
        let day = Calendar.current.startOfDay(for: Date())
        guard budgetNotifiedDay != day else { return }
        budgetNotifiedDay = day
        notify("Daily Claude budget reached", "\(Fmt.money(today.cost)) of \(Fmt.money(budget)) API-equivalent spend today.")
    }

    // MARK: Actions

    static func openInTerminal(_ path: String) {
        // Paths come from transcripts: only ever open an existing directory (Terminal would *run* a file).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let config = NSWorkspace.OpenConfiguration()
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
        }
    }

    func clearArchive() async {
        await scanner.clearArchive()
        await refresh()
    }

    static func open(_ url: String) {
        // Links come from transcript data; only ever open web URLs.
        guard let u = URL(string: url), u.scheme?.lowercased() == "https", u.host != nil else { return }
        NSWorkspace.shared.open(u)
    }

    /// `cd '<dir>' && claude --resume <id>`, single-quoted so any path is safe to paste.
    /// nil if the path contains control characters (nothing safe to paste).
    static func resumeCommand(cwd: String, sessionId: String) -> String? {
        guard !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = sessionId.filter { $0.isHexDigit || $0 == "-" }
        return "cd -- \(quoted) && claude --resume \(id)"
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func copy(_ s: String?) {
        guard let s else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Brings the terminal app that owns a live session's process tree to the front.
    static func focus(pid: Int32) {
        guard !isSandboxed else { return }   // demo pids are fake
        var p = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                app.activate()
                return
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return }
            p = Int32(info.pbi_ppid)
            if p <= 1 { return }
        }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("launch at login: \(error)") }
        }
    }
}
