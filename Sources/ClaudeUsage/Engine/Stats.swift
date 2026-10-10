import Foundation

extension Calendar {
    /// Start of the day `n` days away. Re-normalising matters in zones where DST starts at
    /// midnight (Chile, Egypt, …): adding a day to 01:00 would otherwise stay at 01:00 forever.
    func day(_ d: Date, plus n: Int) -> Date {
        startOfDay(for: date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(Double(n) * 86400))
    }

    /// Next bucket start for any unit, re-normalised the same way.
    func next(_ d: Date, unit: Component) -> Date {
        let n = date(byAdding: unit, value: 1, to: d) ?? d.addingTimeInterval(3600)
        return dateInterval(of: unit, for: n)?.start ?? n
    }
}

/// Memoised startOfDay. Keyed per 15 minutes, since every UTC offset is a multiple of 15 min
/// (an hourly key mis-assigns days in India, Iran, Newfoundland, …).
struct DayCache {
    private var cache: [Int: Date] = [:]
    let cal: Calendar
    init(_ cal: Calendar = .current) { self.cal = cal }
    mutating func day(_ t: Date) -> Date {
        let k = Int((t.timeIntervalSince1970 / 900).rounded(.down))
        if let d = cache[k] { return d }
        let d = cal.startOfDay(for: t)
        cache[k] = d
        return d
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 Days", month = "30 Days", all = "All Time"
    var id: String { rawValue }

    func interval(now: Date, cal: Calendar = .current) -> DateInterval {
        let startOfToday = cal.startOfDay(for: now)
        switch self {
        case .today: return DateInterval(start: startOfToday, end: now)
        case .week:  return DateInterval(start: cal.day(startOfToday, plus: -6), end: now)
        case .month: return DateInterval(start: cal.day(startOfToday, plus: -29), end: now)
        case .all:   return DateInterval(start: .distantPast, end: now)
        }
    }

    /// The equally-long window immediately before, for "vs previous" deltas.
    func previous(now: Date, cal: Calendar = .current) -> DateInterval? {
        let cur = interval(now: now, cal: cal)
        switch self {
        case .today:
            let y = cal.day(cur.start, plus: -1)
            return DateInterval(start: y, end: max(y, now.addingTimeInterval(-86400)))
        case .week, .month:
            let len = cur.end.timeIntervalSince(cur.start)
            return DateInterval(start: cur.start.addingTimeInterval(-len), end: cur.start)
        case .all: return nil
        }
    }

    var shortLabel: String {
        switch self { case .today: "24h"; case .week: "7d"; case .month: "30d"; case .all: "All" }
    }
}

struct Bucket: Identifiable {
    var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    let date: Date
    let series: String      // project path or "Other"
    var cost: Double
    var tokens: Int
}

struct ProjectStat: Identifiable {
    var id: String { path }
    let path: String
    var name: String { ProjectPath.name(of: path) }
    var cost: Double = 0
    var tokens: Int = 0
    var output: Int = 0
    var messages: Int = 0
    var prompts: Int = 0
    var activeMs: Double = 0
    var sessions = Set<String>()
    var lastActive: Date = .distantPast
    var models: [String: Double] = [:]
    var tools: [String: Int] = [:]
    var spark: [Double] = []
}

struct ModelStat: Identifiable {
    var id: String { model }
    let model: String
    var cost: Double = 0
    var input: Int = 0
    var output: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0
    var thinking: Int = 0
    var messages: Int = 0
    var tokens: Int { input + output + cacheWrite + cacheRead }
}

struct UsageBlock: Identifiable {
    var id: Date { start }
    let start: Date
    var end: Date { start.addingTimeInterval(5 * 3600) }
    var lastEvent: Date
    var cost: Double = 0
    var tokens: Int = 0
    var messages: Int = 0
    func isActive(now: Date) -> Bool { now < end && now.timeIntervalSince(lastEvent) < 5 * 3600 }
}

struct RangeStats {
    var range: TimeRange = .today
    var interval = DateInterval()
    var cost = 0.0
    var prevCost: Double?
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, thinking = 0
    var messages = 0, prompts = 0, webSearches = 0
    var activeMs = 0.0
    var sessions = 0
    var subagentCost = 0.0
    var fastCost = 0.0
    var cacheSavings = 0.0
    var buckets: [Bucket] = []
    var bucketUnit: Calendar.Component = .day
    var projects: [ProjectStat] = []
    var models: [ModelStat] = []
    var tools: [(name: String, count: Int)] = []
    var punchcard: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7) // [weekday][hour] cost

    var tokens: Int { input + output + cacheWrite + cacheRead }
    var cacheHitRate: Double {
        let denom = Double(input + cacheWrite + cacheRead)
        return denom > 0 ? Double(cacheRead) / denom : 0
    }
    var delta: Double? {
        guard let p = prevCost, p > 0.01 else { return nil }
        return (cost - p) / p
    }
}

struct Streaks {
    var current = 0
    var longest = 0
    var activeDays = 0
    var busiestDay: (date: Date, cost: Double)?
}

enum StatsEngine {
    static let otherKey = "\u{0}other"   // can't collide with a real project path

    /// Stable project -> palette slot (0..6) by all-time spend. Color follows the entity.
    static func colorSlots(_ snap: Snapshot) -> [String: Int] {
        var totals: [String: Double] = [:]
        for e in snap.events { totals[e.project, default: 0] += e.cost }
        let ranked = totals.sorted { $0.value > $1.value }.prefix(7)
        var out: [String: Int] = [:]
        for (i, p) in ranked.enumerated() { out[p.key] = i }
        return out
    }

    static func compute(_ snap: Snapshot, range: TimeRange, slots: [String: Int], now: Date = Date()) -> RangeStats {
        let cal = Calendar.current
        var s = RangeStats()
        s.range = range
        var iv = range.interval(now: now, cal: cal)
        if range == .all, let first = snap.events.first?.time { iv = DateInterval(start: min(cal.startOfDay(for: first), now), end: now) }
        s.interval = iv

        let span = iv.end.timeIntervalSince(iv.start)
        s.bucketUnit = range == .today ? .hour : (span > 120 * 86400 ? .weekOfYear : .day)

        var projects: [String: ProjectStat] = [:]
        var models: [String: ModelStat] = [:]
        var tools: [String: Int] = [:]
        var buckets: [String: Bucket] = [:]
        var sessionIds = Set<String>()

        let events = slice(snap.events, iv, \.time)
        for e in events {
            s.cost += e.cost
            s.input += e.input; s.output += e.output
            s.cacheWrite += e.cacheWrite; s.cacheRead += e.cacheRead
            s.thinking += e.thinking
            s.messages += 1
            s.webSearches += e.webSearches
            if e.isSubagent { s.subagentCost += e.cost }
            if e.fast { s.fastCost += e.cost }
            s.cacheSavings += Pricing.cacheSavings(model: e.model, cacheRead: e.cacheRead)
            sessionIds.insert(e.sessionId)

            var p = projects[e.project] ?? ProjectStat(path: e.project)
            p.cost += e.cost; p.tokens += e.totalTokens; p.output += e.output; p.messages += 1
            p.sessions.insert(e.sessionId)
            p.lastActive = max(p.lastActive, e.time)
            p.models[e.model, default: 0] += e.cost
            for t in e.tools { p.tools[t, default: 0] += 1 }
            projects[e.project] = p

            var m = models[e.model] ?? ModelStat(model: e.model)
            m.cost += e.cost; m.input += e.input; m.output += e.output
            m.cacheWrite += e.cacheWrite; m.cacheRead += e.cacheRead
            m.thinking += e.thinking; m.messages += 1
            models[e.model] = m

            for t in e.tools { tools[toolGroup(t), default: 0] += 1 }

            let bStart = cal.dateInterval(of: s.bucketUnit, for: e.time)?.start ?? e.time
            let series = slots[e.project] != nil ? e.project : otherKey
            let key = "\(bStart.timeIntervalSince1970)|\(series)"
            var b = buckets[key] ?? Bucket(date: bStart, series: series, cost: 0, tokens: 0)
            b.cost += e.cost; b.tokens += e.totalTokens
            buckets[key] = b

            let wd = (cal.component(.weekday, from: e.time) + 5) % 7  // Mon=0
            s.punchcard[wd][cal.component(.hour, from: e.time)] += e.cost
        }

        for pr in slice(snap.prompts, iv, \.time) {
            s.prompts += 1
            projects[pr.project]?.prompts += 1
        }
        for t in slice(snap.turns, iv, \.time) {
            s.activeMs += t.durationMs
            projects[t.project]?.activeMs += t.durationMs
        }
        s.sessions = sessionIds.count

        // Sparklines: per-project cost per bucket across the range.
        let bucketDates = strideBuckets(iv, unit: s.bucketUnit, cal: cal)
        let index = Dictionary(bucketDates.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for e in events {
            guard let start = cal.dateInterval(of: s.bucketUnit, for: e.time)?.start, let i = index[start] else { continue }
            if projects[e.project]!.spark.isEmpty { projects[e.project]!.spark = Array(repeating: 0, count: bucketDates.count) }
            projects[e.project]!.spark[i] += e.cost
        }

        s.projects = projects.values.sorted { $0.cost > $1.cost }
        s.models = models.values.sorted { $0.cost > $1.cost }
        s.tools = tools.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        s.buckets = buckets.values.sorted { $0.date < $1.date }

        if let prev = range.previous(now: now, cal: cal) {
            s.prevCost = slice(snap.events, prev, \.time).reduce(0) { $0 + $1.cost }
        }
        return s
    }

    /// Bucket start dates covering the interval (for complete x-axes / sparklines).
    static func strideBuckets(_ iv: DateInterval, unit: Calendar.Component, cal: Calendar = .current) -> [Date] {
        guard var d = cal.dateInterval(of: unit, for: iv.start)?.start else { return [] }
        var out: [Date] = []
        while d < iv.end && out.count < 2000 {
            out.append(d)
            d = cal.next(d, unit: unit)
        }
        return out
    }

    /// Billing-style 5-hour windows: a block starts at the hour of the first message after the
    /// previous block expired, and lasts five hours.
    static func blocks(_ events: [UsageEvent], cal: Calendar = .current) -> [UsageBlock] {
        var out: [UsageBlock] = []
        for e in events {
            if var cur = out.last, e.time < cur.end {
                cur.cost += e.cost; cur.tokens += e.totalTokens; cur.messages += 1
                cur.lastEvent = e.time
                out[out.count - 1] = cur
            } else {
                let start = cal.dateInterval(of: .hour, for: e.time)?.start ?? e.time
                out.append(UsageBlock(start: start, lastEvent: e.time, cost: e.cost, tokens: e.totalTokens, messages: 1))
            }
        }
        return out
    }

    static func dailyCosts(_ events: [UsageEvent], cal: Calendar = .current) -> [Date: Double] {
        var out: [Date: Double] = [:]
        var days = DayCache(cal)
        for e in events { out[days.day(e.time), default: 0] += e.cost }
        return out
    }

    static func streaks(daily: [Date: Double], now: Date = Date(), cal: Calendar = .current) -> Streaks {
        var s = Streaks()
        let active = Set(daily.filter { $0.value > 0 }.keys)
        s.activeDays = active.count
        if let best = daily.max(by: { $0.value < $1.value }) { s.busiestDay = (best.key, best.value) }

        var day = cal.startOfDay(for: now)
        if !active.contains(day) { day = cal.day(day, plus: -1) } // today not over yet
        while active.contains(day) {
            s.current += 1
            day = cal.day(day, plus: -1)
        }
        var run = 0
        for d in active.sorted() {
            if active.contains(cal.day(d, plus: -1)) { run += 1 } else { run = 1 }
            s.longest = max(s.longest, run)
        }
        return s
    }

    /// Cost over the trailing window, for live burn rate.
    static func trailingCost(_ events: [UsageEvent], seconds: TimeInterval, now: Date = Date()) -> Double {
        var total = 0.0
        for e in events.reversed() {
            if now.timeIntervalSince(e.time) > seconds { break }
            total += e.cost
        }
        return total
    }

    /// mcp__server__tool -> "mcp: server"
    static func toolGroup(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                return "MCP · " + parts[1].replacingOccurrences(of: "claude-in-chrome", with: "chrome")
            }
        }
        return name
    }

    /// Binary-searched slice of a time-sorted array.
    static func slice<T>(_ arr: [T], _ iv: DateInterval, _ key: KeyPath<T, Date>) -> ArraySlice<T> {
        func lower(_ d: Date) -> Int {
            var lo = 0, hi = arr.count
            while lo < hi { let mid = (lo + hi) / 2; if arr[mid][keyPath: key] < d { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        let a = lower(iv.start), b = lower(iv.end.addingTimeInterval(0.001))
        return a < b ? arr[a..<b] : []
    }
}
