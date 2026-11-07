import Foundation

/// OpenCode Go usage adapter: explicit `opencode-go` api key only, then
/// GET /zen/go/v1/usage. Never mixes linked third-party accounts or cost totals.
public struct OpenCodeUsageCollector: Sendable {
    public static let rowID = "opencode:current"
    public static let rowAccountRef = "current"
    private static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

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
        // OPENCODE_DATA_DIR IS the data dir; XDG_DATA_HOME gets /opencode appended.
        if let o = environment["OPENCODE_DATA_DIR"], o.hasPrefix("/") {
            return URL(fileURLWithPath: o).appendingPathComponent("auth.json")
        }
        let root = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? home.appendingPathComponent(".local/share").path
        return URL(fileURLWithPath: root).appendingPathComponent("opencode/auth.json")
    }

    /// Only object["opencode-go"] with type:"api" supplies a key.
    private func token() -> String? {
        guard let data = credentials.read(authFile),
              let object = UsageJSON.object(data),
              let go = object["opencode-go"] as? [String: Any],
              go["type"] as? String == "api",
              let key = UsageJSON.token(go["key"]) else { return nil }
        return key
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = []) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .opencode, accountRef: Self.rowAccountRef,
                         label: "OpenCode", plan: nil, windows: windows,
                         state: state, readAt: now(), toolVersion: nil)
        }
        func success(_ windows: [UsageWindow]) -> AccountUsage {
            // a successful Go quota read is subscription billing, not API-key metering
            AccountUsage(id: Self.rowID, provider: .opencode, accountRef: Self.rowAccountRef,
                         label: "OpenCode", plan: "Go", windows: windows,
                         state: .ok, readAt: now(), toolVersion: nil,
                         authentication: .subscription)
        }
        guard enabled else { return [] }
        guard let key = token() else { return [finish(.unavailable(.noSignIn))] }
        let request = UsageHTTPRequest(url: Self.endpoint, method: .get,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
            timeout: 10)
        guard let r = http.send(request) else { return [finish(.failed(.network))] }
        switch r.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let root = UsageJSON.object(r.body),
              let usage = root["usage"] as? [String: Any] else {
            return [finish(.unavailable(.schemaChanged))]
        }
        var windows: [UsageWindow] = []
        for (scope, minutes) in [("rolling", 300), ("weekly", 10080), ("monthly", 43200)] {
            guard let raw = usage[scope] else { continue } // absent windows are fine
            guard let w = raw as? [String: Any],
                  let percent = UsageJSON.percent(w["percent"]) else {
                // a present window that won't parse is a schema break, not a drop
                return [finish(.unavailable(.schemaChanged))]
            }
            var reset: Date?
            if let rawReset = w["resetsAt"], !(rawReset is NSNull) {
                guard let parsed = UsageJSON.resetDateISO(rawReset) else {
                    return [finish(.unavailable(.schemaChanged))]
                }
                reset = parsed
            }
            windows.append(UsageWindow(scope: nil, durationMinutes: minutes,
                                       usedPercent: percent, resetsAt: reset))
        }
        return windows.isEmpty ? [finish(.notReporting)]
                               : [success(windows)]
    }
}
