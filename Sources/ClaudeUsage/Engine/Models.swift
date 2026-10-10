import Foundation

/// One billed API response (deduplicated across the multiple transcript lines it spans).
struct UsageEvent: Codable {
    let time: Date
    let sessionId: String
    var project: String
    let model: String
    let input: Int
    let output: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    let thinking: Int
    let webSearches: Int
    let fast: Bool
    let cost: Double
    let tools: [String]
    let isSubagent: Bool
    /// `git commit` invocations in this reply's Bash calls (optional: older archives lack it).
    var commits: Int? = nil
    /// Context window of the model that produced it (1M unless it's an older 200k model).
    var ctxWindow: Int? = nil

    /// Tokens in the prompt for this reply = how full the context window was.
    var contextSize: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var totalTokens: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
    /// Tokens that were freshly processed (excludes cheap cache reads).
    var freshTokens: Int { input + output + cacheWrite5m + cacheWrite1h }
}

struct PromptEvent: Codable {
    let time: Date
    let sessionId: String
    let project: String
    let text: String
}

struct TurnEvent: Codable {
    let time: Date
    let sessionId: String
    let project: String
    let durationMs: Double
}

struct CompactEvent: Codable {
    let time: Date
    let sessionId: String
    let preTokens: Int
    let auto: Bool
}

struct PRLink: Hashable, Codable {
    let number: Int
    let url: String
    let repo: String
    let time: Date
    let sessionId: String
    let project: String
}

/// Everything known about one Claude Code session, rolled up from its transcript(s).
struct SessionSummary: Identifiable, Codable {
    let id: String
    var project: String
    var cwd: String
    var title: String?
    var lastPrompt: String?
    var branch: String?
    var version: String?
    var start: Date
    var end: Date
    var cost: Double = 0
    var tokens: Int = 0
    var outputTokens: Int = 0
    var messages: Int = 0
    var prompts: Int = 0
    var activeMs: Double = 0
    var subagentCost: Double = 0
    var subagentCount: Int = 0
    var models: [String: Double] = [:]
    var tools: [String: Int] = [:]
    var prs: [PRLink] = []
    // Optional so archives written by older builds still decode.
    var compactions: Int? = nil
    var context: Int? = nil
    var contextWindow: Int? = nil
    var commits: Int? = nil
    var contextFraction: Double {
        guard let c = context, let w = contextWindow, w > 0 else { return 0 }
        return Double(c) / Double(w)
    }
    var isWorktree: Bool { cwd.contains("/.claude/worktrees/") }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var primaryModel: String? { models.max { $0.value < $1.value }?.key }
}

/// A live Claude Code process, from ~/.claude/sessions/<pid>.json.
struct LiveSession: Identifiable, Equatable {
    var id: String { "\(pid)-\(sessionId)" }
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String
    let status: String
    let kind: String
    let entrypoint: String
    let version: String
    let startedAt: Date
    let updatedAt: Date
    let statusUpdatedAt: Date
    let remote: Bool

    var isBusy: Bool { status == "busy" }
    var project: String { ProjectPath.root(of: cwd) }
}

/// The immutable result of a scan, handed to the UI.
struct Snapshot {
    var events: [UsageEvent] = []          // sorted by time
    var prompts: [PromptEvent] = []        // sorted by time
    var turns: [TurnEvent] = []
    var prs: [PRLink] = []
    var compactions: [CompactEvent] = []
    var sessions: [String: SessionSummary] = [:]
    var filesScanned = 0
    var archivedSessions = 0   // sessions whose transcripts Claude Code has since deleted
    var bytesScanned: Int64 = 0
    var scanDuration: TimeInterval = 0
    var generatedAt = Date()
}

/// Claude Code config folders: ~/.claude, ~/.config/claude, $CLAUDE_CONFIG_DIR, plus any the user
/// adds in Settings (apps launched from Finder don't inherit shell environment variables).
enum ClaudeConfig {
    static let extraDirsKey = "extraConfigDirs"

    static var dirs: [URL] {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { candidates += env.split(separator: ",").map(String.init) }
        if let extra = UserDefaults.standard.string(forKey: extraDirsKey) {
            candidates += extra.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [home + "/.claude", home + "/.config/claude"]
        var seen = Set<String>()
        return candidates.compactMap { raw -> URL? in
            guard !raw.isEmpty else { return nil }
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()   // a symlinked dir must not be read twice
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, seen.insert(url.path).inserted else { return nil }
            return url
        }
    }
}

enum ProjectPath {
    /// Worktrees (`repo/.claude/worktrees/foo`) roll up into their parent repo.
    static func root(of cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        return cwd
    }

    static func name(of path: String) -> String {
        let n = (path as NSString).lastPathComponent
        return n.isEmpty ? path : n
    }

    static func pretty(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Fallback when a transcript has no cwd: decode the project dir name (lossy: '-' ambiguity).
    static func fromProjectDir(_ dir: String) -> String {
        dir.replacingOccurrences(of: "-", with: "/")
    }
}
