import Foundation

/// `ClaudeUsage --dump` prints a text report; handy for verifying the parser without the UI.
enum Dump {
    static func run() async {
        let scanner = TranscriptScanner(persist: false, loadArchive: true)   // includes archived history, never writes
        let snap = await scanner.scan()
        let f = { (d: Double) in String(format: "$%.2f", d) }
        print("files \(snap.filesScanned)  bytes \(snap.bytesScanned / 1_000_000)MB  events \(snap.events.count)  prompts \(snap.prompts.count)  archived sessions \(snap.archivedSessions)  scan \(String(format: "%.2fs", snap.scanDuration))")
        let slots = StatsEngine.colorSlots(snap)
        for r in TimeRange.allCases {
            let s = StatsEngine.compute(snap, range: r, slots: slots)
            print("\n== \(r.rawValue): \(f(s.cost)) prev \(s.prevCost.map(f) ?? "-")  tokens \(s.tokens)  msgs \(s.messages)  prompts \(s.prompts)  sessions \(s.sessions)  active \(Int(s.activeMs / 60000))m  cacheHit \(Int(s.cacheHitRate * 100))%  saved \(f(s.cacheSavings))")
            for p in s.projects.prefix(8) { print("   \(p.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(f(p.cost))  \(p.sessions.count) sess") }
            for m in s.models { print("   [\(Pricing.displayName(m.model))] \(f(m.cost))  \(m.messages) msgs") }
            print("   tools: " + s.tools.prefix(8).map { "\($0.name)=\($0.count)" }.joined(separator: " "))
        }
        let blocks = StatsEngine.blocks(snap.events)
        if let b = blocks.last { print("\nlast block \(b.start) cost \(f(b.cost)) active \(b.isActive(now: Date()))  max block \(f(blocks.map(\.cost).max() ?? 0))") }
        let st = StatsEngine.streaks(daily: StatsEngine.dailyCosts(snap.events))
        print("streak \(st.current) longest \(st.longest) days \(st.activeDays)")
        let days = Analytics.days(snap)
        let prc = Analytics.prCosts(snap)
        let g = Game.compute(snap, days: days, prCosts: prc)
        print("\nGAME level \(g.level) \(g.title)  xp \(g.totalXP) (\(g.levelFloor)-\(g.levelCeil))  today +\(g.todayXP)  streak \(g.streak) freezes \(g.freezes)  season \(g.seasonRank) \(g.seasonXP)")
        for a in g.achievements { print("  \(a.isUnlocked ? "✓" : " ") \(a.emoji) \(a.name) tier \(a.tier)/\(a.tiers.count) value \(Int(a.value))") }
        for q in g.dailyQuests { print("  quest \(q.emoji) \(q.title) \(q.label) done=\(q.done)") }
        if let w = g.weeklyQuest { print("  weekly \(w.title) \(w.label)") }
        for r in g.records { print("  record \(r.emoji) \(r.name): \(r.value)") }
        for p in prc.prefix(6) { print("  PR #\(p.pr.number) \(Fmt.money(p.cost)) wall \(Fmt.duration(p.wall)) replies \(p.replies)") }
        let rb = Analytics.cacheRebuilds(snap.events[...])
        print("  cache rebuilds \(rb.count) premium \(Fmt.money(rb.reduce(0) { $0 + $1.premium }))  compactions \(snap.compactions.count)  commits \(snap.events.reduce(0) { $0 + ($1.commits ?? 0) })")
        for s in snap.sessions.values where s.end > Date().addingTimeInterval(-86400) { print("  ctx \(ProjectPath.name(of: s.project)) \(Fmt.tokens(s.context ?? 0))/\(Fmt.tokens(s.contextWindow ?? 0)) compactions \(s.compactions ?? 0)") }
        for l in LiveSessionReader.read() { print("LIVE \(l.pid) \(l.status) \(l.name) \(l.cwd)") }
        let t0 = Date(); let snap2 = await scanner.scan()
        print("rescan \(String(format: "%.3fs", Date().timeIntervalSince(t0))) events \(snap2.events.count)")
    }
}
