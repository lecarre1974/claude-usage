import Foundation

/// Real plan limits (what `/usage` shows in Claude Code), read with Claude Code's own OAuth login.
///
/// Safety rules: the token is read from the Keychain on demand and only ever sent to
/// api.anthropic.com. We never refresh or modify the stored credentials — if the token is
/// expired we wait for Claude Code to refresh it.
struct PlanLimit: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let label: String
    let percent: Double      // 0...100
    let resetsAt: Date?
}

struct PlanStatus: Equatable {
    var limits: [PlanLimit] = []
    var plan: String?
    var fetchedAt: Date?
    var error: String?

    var fiveHour: PlanLimit? { limits.first { $0.key == "five_hour" } }
    var weekly: [PlanLimit] { limits.filter { $0.key != "five_hour" } }
    var isConnected: Bool { !limits.isEmpty && error == nil }
}

/// Refuses every redirect so the Authorization header can never be forwarded elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PlanLimitsClient {
    /// Ephemeral: no disk cache, no cookies, no credential storage.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let keychainService = "Claude Code-credentials"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth?
    }

    /// Uses /usr/bin/security, which Claude Code's keychain item already trusts, so there's
    /// no per-rebuild "allow access" prompt for this ad-hoc-signed app.
    private static func readCredentials() -> Credentials.OAuth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? JSONDecoder().decode(Credentials.self, from: data))?.claudeAiOauth
    }

    static func fetch() async -> PlanStatus {
        var status = PlanStatus()
        guard let creds = readCredentials(), let token = creds.accessToken, !token.isEmpty else {
            status.error = "No Claude Code login found in Keychain"
            return status
        }
        status.plan = creds.subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let exp = creds.expiresAt, Date(timeIntervalSince1970: exp / 1000) < Date() {
            status.error = "Login token expired — it refreshes next time Claude Code runs"
            return status
        }

        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-menubar/1.0", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                status.error = code == 401 ? "Login token rejected (401) — waiting for Claude Code to refresh it"
                                           : code == 429 ? "Rate limited by the usage endpoint; will retry"
                                           : "Usage endpoint returned HTTP \(code)"
                return status
            }
            status.limits = parse(data)
            status.fetchedAt = Date()
            if status.limits.isEmpty { status.error = "Usage response had no limits I recognise" }
        } catch {
            status.error = "Couldn't reach api.anthropic.com (\(error.localizedDescription))"
        }
        return status
    }

    /// Accepts any top-level `{ "<name>": { "utilization": n, "resets_at": "…" } }` entries.
    static func parse(_ data: Data) -> [PlanLimit] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [PlanLimit] = []
        for (key, value) in obj {
            guard let d = value as? [String: Any], let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resets = (d["resets_at"] as? String).flatMap { FastISO8601.parse($0) ?? ISO8601DateFormatter().date(from: $0) }
            out.append(PlanLimit(key: key, label: label(for: key), percent: max(0, u), resetsAt: resets))
        }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return out.sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour session"
        case "seven_day": return "Weekly · all models"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        case "seven_day_oauth_apps": return "Weekly · apps"
        default:
            return key.replacingOccurrences(of: "seven_day", with: "weekly")
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
