import Foundation

/// Synthetic but realistic history for `--demo` (screenshots, trying the app without Claude Code).
/// Deterministic: the same seed always produces the same data.
enum DemoData {
    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() * Double(r.count)) % r.count }
        mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
    }

    static let home = NSHomeDirectory()
    static let projects: [(name: String, weight: Double, model: String)] = [
        ("acme-api", 1.0, "claude-opus-5-5"),
        ("pixel-garden", 0.7, "claude-opus-5-5"),
        ("rust-raytracer", 0.5, "claude-fable-5-1"),
        ("landing-page", 0.35, "claude-sonnet-5-5"),
        ("dotfiles", 0.15, "claude-sonnet-5-5"),
        ("ml-notebooks", 0.25, "claude-opus-5"),
    ]
    static let titles = [
        "Add rate limiting to the public API", "Fix flaky checkout test", "Migrate auth to passkeys",
        "Garden tile renderer", "Refactor plant growth system", "BVH acceleration structure",
        "Soft shadows and area lights", "Hero section redesign", "Dark mode polish", "zsh startup speedup",
        "Tune the training loop", "Write onboarding docs", "Upgrade to the new SDK", "Cache warm-up job",
    ]
    static let prompts = [
        "can you add rate limiting to the /v2 endpoints, 100 req/min per key",
        "the checkout test is flaky on CI again, figure out why",
        "let's make the tiles render in batches, it's dropping frames",
        "implement a BVH so we stop testing every triangle",
        "ship it — open a PR when tests pass",
        "dark mode looks muddy on the cards, fix the contrast",
        "why is zsh taking 900ms to start",
        "write a migration for the new sessions table",
        "great, now add tests for the edge cases",
        "explain what this function is doing before we refactor it",
        "profile the render loop and tell me the top 3 hotspots",
        "commit this and push",
    ]

    static func path(_ name: String) -> String { home + "/code/" + name }

    static func snapshot(now: Date = Date()) -> Snapshot {
        var rng = RNG(state: 0xC1A0DE)
        let cal = Calendar.current
        var snap = Snapshot()
        let today = cal.startOfDay(for: now)

        for dayOffset in stride(from: 59, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -dayOffset, to: today)!
            let weekday = cal.component(.weekday, from: day)
            // skip some days (more on weekends), but keep a streak running into today
            let skip = dayOffset > 9 && rng.next() < (weekday == 1 || weekday == 7 ? 0.55 : 0.18)
            if skip { continue }
            let sessionsToday = rng.int(1...3)
            for _ in 0..<sessionsToday {
                let proj = weightedProject(&rng)
                let sid = UUID(uuid: uuidBytes(&rng)).uuidString.lowercased()
                var hour = Double(rng.int(8...21)) + rng.next()
                if dayOffset == 0 { hour = min(hour, Double(cal.component(.hour, from: now)) - 0.8) }
                if hour < 0 { continue }
                var t = day.addingTimeInterval(hour * 3600)
                let start = t
                var context = rng.int(12_000...30_000)
                var summary = SessionSummary(id: sid, project: path(proj.name), cwd: path(proj.name),
                                             title: rng.pick(titles), lastPrompt: nil,
                                             branch: rng.pick(["main", "feat/rate-limit", "fix/flaky-test", "bvh", "dark-mode"]),
                                             version: "2.1.300", start: t, end: t)
                let promptCount = rng.int(2...12)
                for _ in 0..<promptCount {
                    let text = rng.pick(prompts)
                    snap.prompts.append(PromptEvent(time: t, sessionId: sid, project: path(proj.name), text: text))
                    summary.lastPrompt = text
                    summary.prompts += 1
                    let replies = rng.int(3...18)
                    var turnMs = 0.0
                    for r in 0..<replies {
                        t = t.addingTimeInterval(Double(rng.int(4...40)))
                        turnMs += Double(rng.int(4...40)) * 1000
                        let out = rng.int(150...2400)
                        let write = r == 0 ? rng.int(2_000...9_000) : rng.int(200...2_500)
                        context = min(context + write, 980_000)
                        let sub = rng.next() < 0.12
                        let tools = (0..<rng.int(0...2)).map { _ in rng.pick(["Bash", "Bash", "Read", "Edit", "Write", "Grep", "WebSearch"]) }
                        let model = sub ? "claude-sonnet-5-5" : proj.model
                        let cost = Pricing.cost(model: model, input: 6, output: out, cw5m: 0, cw1h: write, cacheRead: context, fast: false)
                        let e = UsageEvent(time: t, sessionId: sid, project: path(proj.name), model: model,
                                           input: 6, output: out, cacheWrite5m: 0, cacheWrite1h: write, cacheRead: context,
                                           thinking: out / 2, webSearches: tools.contains("WebSearch") ? 1 : 0, fast: false,
                                           cost: cost, tools: tools, isSubagent: sub,
                                           commits: rng.next() < 0.03 ? 1 : nil, ctxWindow: 1_000_000)
                        snap.events.append(e)
                        summary.cost += cost; summary.tokens += e.totalTokens; summary.outputTokens += out
                        summary.messages += 1
                        summary.models[model, default: 0] += cost
                        for tl in tools { summary.tools[tl, default: 0] += 1 }
                        if sub { summary.subagentCost += cost }
                        summary.commits = (summary.commits ?? 0) + (e.commits ?? 0)
                    }
                    snap.turns.append(TurnEvent(time: t, sessionId: sid, project: path(proj.name), durationMs: turnMs))
                    summary.activeMs += turnMs
                    t = t.addingTimeInterval(Double(rng.int(60...900)))
                }
                if rng.next() < 0.22 {
                    let n = 40 + snap.prs.count
                    let pr = PRLink(number: n, url: "https://github.com/example/\(proj.name)/pull/\(n)", repo: "example/\(proj.name)",
                                    time: t, sessionId: sid, project: path(proj.name))
                    snap.prs.append(pr)
                    summary.prs.append(pr)
                }
                summary.subagentCount = rng.int(0...4)
                summary.end = t
                summary.context = context
                summary.contextWindow = 1_000_000
                summary.compactions = context > 900_000 ? 1 : 0
                _ = start
                snap.sessions[sid] = summary
            }
        }
        snap.events.sort { $0.time < $1.time }
        snap.prompts.sort { $0.time < $1.time }
        snap.turns.sort { $0.time < $1.time }
        snap.prs.sort { $0.time > $1.time }
        snap.filesScanned = snap.sessions.count
        return snap
    }

    /// Live sessions: the most recent sessions of today, one busy, one waiting.
    static func live(_ snap: Snapshot, now: Date = Date()) -> [LiveSession] {
        let recent = snap.sessions.values.sorted { $0.end > $1.end }.prefix(3)
        return recent.enumerated().map { i, s in
            LiveSession(pid: Int32(90_000 + i), sessionId: s.id, cwd: s.cwd, name: ProjectPath.name(of: s.project),
                        status: i == 0 ? "busy" : "idle", kind: "interactive", entrypoint: "cli", version: "2.1.300",
                        startedAt: s.start, updatedAt: now,
                        statusUpdatedAt: i == 0 ? now.addingTimeInterval(-240) : now.addingTimeInterval(-Double(600 + i * 1500)),
                        remote: false)
        }
    }

    static func plan(now: Date = Date()) -> PlanStatus {
        PlanStatus(limits: [
            PlanLimit(key: "five_hour", label: PlanLimitsClient.label(for: "five_hour"), percent: 42, resetsAt: now.addingTimeInterval(2.4 * 3600)),
            PlanLimit(key: "seven_day", label: PlanLimitsClient.label(for: "seven_day"), percent: 63, resetsAt: now.addingTimeInterval(3.2 * 86400)),
            PlanLimit(key: "seven_day_opus", label: PlanLimitsClient.label(for: "seven_day_opus"), percent: 71, resetsAt: now.addingTimeInterval(3.2 * 86400)),
        ], plan: "Max", fetchedAt: now.addingTimeInterval(-50), error: nil)
    }

    private static func weightedProject(_ rng: inout RNG) -> (name: String, weight: Double, model: String) {
        let total = projects.reduce(0) { $0 + $1.weight }
        var x = rng.next() * total
        for p in projects { x -= p.weight; if x <= 0 { return p } }
        return projects[0]
    }

    private static func uuidBytes(_ rng: inout RNG) -> uuid_t {
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { b[i] = UInt8(rng.int(0...255)) }
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
}
