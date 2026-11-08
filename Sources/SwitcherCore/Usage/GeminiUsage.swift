import Foundation

/// Gemini CLI usage adapter: Keychain first, then the legacy bounded auth file,
/// followed by loadCodeAssist -> retrieveUserQuota.
public struct GeminiUsageCollector: Sendable {
    public static let rowID = "gemini:current"
    public static let rowAccountRef = "current"
    private static let assistURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let runner: any UsageProcessRunner
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                runner: any UsageProcessRunner,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = [:],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.credentials = credentials
        self.runner = runner; self.home = home; self.environment = environment; self.now = now
    }

    private enum CredentialResult {
        case token(String)
        case unavailable(UsageProblem)
    }

    private func token() -> CredentialResult {
        guard environment["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"] != "true" else {
            return .unavailable(.noSignIn)
        }
        let keychain = runner.run(UsageProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", "main-account",
                        "-s", "gemini-cli-oauth", "-w"],
            environment: SystemClaudeAppControl.cleanEnvironment(from: environment),
            workingDirectory: FileManager.default.temporaryDirectory,
            maxOutputBytes: 64 * 1024, timeout: 3))
        switch keychain.outcome {
        case .exited(0):
            let raw = keychain.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard let data = raw.data(using: .utf8),
                      let object = UsageJSON.object(data),
                      object["serverName"] as? String == "main-account",
                      let token = object["token"] as? [String: Any],
                      let expiry = UsageJSON.double(token["expiresAt"]),
                      let access = UsageJSON.token(token["accessToken"]) else {
                    return .unavailable(.schemaChanged)
                }
                guard expiry > now().timeIntervalSince1970 * 1000 else {
                    return .unavailable(.noSignIn)
                }
                return .token(access)
            }
        case .outputLimit:
            return .unavailable(.schemaChanged)
        default:
            break
        }
        guard let data = credentials.read(home.appendingPathComponent(".gemini/oauth_creds.json")) else {
            return .unavailable(.noSignIn)
        }
        guard let object = UsageJSON.object(data),
              let expiry = UsageJSON.double(object["expiry_date"]),
              let access = UsageJSON.token(object["access_token"]) else {
            return .unavailable(.schemaChanged)
        }
        guard expiry > now().timeIntervalSince1970 * 1000 else {
            return .unavailable(.noSignIn)
        }
        return .token(access)
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], plan: String? = nil) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .gemini, accountRef: Self.rowAccountRef,
                         label: "Gemini", plan: plan, windows: windows,
                         state: state, readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        let key: String
        switch token() {
        case .token(let access): key = access
        case .unavailable(let problem): return [finish(.unavailable(problem))]
        }
        let headers = ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]

        // Step 1: project id — the opaque project string is serialized as JSON, never
        // interpolated into a URL.
        let meta = UsageHTTPRequest(url: Self.assistURL, method: .post, headers: headers,
            body: #"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.data(using: .utf8),
            timeout: 10)
        guard let a = http.send(meta) else { return [finish(.failed(.network))] }
        switch a.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let assist = UsageJSON.object(a.body),
              let project = UsageJSON.plainID(assist["cloudaicompanionProject"], max: 200) else {
            return [finish(.unavailable(.schemaChanged))]
        }

        // Step 2: quota buckets — validate the whole collection; malformed buckets must
        // not silently drop a limiting quota.
        struct Body: Encodable { let project: String }
        let quota = UsageHTTPRequest(url: Self.quotaURL, method: .post, headers: headers,
            body: try? JSONEncoder().encode(Body(project: project)), timeout: 10)
        guard let q = http.send(quota) else { return [finish(.failed(.network))] }
        switch q.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        let buckets: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: q.body) as? [[String: Any]] {
            buckets = arr
        } else if let o = UsageJSON.object(q.body), let arr = o["buckets"] as? [[String: Any]] {
            buckets = arr
        } else {
            return [finish(.unavailable(.schemaChanged))]
        }
        var byScope: [String: UsageWindow] = [:]
        var order: [String] = []
        for b in buckets {
            guard let remaining = UsageJSON.double(b["remainingFraction"]),
                  (0...1).contains(remaining),
                  let model = UsageJSON.plainID(b["modelId"], max: 64) else {
                // malformed bucket: fail the collection rather than drop a quota
                return [finish(.unavailable(.schemaChanged))]
            }
            // resetTime is required and must parse — an absent quota reset is not "no window"
            guard let reset = UsageJSON.resetDateISO(b["resetTime"]) else {
                return [finish(.unavailable(.schemaChanged))]
            }
            let tokenType = b["tokenType"].flatMap { UsageJSON.plainID($0, max: 64) }
            if b["tokenType"] != nil && tokenType == nil {
                return [finish(.unavailable(.schemaChanged))]
            }
            // input ids never contain brackets, so "model [type]" can't collide with a bare model
            let scope = tokenType.map { "\(model) [\($0)]" } ?? model
            let candidate = UsageWindow(scope: scope, durationMinutes: nil,
                                        usedPercent: (1 - remaining) * 100,
                                        resetsAt: reset)
            if let existing = byScope[scope] {
                // identical typed duplicate collapses; a different record for the same
                // scope is contradictory input, not a merge
                if existing.usedPercent != candidate.usedPercent || existing.resetsAt != reset {
                    return [finish(.unavailable(.schemaChanged))]
                }
                continue
            }
            byScope[scope] = candidate
            order.append(scope)
        }
        let windows = order.compactMap { byScope[$0] }
        return windows.isEmpty ? [finish(.notReporting)] : [finish(.ok, windows)]
    }
}
