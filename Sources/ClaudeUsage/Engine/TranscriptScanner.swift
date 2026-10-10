import Foundation

// MARK: - Raw transcript line shapes (only the fields we need)

private struct RawLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let isSidechain: Bool?
    let requestId: String?
    let message: RawMessage?
    let aiTitle: String?
    let lastPrompt: String?
    let prNumber: Int?
    let prUrl: String?
    let prRepository: String?
    let subtype: String?
    let durationMs: Double?
    let origin: Origin?
    let isMeta: Bool?
    let compactMetadata: CompactMetadata?
    let uuid: String?
    let isCompactSummary: Bool?

    struct Origin: Decodable { let kind: String? }
    struct CompactMetadata: Decodable { let trigger: String?; let preTokens: Int? }
}

private struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
    let content: RawContent?
}

private struct RawUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
    let cache_creation: CacheCreation?
    let output_tokens_details: OutputDetails?
    let server_tool_use: ServerToolUse?
    let speed: String?

    struct CacheCreation: Decodable {
        let ephemeral_5m_input_tokens: Int?
        let ephemeral_1h_input_tokens: Int?
    }
    struct OutputDetails: Decodable { let thinking_tokens: Int? }
    struct ServerToolUse: Decodable { let web_search_requests: Int? }
}

private enum RawContent: Decodable {
    case text(String)
    case blocks([Block])

    struct Block: Decodable {
        let type: String?
        let name: String?
        let text: String?
        let input: ToolInput?
    }
    struct ToolInput: Decodable { let command: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        self = .blocks((try? c.decode([Block].self)) ?? [])
    }
}

// MARK: - Per-file incremental state

private final class FileState {
    let url: URL
    let isSubagent: Bool
    let dirProject: String
    var offset: UInt64 = 0
    var inode: UInt64 = 0

    var events: [String: UsageEvent] = [:]
    var prompts: [PromptEvent] = []
    var turns: [TurnEvent] = []
    var prs: [Int: PRLink] = [:]
    var compactions: [CompactEvent] = []

    var sessionId: String?
    /// The launch directory: the first cwd seen. Later records follow the shell's `cd`s.
    var cwd: String?
    var title: String?
    var lastPrompt: String?
    var branch: String?
    var version: String?
    var first: Date?
    var last: Date?

    init(url: URL, isSubagent: Bool, dirProject: String) {
        self.url = url
        self.isSubagent = isSubagent
        self.dirProject = dirProject
    }

    func reset() {
        offset = 0
        events = [:]; prompts = []; turns = []; prs = [:]; compactions = []
        sessionId = nil; cwd = nil; title = nil; lastPrompt = nil
        branch = nil; version = nil; first = nil; last = nil
    }

    var project: String { ProjectPath.root(of: cwd ?? dirProject) }
}

// MARK: - Scanner

/// Incrementally tails every Claude Code transcript. The first pass reads everything;
/// later passes only read bytes appended since the previous pass.
actor TranscriptScanner {
    private var files: [String: FileState] = [:]
    private let decoder = JSONDecoder()
    private var archive: Archive
    private var archiveDirty = false
    private var lastArchiveSave = Date.distantPast
    private let persist: Bool

    /// `persist`: save the archive. `loadArchive`: include archived history (read-only when not persisting).
    init(persist: Bool = true, loadArchive: Bool? = nil) {
        if loadArchive ?? persist, let a = Archive.load(sideEffects: persist) {
            archive = a
            self.persist = persist
        } else {
            archive = Archive()
            // An existing archive we couldn't read must never be overwritten.
            self.persist = persist && !FileManager.default.fileExists(atPath: Archive.url.path)
        }
        if self.persist { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Archive.url.deletingLastPathComponent().path) }
    }

    static var roots: [URL] {
        var seen = Set<String>()
        return ClaudeConfig.dirs.map { $0.appendingPathComponent("projects").resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
    }

    func scan() -> Snapshot {
        let started = Date()
        var bytes: Int64 = 0
        let fm = FileManager.default
        var live = Set<String>()

        for root in Self.roots {
            guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in projectDirs where dir.hasDirectoryPath {
                let dirProject = ProjectPath.fromProjectDir(dir.lastPathComponent)
                guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for entry in entries {
                    if entry.pathExtension == "jsonl" {
                        live.insert(entry.path)
                        bytes += ingest(entry, isSubagent: false, dirProject: dirProject)
                    } else if entry.hasDirectoryPath {
                        let sub = entry.appendingPathComponent("subagents")
                        guard let agents = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
                        for a in agents where a.pathExtension == "jsonl" {
                            live.insert(a.path)
                            bytes += ingest(a, isSubagent: true, dirProject: dirProject)
                        }
                    }
                }
            }
        }
        files = files.filter { live.contains($0.key) }

        var snap = buildSnapshot()
        if persist, archiveDirty, Date().timeIntervalSince(lastArchiveSave) > 120 {
            archive.save()
            archiveDirty = false
            lastArchiveSave = Date()
        }
        snap.bytesScanned = bytes
        snap.scanDuration = Date().timeIntervalSince(started)
        return snap
    }

    /// Forget everything not currently on disk (Settings → Clear archive).
    func clearArchive() {
        guard persist else { return }   // never touch the real archive from demo/snapshot/dump runs
        archive = Archive()
        let dir = Archive.url.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where f == "archive.json" || f.hasPrefix("archive.unreadable-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        for f in files.values { f.reset() }   // re-read live transcripts on next scan
        archiveDirty = true
        lastArchiveSave = .distantPast
    }

    /// Returns the number of new bytes read.
    private func ingest(_ url: URL, isSubagent: Bool, dirProject: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return 0 }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        let state: FileState
        if let s = files[url.path] {
            state = s
            if size < s.offset || inode != s.inode { s.reset() }   // truncated or replaced
        } else {
            state = FileState(url: url, isSubagent: isSubagent, dirProject: dirProject)
            files[url.path] = state
        }
        state.inode = inode
        guard size > state.offset else { return 0 }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) } catch { return 0 }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return 0 }

        // Only consume complete lines; a partially-written trailing line waits for next pass.
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let nl = memchr(base + start, 0x0A, count - start) else { break }
                let end = UnsafeRawPointer(nl).assumingMemoryBound(to: UInt8.self) - base
                if end > start {
                    parseLine(UnsafeBufferPointer(start: base + start, count: end - start), into: state)
                }
                start = end + 1
                consumed = start
            }
        }
        state.offset += UInt64(consumed)
        return Int64(consumed)
    }

    private static let assistantNeedle = Array(#""type":"assistant""#.utf8)

    private func parseLine(_ bytes: UnsafeBufferPointer<UInt8>, into s: FileState) {
        // Giant lines are tool results / attachments; skip unless they're an assistant message.
        if bytes.count > 400_000 {
            let found = Self.assistantNeedle.withUnsafeBufferPointer { n in
                memmem(bytes.baseAddress, bytes.count, n.baseAddress, n.count) != nil
            }
            if !found { return }
        }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none)
        guard let line = try? decoder.decode(RawLine.self, from: data) else { return }

        if let sid = line.sessionId, s.sessionId == nil { s.sessionId = sid }
        if s.cwd == nil, let cwd = line.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let b = line.gitBranch, !b.isEmpty, b != "HEAD" { s.branch = b }
        if let v = line.version { s.version = v }
        let time = line.timestamp.flatMap(FastISO8601.parse)
        if let t = time {
            if s.first == nil || t < s.first! { s.first = t }
            if s.last == nil || t > s.last! { s.last = t }
        }

        switch line.type {
        case "assistant":
            guard let msg = line.message, let usage = msg.usage, let t = time else { return }
            let model = Pricing.normalize(msg.model ?? "unknown")
            if model == "<synthetic>" { return }
            // Stable across launches (a random fallback would double-count via the archive).
            let key = "\(msg.id ?? line.uuid ?? "\(t.timeIntervalSince1970)"):\(line.requestId ?? "")"
            let input = usage.input_tokens ?? 0
            let output = usage.output_tokens ?? 0
            let cr = usage.cache_read_input_tokens ?? 0
            var cw5 = usage.cache_creation?.ephemeral_5m_input_tokens ?? 0
            let cw1 = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
            if usage.cache_creation == nil { cw5 = usage.cache_creation_input_tokens ?? 0 }
            let fast = usage.speed == "fast"

            var tools: [String] = []
            var commits = 0
            if case .blocks(let blocks)? = msg.content {
                for b in blocks where b.type == "tool_use" {
                    if let n = b.name { tools.append(n) }
                    if b.name == "Bash", let cmd = b.input?.command, cmd.contains("git commit") { commits += 1 }
                }
            }
            // A message spans several lines (one per content block); merge tool names.
            if let prev = s.events[key] { tools = prev.tools + tools; commits += prev.commits ?? 0 }
            let raw = msg.model ?? ""
            let window = raw.contains("[1m]") || Pricing.contextWindow(model) >= 1_000_000 ? 1_000_000 : Pricing.contextWindow(model)

            s.events[key] = UsageEvent(
                time: t,
                sessionId: line.sessionId ?? s.sessionId ?? "",
                project: s.project,
                model: model,
                input: input, output: output,
                cacheWrite5m: cw5, cacheWrite1h: cw1, cacheRead: cr,
                thinking: usage.output_tokens_details?.thinking_tokens ?? 0,
                webSearches: usage.server_tool_use?.web_search_requests ?? 0,
                fast: fast,
                cost: Pricing.cost(model: model, input: input, output: output, cw5m: cw5, cw1h: cw1, cacheRead: cr, fast: fast),
                tools: tools,
                isSubagent: s.isSubagent || (line.isSidechain ?? false),
                commits: commits > 0 ? commits : nil,
                ctxWindow: window
            )

        case "user":
            guard !s.isSubagent, let t = time else { return }
            var text = ""
            var isToolResult = false
            switch line.message?.content {
            case .text(let str)?: text = str
            case .blocks(let blocks)?:
                isToolResult = blocks.contains { $0.type == "tool_result" }
                text = blocks.compactMap(\.text).first ?? "(attachment)"
            case nil: break
            }
            if let kind = line.origin?.kind {
                guard kind == "human" else { return }
            } else {
                // Older Claude Code versions don't write `origin`: infer a typed prompt.
                let machine = ["Caveat:", "[Request interrupted"]
                let wrapped = text.range(of: "^\\s*<[a-zA-Z][a-zA-Z0-9_-]*[ >]", options: .regularExpression) != nil
                guard !isToolResult, !wrapped, line.isMeta != true, line.isCompactSummary != true, line.isSidechain != true,
                      !machine.contains(where: { text.hasPrefix($0) }) else { return }
            }
            s.prompts.append(PromptEvent(time: t, sessionId: s.sessionId ?? "", project: s.project,
                                         text: Self.clean(text)))

        case "ai-title":
            if let title = line.aiTitle, !title.isEmpty { s.title = title }

        case "last-prompt":
            if let p = line.lastPrompt, !p.isEmpty { s.lastPrompt = Self.clean(p) }

        case "pr-link":
            if let n = line.prNumber, let url = line.prUrl {
                s.prs[n] = PRLink(number: n, url: url, repo: line.prRepository ?? "",
                                  time: time ?? Date(), sessionId: s.sessionId ?? "", project: s.project)
            }

        case "system":
            if line.subtype == "turn_duration", let ms = line.durationMs, let t = time, !s.isSubagent {
                s.turns.append(TurnEvent(time: t, sessionId: s.sessionId ?? "", project: s.project, durationMs: ms))
            }
            if line.subtype == "compact_boundary", let t = time, !s.isSubagent {
                s.compactions.append(CompactEvent(time: t, sessionId: s.sessionId ?? "",
                                                  preTokens: line.compactMetadata?.preTokens ?? 0,
                                                  auto: line.compactMetadata?.trigger == "auto"))
            }

        default:
            break
        }
    }

    /// Prompt preview: drop wrapper tags like <pasted_content …>, collapse whitespace.
    private static func clean(_ raw: String) -> String {
        var t = String(raw.prefix(2000))
        t = t.replacingOccurrences(of: "<pasted_content[^>]*>", with: "[pasted] ", options: .regularExpression)
        t = t.replacingOccurrences(of: "</?[a-zA-Z_-]+[^>]*>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(t.trimmingCharacters(in: .whitespaces).prefix(280))
    }

    private func buildSnapshot() -> Snapshot {
        var snap = Snapshot()
        snap.filesScanned = files.count
        var seen = Set<String>()
        var sessions: [String: SessionSummary] = [:]
        var prs: [String: PRLink] = [:]

        // Main transcripts first so their metadata wins over subagent files.
        let ordered = files.values.sorted { a, b in
            if a.isSubagent != b.isSubagent { return !a.isSubagent }
            return a.url.path < b.url.path
        }

        for f in ordered {
            guard let sid = f.sessionId, let first = f.first, let last = f.last else { continue }
            var sess = sessions[sid] ?? SessionSummary(id: sid, project: f.project, cwd: f.cwd ?? f.dirProject,
                                                       start: first, end: last)
            sess.start = min(sess.start, first)
            sess.end = max(sess.end, last)
            if !f.isSubagent {
                if let t = f.title { sess.title = t }
                if let p = f.lastPrompt { sess.lastPrompt = p }
                if let b = f.branch { sess.branch = b }
                if let v = f.version { sess.version = v }
                if let c = f.cwd { sess.cwd = c; sess.project = f.project }
                sess.prompts += f.prompts.count
                sess.activeMs += f.turns.reduce(0) { $0 + $1.durationMs }
            } else {
                sess.subagentCount += 1
            }

            if !f.isSubagent {
                sess.compactions = (sess.compactions ?? 0) + f.compactions.count
                snap.compactions.append(contentsOf: f.compactions)
                // Context fill = prompt size of the latest main-thread reply.
                if let latest = f.events.values.max(by: { $0.time < $1.time }) {
                    sess.context = latest.contextSize
                    sess.contextWindow = latest.ctxWindow ?? Pricing.contextWindow(latest.model)
                }
            }
            for (key, var e) in f.events where seen.insert(key).inserted {
                e.project = sess.project   // subagents inherit the parent session's project
                if let c = e.commits { sess.commits = (sess.commits ?? 0) + c }
                snap.events.append(e)
                sess.cost += e.cost
                sess.tokens += e.totalTokens
                sess.outputTokens += e.output
                sess.messages += 1
                sess.models[e.model, default: 0] += e.cost
                for t in e.tools { sess.tools[t, default: 0] += 1 }
                if e.isSubagent { sess.subagentCost += e.cost }
            }
            snap.prompts.append(contentsOf: f.prompts)
            snap.turns.append(contentsOf: f.turns)
            for pr in f.prs.values { prs[pr.url] = pr }
            sess.prs = Array(Set(sess.prs + f.prs.values)).sorted { $0.number < $1.number }
            sessions[sid] = sess
        }

        mergeArchive(into: &snap, sessions: &sessions, prs: &prs, seen: seen)

        snap.events.sort { $0.time < $1.time }
        snap.prompts.sort { $0.time < $1.time }
        snap.turns.sort { $0.time < $1.time }
        snap.compactions.sort { $0.time < $1.time }
        snap.prs = prs.values.sorted { $0.time > $1.time }
        snap.sessions = sessions
        return snap
    }
}

// MARK: - Archive (history that outlives Claude Code's transcript cleanup)

/// Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30). Everything we've
/// ever parsed is kept here so long-range charts don't silently shrink.
struct Archive: Codable {
    var version = 1
    var events: [String: UsageEvent] = [:]
    var prompts: [String: PromptEvent] = [:]
    var turns: [String: TurnEvent] = [:]
    var sessions: [String: SessionSummary] = [:]
    var prs: [String: PRLink] = [:]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("archive.json")
    }

    /// nil = an archive exists but couldn't be read (caller must not overwrite it).
    static func load(sideEffects: Bool) -> Archive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return Archive() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let a = try? JSONDecoder().decode(Archive.self, from: data), a.version <= 1 { return a }
        guard sideEffects else { return nil }
        // Unreadable (corrupt, or written by a newer build): set it aside instead of overwriting it.
        let backup = url.deletingLastPathComponent().appendingPathComponent("archive.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: backup)
        NSLog("ClaudeUsage: archive unreadable, moved to \(backup.lastPathComponent)")
        return Archive()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        // Contains prompt previews: keep it private to this user.
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

extension TranscriptScanner {
    fileprivate func mergeArchive(into snap: inout Snapshot, sessions: inout [String: SessionSummary],
                                  prs: inout [String: PRLink], seen: Set<String>) {
        // 1. Remember everything currently on disk.
        for f in files.values {
            for (k, e) in f.events {
                // Overwrite when a reply grew since we archived it (usage is updated across its lines).
                if let old = archive.events[k], old.output == e.output, old.tools.count == e.tools.count { continue }
                archive.events[k] = e; archiveDirty = true
            }
            for p in f.prompts {
                let k = "\(p.sessionId)|\(p.time.timeIntervalSince1970)"
                if archive.prompts[k] == nil { archive.prompts[k] = p; archiveDirty = true }
            }
            for t in f.turns {
                let k = "\(t.sessionId)|\(t.time.timeIntervalSince1970)"
                if archive.turns[k] == nil { archive.turns[k] = t; archiveDirty = true }
            }
        }
        for (id, s) in sessions {
            if archive.sessions[id]?.end != s.end || archive.sessions[id]?.cost != s.cost { archive.sessions[id] = s; archiveDirty = true }
        }
        for (u, pr) in prs where archive.prs[u] == nil { archive.prs[u] = pr; archiveDirty = true }

        // 2. Restore what Claude Code has deleted.
        let liveSessions = Set(sessions.keys)
        var promptKeys = Set(snap.prompts.map { "\($0.sessionId)|\($0.time.timeIntervalSince1970)" })
        var turnKeys = Set(snap.turns.map { "\($0.sessionId)|\($0.time.timeIntervalSince1970)" })
        for (k, e) in archive.events where !seen.contains(k) {
            var e = e
            if let s = archive.sessions[e.sessionId] { e.project = s.project }
            snap.events.append(e)
        }
        for (k, p) in archive.prompts where promptKeys.insert(k).inserted { snap.prompts.append(p) }
        for (k, t) in archive.turns where turnKeys.insert(k).inserted { snap.turns.append(t) }
        for (id, s) in archive.sessions where !liveSessions.contains(id) {
            sessions[id] = s
            snap.archivedSessions += 1
        }
        for (u, pr) in archive.prs where prs[u] == nil { prs[u] = pr }
    }
}

// MARK: - Fast fixed-format ISO-8601 parser ("2026-09-20T20:51:18.296Z")

enum FastISO8601 {
    static func parse(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { p -> Date? in
            guard p.count >= 19 else { return nil }
            func num(_ i: Int, _ n: Int) -> Int? {
                var v = 0
                for k in i..<(i + n) {
                    let c = p[k]
                    guard c >= 48 && c <= 57 else { return nil }
                    v = v * 10 + Int(c - 48)
                }
                return v
            }
            guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
                  let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
                  (2000...2200).contains(y), (1...12).contains(mo), (1...31).contains(d) else { return nil }
            var frac = 0.0
            var i = 19
            if i < p.count && p[i] == 46 {  // '.'
                var scale = 0.1
                i += 1
                while i < p.count, p[i] >= 48, p[i] <= 57 {
                    frac += Double(p[i] - 48) * scale
                    scale /= 10
                    i += 1
                }
            }
            var offset = 0
            if i < p.count, p[i] == 43 || p[i] == 45, p.count >= i + 6,
               let oh = num(i + 1, 2), let om = num(i + 4, 2) {
                offset = (oh * 3600 + om * 60) * (p[i] == 43 ? 1 : -1)
            }
            // days from civil (Howard Hinnant)
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let mp = (mo + 9) % 12
            let doy = (153 * mp + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146097 + doe - 719468
            let secs = Double(days * 86400 + h * 3600 + mi * 60 + se - offset) + frac
            return Date(timeIntervalSince1970: secs)
        }
    }
}
