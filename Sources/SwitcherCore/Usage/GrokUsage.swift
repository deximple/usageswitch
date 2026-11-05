import Foundation

/// Grok CLI usage adapter. Reads the trusted `auth.x.ai`-keyed entries from
/// `~/.grok/auth.json` (or `GROK_HOME`), then GETs the CLI billing endpoint.
/// Never refreshes tokens, never reads other auth origins, never falls back to
/// monetary fields for quota.
public struct GrokUsageCollector: Sendable {
    public static let rowID = "grok:current"
    public static let rowAccountRef = "current"
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let authPrefix = "https://auth.x.ai"

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = [:],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.credentials = credentials
        self.home = home; self.environment = environment; self.now = now
    }

    private var authFile: URL {
        if let g = environment["GROK_HOME"], g.hasPrefix("/") {
            return URL(fileURLWithPath: g).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".grok/auth.json")
    }

    /// Only `https://auth.x.ai`-origin entries may supply a token; unknown origins
    /// and ambiguous duplicates with no explicit selection fail closed.
    private func token() -> (key: String, userID: String?)? {
        guard let data = credentials.read(authFile),
              let object = UsageJSON.object(data) else { return nil }
        let entries = object.compactMap { (key: String, value: Any) -> (key: String, userID: String?)? in
            // exactly "https://auth.x.ai" or that prefix plus "::" — a lookalike host fails
            guard key == Self.authPrefix || key.hasPrefix(Self.authPrefix + "::"),
                  let e = value as? [String: Any],
                  let tokenKey = UsageJSON.token(e["key"]) else { return nil }
            if let raw = e["expires_at"] {
                // Skip near-expiry tokens rather than refreshing credentials.
                guard let expiry = UsageJSON.expiryDate(raw), expiry > now().addingTimeInterval(300)
                else { return nil }
            }
            return (tokenKey, UsageJSON.plainID(e["user_id"]))
        }
        guard entries.count == 1, let only = entries.first else { return nil }
        return only
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = []) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .grok, accountRef: Self.rowAccountRef,
                         label: "Grok", plan: nil, windows: windows,
                         state: state, readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        guard let t = token() else { return [finish(.unavailable(.noSignIn))] }

        var headers = ["Authorization": "Bearer \(t.key)",
                       "X-XAI-Token-Auth": "xai-grok-cli",
                       "Accept": "application/json"]
        if let u = t.userID { headers["x-userid"] = u }
        let request = UsageHTTPRequest(url: Self.endpoint.appending(queryItems: [
            URLQueryItem(name: "format", value: "credits")]),
            method: .get, headers: headers, timeout: 10)
        guard let r = http.send(request) else { return [finish(.failed(.network))] }
        switch r.status {
        case 200: break
        case 401, 403: return [finish(.unavailable(.noSignIn))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let root = UsageJSON.object(r.body) else {
            return [finish(.unavailable(.schemaChanged))]
        }
        let config = (root["config"] as? [String: Any]) ?? root

        if config["creditUsagePercent"] != nil,
           UsageJSON.percent(config["creditUsagePercent"]) == nil {
            // present but invalid — malformed, not "no data"
            return [finish(.unavailable(.schemaChanged))]
        }
        guard let percent = UsageJSON.percent(config["creditUsagePercent"]) else {
            // money-only or absent percentage is not a healthy zero
            return [finish(.notReporting)]
        }
        guard let period = config["currentPeriod"] as? [String: Any],
              let type = UsageJSON.string(period["type"]),
              ["USAGE_PERIOD_TYPE_WEEKLY", "USAGE_PERIOD_TYPE_MONTHLY"].contains(type)
        else { return [finish(.notReporting)] } // no explicit period: cannot invent a window
        // an explicit period whose fields are present but malformed is a schema break
        let start = period["start"].flatMap { UsageJSON.resetDateISO($0) }
        let end = period["end"].flatMap { UsageJSON.resetDateISO($0) }
        if period["start"] != nil && start == nil { return [finish(.unavailable(.schemaChanged))] }
        if period["end"] != nil && end == nil { return [finish(.unavailable(.schemaChanged))] }
        if let start, let end, end <= start { return [finish(.unavailable(.schemaChanged))] }
        var duration = type == "USAGE_PERIOD_TYPE_WEEKLY" ? 10080 : 43200
        if let start, let end, end > start {
            duration = Int(end.timeIntervalSince(start) / 60)
        }
        let window = UsageWindow(scope: nil, durationMinutes: duration,
                                 usedPercent: percent, resetsAt: end ?? nil)
        return [finish(.ok, [window])]
    }
}
