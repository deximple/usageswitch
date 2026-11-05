import Foundation

/// Devin CLI usage adapter. Reads a fail-closed TOML scalar file for the API key,
/// probes the installed CLI for `--version` (read-only, bounded), then POSTs the
/// Connect GetUserStatus call to the FIXED server.codeium.com — a configured
/// arbitrary server is never contacted.
public struct DevinUsageCollector: Sendable {
    public static let rowID = "devin:current"
    public static let rowAccountRef = "current"
    private static let endpoint = URL(string:
        "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!
    private static let quotaStrategy = "BILLING_STRATEGY_QUOTA"

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let runner: any UsageProcessRunner
    private let cli: URL?
    private let clientVersion: String
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                runner: any UsageProcessRunner,
                cli: URL?, clientVersion: String,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = [:],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.credentials = credentials
        self.runner = runner; self.cli = cli; self.clientVersion = clientVersion
        self.home = home; self.environment = environment; self.now = now
    }

    private var credentialFiles: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) { if seen.insert(url.standardizedFileURL.path).inserted { urls.append(url) } }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            add(URL(fileURLWithPath: xdg).appendingPathComponent("devin/credentials.toml"))
        }
        add(home.appendingPathComponent(".local/share/devin/credentials.toml"))
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            add(URL(fileURLWithPath: xdg).appendingPathComponent("devin/credentials.toml"))
        }
        add(home.appendingPathComponent(".config/devin/credentials.toml"))
        return urls
    }

    /// Tiny fail-closed TOML root-scalar reader: double-quoted escapes, single-quoted
    /// literals, trailing comments, duplicate keys rejected, tables ignored.
    private static func tomlScalars(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        var inTable = false
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { inTable = true; continue }
            if inTable { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            else { continue }
            line = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let relevant = ["api_server_url", "windsurf_api_key", "devin_api_key", "api_key"]
            guard let value = quotedValue(line) else {
                if relevant.contains(key) { return nil } // malformed relevant scalar fails the file
                continue
            }
            if out[key] != nil { return nil } // duplicate root key — ambiguous input fails
            out[key] = value.0
        }
        return out
    }

    private static func quotedValue(_ line: String) -> (String, Int)? {
        if line.hasPrefix("\"") {
            var result = ""
            var i = line.index(after: line.startIndex)
            while i < line.endIndex {
                let c = line[i]
                if c == "\\", line.index(after: i) < line.endIndex {
                    let n = line[line.index(after: i)]
                    guard let esc = ["n": "\n", "t": "\t", "r": "\r", "\"": "\"", "\\": "\\", "b": "\u{8}", "f": "\u{C}"][n]
                    else { return nil } // unknown escape — fail closed
                    result += esc
                    i = line.index(i, offsetBy: 2); continue
                }
                if c == "\"" {
                    let rest = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                    guard rest.isEmpty || rest.hasPrefix("#") else { return nil } // trailing junk fails
                    return (result, line.distance(from: line.startIndex, to: i))
                }
                result.append(c); i = line.index(after: i)
            }
            return nil
        }
        if line.hasPrefix("'"), let end = line.dropFirst().firstIndex(of: "'") {
            let rest = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
            return (String(line[line.index(after: line.startIndex)..<end]),
                    line.distance(from: line.startIndex, to: end))
        }
        return nil
    }

    /// api key in priority order; an `api_server_url` that isn't the fixed host
    /// makes the file fail closed — the key is never forwarded elsewhere.
    private func token() -> String? {
        for file in credentialFiles {
            guard let data = credentials.read(file) else { continue }
            // a present file that won't parse is authoritative: fail, never fall to a weaker candidate
            // the first PRESENT credential file is authoritative — a malformed or
            // token-less file never falls through to a weaker candidate
            guard let scalars = Self.tomlScalars(data) else { return nil }
            if let server = scalars["api_server_url"],
               server != "https://server.codeium.com" { return nil }
            for name in ["windsurf_api_key", "devin_api_key", "api_key"] {
                if let key = scalars[name], !key.isEmpty {
                    return UsageJSON.token(key)
                }
            }
            return nil
        }
        return nil
    }

    /// `--version` on the discovered CLI only — bounded 3s, no session command.
    private func cliVersion() -> String? {
        guard let cli else { return nil }
        let req = UsageProcessRequest(executable: cli, arguments: ["--version"],
                                      environment: [:], workingDirectory: home, timeout: 3)
        let out = runner.run(req)
        guard case .exited(0) = out.outcome else { return nil }
        let text = out.lines.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // version-shaped token only — banner noise is not a version
        guard let range = text.range(of: #"[0-9]+(\.[0-9]+){1,3}"#, options: .regularExpression)
        else { return nil }
        return UsageJSON.plainID(String(text[range]), max: 64)
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], plan: String? = nil,
                    toolVersion: String? = nil) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .devin, accountRef: Self.rowAccountRef,
                         label: "Devin", plan: plan, windows: windows,
                         state: state, readAt: now(), toolVersion: toolVersion)
        }
        guard enabled else { return [] }
        guard let t = token() else { return [finish(.unavailable(.noSignIn))] }
        // a missing or unparseable CLI version means we cannot honestly say what we
        // are — do not pretend our version is the vendor's
        guard let version = cliVersion() else { return [finish(.unavailable(.cliMissing))] }

        struct Metadata: Encodable { let apiKey, ideName, ideVersion, extensionName, extensionVersion: String }
        struct Body: Encodable { let metadata: Metadata }
        let body = try? JSONEncoder().encode(Body(metadata: Metadata(
            apiKey: t, ideName: "usageswitch", ideVersion: clientVersion,
            extensionName: "devin-cli", extensionVersion: version)))
        let request = UsageHTTPRequest(url: Self.endpoint, method: .post,
            headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1"],
            body: body, timeout: 10)
        guard let r = http.send(request) else { return [finish(.failed(.network))] }
        switch r.status {
        case 200: break
        case 401, 403: return [finish(.unavailable(.noSignIn))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let root = UsageJSON.object(r.body),
              let status = root["userStatus"] as? [String: Any],
              let planStatus = status["planStatus"] as? [String: Any] else {
            return [finish(.unavailable(.schemaChanged))]
        }
        // planInfo is NESTED under planStatus in the real envelope
        let planInfo = planStatus["planInfo"] as? [String: Any]
        let knownPlans: Set<String> = ["Solo", "Pro", "Free", "Team", "Enterprise", "Max"]
        let plan = planInfo?["planName"] as? String
        let planLabel = plan.flatMap { knownPlans.contains($0) ? $0 : nil }
        let isQuota = planInfo?["billingStrategy"] as? String == Self.quotaStrategy

        func hidden(_ key: String) -> Bool {
            (UsageJSON.bool(planStatus[key]) ?? false) || (UsageJSON.bool(planInfo?[key]) ?? false)
        }
        enum WindowError: Error { case schemaChanged }
        func window(remainingKey: String, resetKey: String, hideKey: String,
                    duration: Int) throws -> UsageWindow? {
            guard !hidden(hideKey) else { return nil }
            // a window whose fields are present-but-malformed fails the whole reading
            let hasRemaining = planStatus[remainingKey] != nil
            let hasReset = planStatus[resetKey] != nil
            if hasReset {
                guard let reset = UsageJSON.resetDate(planStatus[resetKey]), reset.timeIntervalSince1970 > 0
                else { throw WindowError.schemaChanged }
            }
            if hasRemaining {
                guard UsageJSON.percent(planStatus[remainingKey]) != nil
                else { throw WindowError.schemaChanged }
            }
            guard let reset = UsageJSON.resetDate(planStatus[resetKey]), reset.timeIntervalSince1970 > 0
            else { return nil } // no valid reset -> not a window
            var remaining = UsageJSON.percent(planStatus[remainingKey])
            if remaining == nil && isQuota && !hasRemaining {
                // proto3 omitted-zero: quota plan + valid reset only, field must be ABSENT
                remaining = 0
            }
            guard let remaining else { return nil }
            return UsageWindow(scope: nil, durationMinutes: duration,
                               usedPercent: 100 - remaining, resetsAt: reset)
        }
        do {
            let windows = [
                try window(remainingKey: "dailyQuotaRemainingPercent",
                           resetKey: "dailyQuotaResetAtUnix",
                           hideKey: "hideDailyQuota", duration: 1440),
                try window(remainingKey: "weeklyQuotaRemainingPercent",
                           resetKey: "weeklyQuotaResetAtUnix",
                           hideKey: "hideWeeklyQuota", duration: 10080),
            ].compactMap { $0 }
            return windows.isEmpty ? [finish(.notReporting)]
                                   : [finish(.ok, windows, plan: planLabel, toolVersion: version)]
        } catch {
            return [finish(.unavailable(.schemaChanged))]
        }
    }
}
