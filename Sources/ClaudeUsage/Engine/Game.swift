import Foundation

// The game is a pure function of your history: replaying the transcripts always yields the same
// level, achievements and records. XP rewards shipping, consistency and efficiency, never spend.

struct Achievement: Identifiable {
    let id: String
    let emoji: String
    let name: String
    let blurb: String          // shown when unlocked; playful
    let unit: String           // what the progress counts
    let tiers: [Double]        // single-tier achievements have one threshold
    var value: Double = 0
    var unlockedAt: [Date?] = []

    var tier: Int { tiers.filter { value >= $0 }.count }          // 0 = locked
    var isUnlocked: Bool { tier > 0 }
    var isMaxed: Bool { tier == tiers.count }
    var nextTarget: Double? { isMaxed ? nil : tiers[tier] }
    var progress: Double {
        guard let next = nextTarget else { return 1 }
        let prev = tier > 0 ? tiers[tier - 1] : 0
        return max(0, min(1, (value - prev) / max(next - prev, 1)))
    }
    static let tierNames = ["Bronze", "Silver", "Gold"]
    var tierName: String? { tier > 0 && tiers.count > 1 ? Self.tierNames[min(tier, 3) - 1] : nil }
}

struct Quest: Identifiable {
    let id: String
    let emoji: String
    let title: String
    let detail: String
    let xp: Int
    var progress: Double     // 0...1
    var label: String        // e.g. "1 / 2"
    var done: Bool { progress >= 1 }
}

struct GameRecord: Identifiable {
    var id: String { name }
    let emoji: String
    let name: String
    let value: String
    let date: Date?
    var isNew: Bool { date.map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false }
}

struct XPLine: Identifiable {
    let id = UUID()
    let label: String
    let xp: Int
}

struct GameState {
    var totalXP = 0
    var level = 1
    var levelFloor = 0
    var levelCeil = 100
    var title = ""
    var todayXP = 0
    var todayLines: [XPLine] = []
    var seasonXP = 0
    var seasonRank = "Bronze"
    var seasonNext: (rank: String, xp: Int)?
    var streak = 0
    var longestStreak = 0
    var freezes = 0
    var frozenToday = false
    var achievements: [Achievement] = []
    var dailyQuests: [Quest] = []
    var weeklyQuest: Quest?
    var records: [GameRecord] = []

    var levelProgress: Double { Double(totalXP - levelFloor) / Double(max(levelCeil - levelFloor, 1)) }
    var unlockedCount: Int { achievements.filter(\.isUnlocked).count }
    /// Menu bar star grows with level: 6 rays at level 1, 12 by level 24.
    var rays: Int { min(12, 6 + level / 4) }
}

enum Game {
    static let xpActiveDay = 50
    static let xpPerPrompt = 3, promptCapPerDay = 30
    static let xpPR = 150
    static let xpCommit = 15, commitCapPerDay = 10
    static let xpCacheDay = 25
    static let xpTier = [100, 200, 400]

    static func xpForLevel(_ l: Int) -> Int { 50 * l * (l - 1) }    // L2=100, L5=1000, L10=4500, L20=19000

    static func level(for xp: Int) -> Int {
        var l = 1
        while xpForLevel(l + 1) <= xp && l < 99 { l += 1 }
        return l
    }

    static let titles: [(Int, String)] = [
        (1, "Prompt Padawan"), (3, "Token Tinkerer"), (5, "Diff Wrangler"), (8, "Cache Whisperer"),
        (11, "Subagent Shepherd"), (15, "Merge Mage"), (20, "Context Sorcerer"), (26, "Ship Captain"),
        (33, "Opus Overlord"), (41, "Fable Legend"), (50, "✻ Ascended"),
    ]
    static func title(for level: Int) -> String { titles.last { $0.0 <= level }!.1 }

    static let seasonRanks: [(String, Int)] = [("Bronze", 0), ("Silver", 1000), ("Gold", 2500), ("Platinum", 5000), ("Diamond", 9000)]

    // MARK: Quests

    private struct QuestDef {
        let id, emoji, title, detail: String
        let xp: Int
        let eval: (DayStats) -> (Double, String)
    }

    private static func frac(_ v: Double, _ target: Double) -> (Double, String) {
        (min(1, v / target), "\(Int(min(v, target))) / \(Int(target))")
    }

    private static let dailyPool: [QuestDef] = [
        QuestDef(id: "ship", emoji: "🚢", title: "Ship It", detail: "Open a pull request", xp: 120) { frac(Double($0.prs), 1) },
        QuestDef(id: "commit", emoji: "📦", title: "Commit to the Bit", detail: "Land 2 commits", xp: 60) { frac(Double($0.commits), 2) },
        QuestDef(id: "cache", emoji: "💎", title: "Cache Money", detail: "95%+ cache hit over 20+ replies", xp: 50) { d in
            d.replies < 20 ? (Double(d.replies) / 20 * 0.5, "\(d.replies) / 20 replies")
                           : (d.cacheHit >= 0.95 ? 1 : d.cacheHit / 0.95 * 0.99, "\(Int(d.cacheHit * 100))% hit")
        },
        QuestDef(id: "explore", emoji: "🧭", title: "Explorer", detail: "Work in 2 different projects", xp: 50) { frac(Double($0.projects.count), 2) },
        QuestDef(id: "delegate", emoji: "🪖", title: "Delegate", detail: "Let a subagent do some work", xp: 40) { frac(Double($0.subagentReplies), 1) },
        QuestDef(id: "early", emoji: "🐦", title: "Early Bird", detail: "Send a prompt before 9am", xp: 40) { d in
            guard let f = d.firstPrompt else { return (0, "not yet") }
            return Calendar.current.component(.hour, from: f) < 9 ? (1, "✓") : (0, "missed today")
        },
        QuestDef(id: "deep", emoji: "🧘", title: "Deep Work", detail: "60 minutes of Claude time", xp: 60) { frac($0.activeMs / 60000, 60) },
        QuestDef(id: "chat", emoji: "💬", title: "Pair Programmer", detail: "Send 10 prompts", xp: 40) { frac(Double($0.prompts), 10) },
        QuestDef(id: "research", emoji: "🔎", title: "Research Mode", detail: "Have Claude search the web", xp: 30) { frac(Double($0.webSearches), 1) },
        QuestDef(id: "multi", emoji: "🐙", title: "Multitasker", detail: "2 sessions working at once", xp: 50) { frac(Double($0.maxConcurrent), 2) },
        QuestDef(id: "fresh", emoji: "🌱", title: "Fresh Start", detail: "Start a new session", xp: 30) { frac(Double($0.newSessions), 1) },
    ]

    /// Deterministic daily pick so a day's quests never change under you.
    private static func questsFor(_ day: Date) -> [QuestDef] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let y: Int = c.year ?? 2000, m: Int = c.month ?? 1, dd: Int = c.day ?? 1
        let stamp: Int = max(0, y * 10_000 + m * 100 + dd)
        var seed: UInt64 = UInt64(stamp) &* 2654435761
        var pool = dailyPool
        var picked: [QuestDef] = []
        for _ in 0..<3 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            picked.append(pool.remove(at: Int((seed >> 33) % UInt64(pool.count))))
        }
        return picked
    }

    private static func evalQuests(_ day: Date, _ s: DayStats?) -> [Quest] {
        let stats = s ?? DayStats(day: day)
        return questsFor(day).map { q in
            let (p, label) = q.eval(stats)
            return Quest(id: q.id, emoji: q.emoji, title: q.title, detail: q.detail, xp: q.xp, progress: p, label: label)
        }
    }

    /// The week's quest, plus the day its target was first reached (XP lands on that day).
    private static func weeklyQuest(weekStart: Date, days: [Date: DayStats], cal: Calendar) -> (Quest, Date?) {
        let week: [DayStats] = (0..<7).map { i in let d = cal.day(weekStart, plus: i); return days[d] ?? DayStats(day: d) }
        typealias Def = (id: String, emoji: String, title: String, detail: String, xp: Int, target: Double, value: ([DayStats]) -> Double)
        let defs: [Def] = [
            ("w-ship", "🏴‍☠️", "Fleet Week", "Open 3 PRs this week", 300, 3, { Double($0.reduce(0) { $0 + $1.prs }) }),
            ("w-days", "📅", "Regular", "Be active 5 days this week", 250, 5, { Double($0.filter(\.isActive).count) }),
            ("w-proj", "🗺️", "Cartographer", "Touch 3 projects this week", 250, 3, { Double($0.reduce(into: Set<String>()) { $0.formUnion($1.projects) }.count) }),
            ("w-commit", "🧱", "Bricklayer", "Land 10 commits this week", 300, 10, { Double($0.reduce(0) { $0 + $1.commits }) }),
        ]
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: weekStart)
        let d = defs[abs((c.yearForWeekOfYear ?? 0) * 53 + (c.weekOfYear ?? 0)) % defs.count]
        var doneOn: Date?
        for i in 1...7 where doneOn == nil && d.value(Array(week.prefix(i))) >= d.target { doneOn = week[i - 1].day }
        let v = d.value(week)
        return (Quest(id: d.id, emoji: d.emoji, title: d.title, detail: d.detail, xp: d.xp,
                      progress: min(1, v / d.target), label: "\(Int(min(v, d.target))) / \(Int(d.target))"), doneOn)
    }

    // MARK: Compute

    static func compute(_ snap: Snapshot, days: [Date: DayStats], prCosts: [PRCost], now: Date = Date(), cal: Calendar = .current) -> GameState {
        var g = GameState()
        let today = cal.startOfDay(for: now)
        guard let firstDay = days.keys.min() else {
            g.title = title(for: 1)
            g.dailyQuests = evalQuests(today, nil)
            return g
        }

        // 1. Walk every day: base XP, quests, streak + freezes.
        var xpByDay: [Date: Int] = [:]
        var streak = 0, freezes = 0, activeRun = 0, longest = 0
        var longestDate: Date?
        var streakTierDates: [Date?] = [nil, nil, nil]
        var d = firstDay
        while d <= today {
            let s = days[d]
            let active = s?.isActive ?? false
            var xp = 0
            if let s, active {
                xp += xpActiveDay
                xp += min(s.prompts, promptCapPerDay) * xpPerPrompt
                xp += s.prs * xpPR + min(s.commits, commitCapPerDay) * xpCommit
                if s.replies >= 20 && s.cacheHit >= 0.95 { xp += xpCacheDay }
                xp += evalQuests(d, s).filter(\.done).reduce(0) { $0 + $1.xp }
                streak += 1; activeRun += 1
                xp += 5 * min(streak, 20)
                if activeRun % 7 == 0 { freezes = min(freezes + 1, 2) }   // earn a freeze per 7 active days
                if streak > longest { longest = streak; longestDate = d }
                for (i, th) in [3, 10, 30].enumerated() where streakTierDates[i] == nil && streak >= th { streakTierDates[i] = d }
            } else if d < today {
                if freezes > 0 && streak > 0 { freezes -= 1 } else { streak = 0; activeRun = 0 }
            }
            xpByDay[d] = xp
            d = cal.day(d, plus: 1)
        }
        g.streak = streak
        g.longestStreak = longest
        g.freezes = freezes
        g.frozenToday = !(days[today]?.isActive ?? false) && streak > 0

        // 2. Achievements (+ their XP).
        g.achievements = achievements(snap, days: days, prCosts: prCosts, longestStreak: longest, streakDates: streakTierDates, cal: cal)
        var achievementXPToday = 0
        for a in g.achievements {
            for (i, date) in a.unlockedAt.enumerated() where i < a.tier {
                let xp = xpTier[min(i, 2)]
                if let date, cal.isDate(date, inSameDayAs: now) { achievementXPToday += xp }
                if let date { xpByDay[cal.startOfDay(for: date), default: 0] += xp }
            }
        }

        // Weekly quests: each completed week pays out on the day its target was reached.
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        var ws = cal.dateInterval(of: .weekOfYear, for: firstDay)?.start ?? firstDay
        var weeklyDoneOn: Date?
        while ws <= weekStart {
            let (q, doneOn) = weeklyQuest(weekStart: ws, days: days, cal: cal)
            if let doneOn { xpByDay[doneOn, default: 0] += q.xp }
            if ws == weekStart { g.weeklyQuest = q; weeklyDoneOn = doneOn }
            // +8 days then snap to the week start: immune to DST and week-numbering quirks
            ws = cal.dateInterval(of: .weekOfYear, for: ws.addingTimeInterval(8 * 86400))?.start ?? ws.addingTimeInterval(7 * 86400)
        }

        g.totalXP = xpByDay.values.reduce(0, +)
        g.level = level(for: g.totalXP)
        g.levelFloor = xpForLevel(g.level)
        g.levelCeil = xpForLevel(g.level + 1)
        g.title = title(for: g.level)

        // 3. Today's breakdown.
        let ts = days[today]
        g.dailyQuests = evalQuests(today, ts)
        g.todayXP = xpByDay[today] ?? 0
        if let ts, ts.isActive {
            g.todayLines.append(XPLine(label: "Showed up", xp: xpActiveDay))
            if ts.prompts > 0 { g.todayLines.append(XPLine(label: "\(min(ts.prompts, promptCapPerDay)) prompts", xp: min(ts.prompts, promptCapPerDay) * xpPerPrompt)) }
            if ts.prs > 0 { g.todayLines.append(XPLine(label: "\(ts.prs) PR\(ts.prs == 1 ? "" : "s")", xp: ts.prs * xpPR)) }
            if ts.commits > 0 { g.todayLines.append(XPLine(label: "\(min(ts.commits, commitCapPerDay)) commit\(ts.commits == 1 ? "" : "s")", xp: min(ts.commits, commitCapPerDay) * xpCommit)) }
            if ts.replies >= 20 && ts.cacheHit >= 0.95 { g.todayLines.append(XPLine(label: "Cache efficiency", xp: xpCacheDay)) }
            g.todayLines.append(XPLine(label: "\(streak)-day streak bonus", xp: 5 * min(streak, 20)))
            for q in g.dailyQuests where q.done { g.todayLines.append(XPLine(label: "Quest: \(q.title)", xp: q.xp)) }
            if achievementXPToday > 0 { g.todayLines.append(XPLine(label: "Achievements", xp: achievementXPToday)) }
            if let w = g.weeklyQuest, let on = weeklyDoneOn, on == today { g.todayLines.append(XPLine(label: "Weekly: \(w.title)", xp: w.xp)) }
        }

        // 5. Season = this calendar month.
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? today
        g.seasonXP = xpByDay.filter { $0.key >= monthStart }.values.reduce(0, +)
        g.seasonRank = seasonRanks.last { $0.1 <= g.seasonXP }!.0
        if let next = seasonRanks.first(where: { $0.1 > g.seasonXP }) { g.seasonNext = (next.0, next.1) }

        // 6. Records.
        g.records = records(days: days, xpByDay: xpByDay, prCosts: prCosts, snap: snap, longest: longest, longestDate: longestDate)
        return g
    }

    // MARK: Achievements

    private static func achievements(_ snap: Snapshot, days: [Date: DayStats], prCosts: [PRCost], longestStreak: Int,
                                     streakDates: [Date?], cal: Calendar) -> [Achievement] {
        /// Time at which a running total first reached each tier.
        func crossings(_ items: [(Date, Double)], _ tiers: [Double]) -> (Double, [Date?]) {
            var total = 0.0
            var dates: [Date?] = Array(repeating: nil, count: tiers.count)
            for (t, v) in items.sorted(by: { $0.0 < $1.0 }) {
                total += v
                for (i, th) in tiers.enumerated() where dates[i] == nil && total >= th { dates[i] = t }
            }
            return (total, dates)
        }
        /// For "best single X" achievements: when the max first reached each tier.
        func maxima(_ items: [(Date, Double)], _ tiers: [Double]) -> (Double, [Date?]) {
            var best = 0.0
            var dates: [Date?] = Array(repeating: nil, count: tiers.count)
            for (t, v) in items.sorted(by: { $0.0 < $1.0 }) {
                best = max(best, v)
                for (i, th) in tiers.enumerated() where dates[i] == nil && best >= th { dates[i] = t }
            }
            return (best, dates)
        }
        func make(_ id: String, _ emoji: String, _ name: String, _ blurb: String, _ unit: String, _ tiers: [Double],
                  _ r: (Double, [Date?])) -> Achievement {
            Achievement(id: id, emoji: emoji, name: name, blurb: blurb, unit: unit, tiers: tiers, value: r.0, unlockedAt: r.1)
        }
        let ev = snap.events
        let sortedDays = days.values.sorted { $0.day < $1.day }
        var out: [Achievement] = []

        // Same streak definition as the header (freezes included); tier dates come from the day walk.
        let streakTiers: [Double] = [3, 10, 30]
        out.append(make("streak", "🔥", "On Fire", "Daily streaks: the compound interest of shipping.", "day streak", streakTiers, (Double(longestStreak), streakDates)))

        out.append(make("cache", "🧠", "Cache Lord", "Billions of tokens, read for pennies.", "tokens from cache",
                        [100e6, 1e9, 10e9], crossings(ev.map { ($0.time, Double($0.cacheRead)) }, [100e6, 1e9, 10e9])))
        out.append(make("shipper", "🚢", "Shipper", "Real artists ship. So do you.", "PRs opened",
                        [1, 5, 25], crossings(snap.prs.map { ($0.time, 1) }, [1, 5, 25])))
        out.append(make("commits", "📦", "Commitment Issues (Solved)", "Claude commits. You commit. Everyone commits.", "commits",
                        [10, 100, 500], crossings(ev.compactMap { e in e.commits.map { (e.time, Double($0)) } }, [10, 100, 500])))
        let bash = ev.filter { $0.tools.contains("Bash") }.map { e in (e.time, Double(e.tools.filter { $0 == "Bash" }.count)) }
        out.append(make("bash", "🐚", "Bash Bard", "Sings in sh. Fluent in pipes.", "shell commands",
                        [500, 5000, 20000], crossings(bash, [500, 5000, 20000])))
        out.append(make("prompts", "💬", "Chatterbox", "You and Claude are basically pen pals now.", "prompts",
                        [100, 500, 2500], crossings(snap.prompts.map { ($0.time, 1) }, [100, 500, 2500])))
        out.append(make("days", "📅", "Regular", "Showing up is half the game.", "active days",
                        [7, 30, 100], crossings(sortedDays.filter(\.isActive).map { ($0.day, 1) }, [7, 30, 100])))
        out.append(make("delegator", "🪖", "Delegator", "Why do it yourself when you can spawn a crew?", "subagents in one session",
                        [3, 10, 25], maxima(snap.sessions.values.map { ($0.start, Double($0.subagentCount)) }, [3, 10, 25])))
        out.append(make("marathon", "🏃", "Marathoner", "One session, many hours, zero quit.", "hours of Claude time in one session",
                        [1, 4, 10], maxima(snap.sessions.values.map { ($0.start, $0.activeMs / 3_600_000) }, [1, 4, 10])))
        out.append(make("octopus", "🐙", "Octopus", "Eight arms, several Claudes.", "sessions working at once",
                        [2, 3, 5], maxima(sortedDays.map { ($0.day, Double($0.maxConcurrent)) }, [2, 3, 5])))
        // projects in a rolling week
        var weekly: [(Date, Double)] = []
        for (i, s) in sortedDays.enumerated() {
            let window = sortedDays[max(0, i - 6)...i].filter { s.day.timeIntervalSince($0.day) < 7 * 86400 }
            weekly.append((s.day, Double(window.reduce(into: Set<String>()) { $0.formUnion($1.projects) }.count)))
        }
        out.append(make("polyglot", "🗺️", "Polyglot", "So many repos, so little time.", "projects in one week", [3, 5, 8], maxima(weekly, [3, 5, 8])))
        var seenModels = Set<String>(); var modelItems: [(Date, Double)] = []
        for e in ev where seenModels.insert(e.model).inserted { modelItems.append((e.time, 1)) }
        out.append(make("models", "🎛️", "Model Hopper", "Fable, Opus, Sonnet… you've met the family.", "models used", [2, 4, 6], crossings(modelItems, [2, 4, 6])))
        out.append(make("web", "🏄", "Web Surfer", "Cowabunga, search results.", "web searches",
                        [10, 100, 500], crossings(ev.filter { $0.webSearches > 0 }.map { ($0.time, Double($0.webSearches)) }, [10, 100, 500])))
        var seenTools = Set<String>(); var toolItems: [(Date, Double)] = []
        for e in ev { for t in e.tools where seenTools.insert(StatsEngine.toolGroup(t)).inserted { toolItems.append((e.time, 1)) } }
        out.append(make("tools", "🧰", "Swiss Army Knife", "A tool for every job.", "different tools", [10, 25, 50], crossings(toolItems, [10, 25, 50])))

        // single-tier
        func first(_ dates: [Date]) -> (Double, [Date?]) { (dates.isEmpty ? 0 : 1, [dates.min()]) }
        let hour = { (d: Date) in cal.component(.hour, from: d) }
        out.append(make("owl", "🦉", "Night Owl", "Prompting at 2am? Claude respects the grind.", "late-night prompt", [1],
                        first(snap.prompts.filter { (1..<5).contains(hour($0.time)) }.map(\.time))))
        out.append(make("bird", "🐓", "Rooster", "Up before the sun, shipping before coffee.", "pre-7am prompt", [1],
                        first(snap.prompts.filter { (5..<7).contains(hour($0.time)) }.map(\.time))))
        let weekendDates: [Date] = sortedDays.filter { s in
            s.isActive && cal.component(.weekday, from: s.day) == 1 &&
            (days[cal.day(s.day, plus: -1)]?.isActive ?? false)
        }.map(\.day)
        out.append(make("weekend", "🏖️", "Weekend Warrior", "Saturday AND Sunday. Respect.", "full weekend", [1], first(weekendDates)))
        out.append(make("sniper", "🎯", "Sniper", "One shot, one PR, under five bucks.", "PR under $5", [1],
                        first(prCosts.filter { $0.cost < 5 && $0.replies > 0 }.map(\.pr.time))))
        out.append(make("speedrun", "⚡", "Speedrunner", "Any% PR in under 20 minutes.", "PR in under 20 min", [1],
                        first(prCosts.filter { $0.wall < 20 * 60 && $0.replies > 0 }.map(\.pr.time))))
        out.append(make("bigbrain", "🗜️", "Big Brain", "You filled a context window. Claude had to tidy up.", "auto-compaction", [1],
                        first(snap.compactions.filter(\.auto).map(\.time))))
        out.append(make("cool", "🧊", "Cool Head", "100+ replies without ever compacting. Zen.", "long session, no compaction", [1],
                        first(snap.sessions.values.filter { $0.messages >= 100 && ($0.compactions ?? 0) == 0 }.map(\.end))))
        // resumed after a week of silence
        var necro: [Date] = []
        var lastSeen: [String: Date] = [:]
        for p in snap.prompts {
            if let l = lastSeen[p.sessionId], p.time.timeIntervalSince(l) > 7 * 86400 { necro.append(p.time) }
            lastSeen[p.sessionId] = p.time
        }
        out.append(make("necro", "🧟", "Necromancer", "Raised a session from the dead after a week.", "session revived", [1], first(necro)))
        out.append(make("cacheday", "💎", "Cache Money", "98% cache hit across 50+ replies in one day.", "ultra-efficient day", [1],
                        first(sortedDays.filter { $0.replies >= 50 && $0.cacheHit >= 0.98 }.map(\.day))))
        return out
    }

    // MARK: Records

    private static func records(days: [Date: DayStats], xpByDay: [Date: Int], prCosts: [PRCost], snap: Snapshot,
                                longest: Int, longestDate: Date?) -> [GameRecord] {
        var r: [GameRecord] = []
        let fmtDay = { (d: Date?) in d }
        r.append(GameRecord(emoji: "🔥", name: "Longest streak", value: "\(longest) days", date: fmtDay(longestDate)))
        if let d = days.values.max(by: { $0.prompts < $1.prompts }), d.prompts > 0 {
            r.append(GameRecord(emoji: "💬", name: "Most prompts in a day", value: "\(d.prompts)", date: d.day))
        }
        if let d = days.values.max(by: { $0.activeMs < $1.activeMs }), d.activeMs > 0 {
            r.append(GameRecord(emoji: "🧘", name: "Most Claude time in a day", value: Fmt.duration(d.activeMs / 1000), date: d.day))
        }
        if let d = xpByDay.max(by: { $0.value < $1.value }), d.value > 0 {
            r.append(GameRecord(emoji: "⭐️", name: "Biggest XP day", value: "\(d.value) XP", date: d.key))
        }
        if let d = days.values.filter({ $0.replies >= 50 }).max(by: { $0.cacheHit < $1.cacheHit }) {
            r.append(GameRecord(emoji: "💎", name: "Best cache day", value: Fmt.percent(d.cacheHit, digits: 1), date: d.day))
        }
        let shipped = prCosts.filter { $0.replies > 0 }
        if let p = shipped.min(by: { $0.wall < $1.wall }) {
            r.append(GameRecord(emoji: "⚡", name: "Fastest PR", value: "\(Fmt.duration(p.wall)) · #\(p.pr.number)", date: p.pr.time))
        }
        if let p = shipped.min(by: { $0.cost < $1.cost }) {
            r.append(GameRecord(emoji: "🎯", name: "Cheapest PR", value: "\(Fmt.money(p.cost)) · #\(p.pr.number)", date: p.pr.time))
        }
        if let s = snap.sessions.values.max(by: { $0.subagentCount < $1.subagentCount }), s.subagentCount > 0 {
            r.append(GameRecord(emoji: "🪖", name: "Biggest crew", value: "\(s.subagentCount) subagents", date: s.end))
        }
        return r
    }
}
