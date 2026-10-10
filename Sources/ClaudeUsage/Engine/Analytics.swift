import Foundation

// MARK: - Cache rebuilds ("wasted cache")

struct CacheRebuild {
    let time: Date
    let sessionId: String
    let project: String
    let tokens: Int
    let premium: Double
    let gap: TimeInterval
}

struct PRCost: Identifiable {
    var id: String { pr.url }
    let pr: PRLink
    let cost: Double
    let claudeMs: Double
    let wall: TimeInterval
    let replies: Int
}

struct TimelineSegment: Identifiable {
    let id = UUID()
    let lane: String
    let sessionId: String
    let project: String
    let start: Date
    let end: Date
    let live: Bool
}

/// Per-calendar-day rollup used by quests, XP and records.
struct DayStats {
    let day: Date
    var prompts = 0
    var replies = 0
    var cost = 0.0
    var input = 0, cacheRead = 0, cacheWrite = 0
    var prs = 0
    var commits = 0
    var subagentReplies = 0
    var webSearches = 0
    var activeMs = 0.0
    var projects = Set<String>()
    var newSessions = 0
    var firstPrompt: Date?
    var lastPrompt: Date?
    var maxConcurrent = 0
    var cacheHit: Double {
        let d = Double(input + cacheRead + cacheWrite)
        return d > 0 ? Double(cacheRead) / d : 0
    }
    var isActive: Bool { prompts > 0 || replies > 0 }
}

enum Analytics {
    /// A reply that rewrote most of its context after an idle gap means the prompt cache expired.
    static func cacheRebuilds(_ events: ArraySlice<UsageEvent>) -> [CacheRebuild] {
        var lastBySession: [String: Date] = [:]
        var out: [CacheRebuild] = []
        for e in events where !e.isSubagent {
            defer { lastBySession[e.sessionId] = e.time }
            guard let prev = lastBySession[e.sessionId] else { continue }
            let gap = e.time.timeIntervalSince(prev)
            guard gap > 300, e.cacheWrite > 20_000, Double(e.cacheWrite) > 0.5 * Double(e.contextSize) else { continue }
            out.append(CacheRebuild(time: e.time, sessionId: e.sessionId, project: e.project, tokens: e.cacheWrite,
                                    premium: Pricing.rebuildPremium(model: e.model, tokens: e.cacheWrite), gap: gap))
        }
        return out
    }

    /// Attribute spend to each PR: the session's replies since its previous PR (or start).
    static func prCosts(_ snap: Snapshot) -> [PRCost] {
        let bySession = Dictionary(grouping: snap.prs, by: \.sessionId)
        var out: [PRCost] = []
        for (sid, prs) in bySession {
            guard let session = snap.sessions[sid] else { continue }
            var from = session.start
            for pr in prs.sorted(by: { $0.time < $1.time }) {
                let iv = DateInterval(start: from, end: max(from, pr.time))
                let evs = StatsEngine.slice(snap.events, iv, \.time).filter { $0.sessionId == sid }
                let turns = StatsEngine.slice(snap.turns, iv, \.time).filter { $0.sessionId == sid }
                out.append(PRCost(pr: pr, cost: evs.reduce(0) { $0 + $1.cost },
                                  claudeMs: turns.reduce(0) { $0 + $1.durationMs },
                                  wall: iv.duration, replies: evs.count))
                from = pr.time
            }
        }
        return out.sorted { $0.pr.time > $1.pr.time }
    }

    /// Working intervals per session, reconstructed from turn durations.
    static func workIntervals(_ turns: ArraySlice<TurnEvent>) -> [(sessionId: String, project: String, start: Date, end: Date)] {
        turns.map { ($0.sessionId, $0.project, $0.time.addingTimeInterval(-$0.durationMs / 1000), $0.time) }
    }

    /// Max number of distinct sessions working at the same instant.
    static func maxConcurrency(_ intervals: [(sessionId: String, project: String, start: Date, end: Date)]) -> Int {
        var points: [(Date, Int, String)] = []
        for i in intervals where i.end > i.start {
            points.append((i.start, 1, i.sessionId))
            points.append((i.end, -1, i.sessionId))
        }
        points.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var active: [String: Int] = [:]
        var best = 0
        for (_, d, sid) in points {
            active[sid, default: 0] += d
            if active[sid]! <= 0 { active[sid] = nil }
            best = max(best, active.count)
        }
        return best
    }

    static func timeline(_ snap: Snapshot, live: [LiveSession], day: Date = Date(), cal: Calendar = .current) -> [TimelineSegment] {
        let start = cal.startOfDay(for: day)
        let iv = DateInterval(start: start, end: day)
        var segs: [TimelineSegment] = []
        func lane(_ sid: String, _ project: String) -> String {
            let name = ProjectPath.name(of: project)
            let title = snap.sessions[sid]?.title.map { " · " + $0 } ?? ""
            return String((name + title).prefix(28))
        }
        for w in workIntervals(StatsEngine.slice(snap.turns, iv, \.time)) {
            segs.append(TimelineSegment(lane: lane(w.sessionId, w.project), sessionId: w.sessionId, project: w.project,
                                        start: max(w.start, start), end: w.end, live: false))
        }
        // Turns are only logged when they finish; show in-flight work too.
        for l in live where l.isBusy {
            segs.append(TimelineSegment(lane: lane(l.sessionId, l.project), sessionId: l.sessionId, project: l.project,
                                        start: max(l.statusUpdatedAt, start), end: day, live: true))
        }
        return segs
    }

    static func days(_ snap: Snapshot, cal: Calendar = .current) -> [Date: DayStats] {
        var out: [Date: DayStats] = [:]
        var cache = DayCache(cal)
        func day(_ t: Date) -> Date { cache.day(t) }
        func touch(_ d: Date, _ f: (inout DayStats) -> Void) {
            var s = out[d] ?? DayStats(day: d)
            f(&s)
            out[d] = s
        }
        for e in snap.events {
            touch(day(e.time)) { s in
                s.replies += 1; s.cost += e.cost
                s.input += e.input; s.cacheRead += e.cacheRead; s.cacheWrite += e.cacheWrite
                s.commits += e.commits ?? 0
                s.webSearches += e.webSearches
                if e.isSubagent { s.subagentReplies += 1 }
                s.projects.insert(e.project)
            }
        }
        for p in snap.prompts {
            touch(day(p.time)) { s in
                s.prompts += 1
                s.firstPrompt = min(s.firstPrompt ?? p.time, p.time)
                s.lastPrompt = max(s.lastPrompt ?? p.time, p.time)
            }
        }
        for t in snap.turns { touch(day(t.time)) { $0.activeMs += t.durationMs } }
        for pr in snap.prs { touch(day(pr.time)) { $0.prs += 1 } }
        for s in snap.sessions.values { touch(day(s.start)) { $0.newSessions += 1 } }

        let byDay = Dictionary(grouping: workIntervals(snap.turns[...]), by: { day($0.end) })
        for (d, ivs) in byDay { touch(d) { $0.maxConcurrent = maxConcurrency(ivs) } }
        return out
    }
}
