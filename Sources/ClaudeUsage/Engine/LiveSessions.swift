import Foundation
import Darwin

/// Reads ~/.claude/sessions/<pid>.json, which every running Claude Code process keeps
/// up to date with its status (busy / idle), cwd and session id.
enum LiveSessionReader {
    private struct Raw: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let name: String?
        let status: String?
        let kind: String?
        let entrypoint: String?
        let version: String?
        let startedAt: Double?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
        let bridgeSessionId: String?
        let procStart: String?
    }

    static var directories: [URL] { ClaudeConfig.dirs.map { $0.appendingPathComponent("sessions") } }

    /// "Sat Oct 10 15:39:08 2026" (UTC, ctime format) as written by Claude Code.
    private static let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    static func read() -> [LiveSession] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        var out: [LiveSession] = []
        var seenPids = Set<Int32>()
        for dir in directories {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f),
                      let r = try? decoder.decode(Raw.self, from: data),
                      isAlive(r.pid, procStart: r.procStart),     // check liveness before claiming the pid
                      seenPids.insert(r.pid).inserted else { continue }
                func date(_ ms: Double?) -> Date { ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast }
                out.append(LiveSession(
                    pid: r.pid, sessionId: r.sessionId, cwd: r.cwd ?? "",
                    name: r.name ?? ProjectPath.name(of: r.cwd ?? "claude"),
                    status: r.status ?? "unknown", kind: r.kind ?? "interactive",
                    entrypoint: r.entrypoint ?? "cli", version: r.version ?? "",
                    startedAt: date(r.startedAt), updatedAt: date(r.updatedAt),
                    statusUpdatedAt: date(r.statusUpdatedAt ?? r.updatedAt),
                    remote: r.bridgeSessionId != nil))
            }
        }
        return out.sorted {
            if $0.isBusy != $1.isBusy { return $0.isBusy }
            return $0.statusUpdatedAt > $1.statusUpdatedAt
        }
    }

    /// Stale files are left behind when a process dies; verify the pid is still a claude process.
    private static func isAlive(_ pid: Int32, procStart: String?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        // A dead session's pid can be reused by another process: compare process start times.
        if let raw = procStart,
           let expected = procStartFormat.date(from: raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
               abs(Double(info.pbi_start_tvsec) - expected.timeIntervalSince1970) > 3 { return false }
        }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf).lowercased()
            return path.contains("claude") || path.hasSuffix("/node") || path.hasSuffix("/bun")
        }
        // proc_pidpath can be denied (e.g. under a sandbox) even for live processes; the pid is alive
        // and the session file says it's Claude Code, so accept it rather than hide every session.
        return true
    }
}
