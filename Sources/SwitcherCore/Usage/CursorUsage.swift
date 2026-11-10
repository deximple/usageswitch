import Foundation

/// One HTTPS POST of an empty JSON object, injected so tests never reach the network or see a token.
/// The token only crosses this boundary as the bearer header — it is never stored or logged.
public protocol UsageHTTP: Sendable {
    /// nil when no response arrived (DNS, TLS, timeout).
    func post(url: URL, bearer: String, timeout: TimeInterval) -> (status: Int, body: Data)?
}

public struct SystemUsageHTTP: UsageHTTP {
    private let transport: any UsageHTTPTransport
    public init(transport: any UsageHTTPTransport = SystemUsageHTTPTransport()) {
        self.transport = transport
    }

    public func post(url: URL, bearer: String, timeout: TimeInterval) -> (status: Int, body: Data)? {
        let request = UsageHTTPRequest(
            url: url, method: .post,
            headers: ["Authorization": "Bearer \(bearer)", "Content-Type": "application/json"],
            body: Data("{}".utf8), timeout: timeout)
        guard let response = transport.send(request) else { return nil }
        return (status: response.status, body: response.body)
    }
}

/// Reads windows out of the DashboardService answers. Connect JSON sends int64 fields as strings, so
/// numbers are accepted either way. Only percentages and the billing cycle are read.
public enum CursorUsageParser {
    /// Dashboard pool names mapped from `planUsage.autoPercentUsed`/`apiPercentUsed`.
    public static let cursorModelsScope = "Cursor Models"
    public static let otherModelsScope = "Other Models"

    /// The windows in `usage` (a GetCurrentPeriodUsage body). `merged` is GetPlanInfo's `isMerged`,
    /// nil when that call didn't happen or didn't answer. Returns nil when no percentage is reported.
    /// The result includes the reported total and any valid Cursor Models/Other Models pool
    /// pool percentages. A missing or invalid split does not hide the total; a missing or
    /// invalid total reports no usage.
    /// `merged` is kept for source compatibility only; no pools are inferred.
    public static func windows(usage: Data, merged _: Bool? = nil) -> [UsageWindow]? {
        guard let object = try? JSONSerialization.jsonObject(with: usage) as? [String: Any] else { return nil }
        let start = int64(object["billingCycleStart"])
        let end = int64(object["billingCycleEnd"])
        let delta = start.flatMap { first in end.map { $0.subtractingReportingOverflow(first) } }
        guard delta?.overflow != true else { return nil }
        let duration = delta.flatMap { $0.partialValue > 0 ? Int(exactly: $0.partialValue / 60_000) : nil }
        let resets = end.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let plan = object["planUsage"] as? [String: Any] ?? [:]
        let fields = [percent(plan["autoPercentUsed"]), percent(plan["apiPercentUsed"]),
                      percent(plan["totalPercentUsed"])]
        guard let total = fields[2].value else { return nil }
        // A reported percentage outside 0...100 is a schema change, not something to clamp
        // into range and present as real data (audit B-11).
        guard fields.allSatisfy({ field in
            guard case .value(let v) = field else { return true }
            return (0...100).contains(v)
        }) else { return nil }
        var windows = [UsageWindow(scope: nil, durationMinutes: duration,
                                   usedPercent: total, resetsAt: resets)]
        // autoPercentUsed/apiPercentUsed are the dashboard's Cursor Models/Other Models pools;
        // a bad or absent split only omits that window.
        if let auto = fields[0].value {
            windows.append(UsageWindow(scope: Self.cursorModelsScope, durationMinutes: duration,
                                       usedPercent: auto, resetsAt: resets))
        }
        if let api = fields[1].value {
            windows.append(UsageWindow(scope: Self.otherModelsScope, durationMinutes: duration,
                                       usedPercent: api, resetsAt: resets))
        }
        return windows
    }

    /// An int64 field, sent as a number or a string.
    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Int64(exactly: number.doubleValue)
        }
        return (value as? String).flatMap(Int64.init)
    }

    /// A percentage field: absent/null means not reported; a provided value must be a
    /// finite JSON number (bool excluded) or a finite Double-parsable numeric string.
    /// Anything else — bool, object, array, or a nonfinite value — is `.invalid`.
    enum PercentField: Equatable { case absent, value(Double), invalid

        var value: Double? {
            if case .value(let number) = self { return number }
            return nil
        }
    }

    static func percent(_ value: Any?) -> PercentField {
        guard let value, !(value is NSNull) else { return .absent }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? .value(double) : .invalid
        }
        if let string = value as? String, let double = Double(string), double.isFinite {
            return .value(double)
        }
        return .invalid
    }

    static func clamped(_ value: Double) -> Double { min(100, max(0, value)) }
}

/// Reads Cursor usage through Cursor's dashboard API.
/// Off by default (`cursorUsageEnabled`): disabled means no Keychain read and no request at all.
/// The token is read per refresh, kept in memory for the request, and never stored or logged.
public struct CursorUsageCollector: Sendable {
    private let enabled: Bool
    private let runner: any UsageProcessRunner
    private let http: any UsageHTTP
    private let home: URL
    private let endpoint: URL
    private let now: @Sendable () -> Date
    /// Bounded read of `.cursor/auth.json` — the Keychain probe stays a bounded
    /// process call; this reader only bounds the file fallback.
    private let credentials: any UsageCredentialReading

    /// `endpoint` defaults to the `CURSOR_API_ENDPOINT` environment variable or Cursor's API host.
    public init(enabled: Bool, runner: any UsageProcessRunner, http: any UsageHTTP,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                endpoint: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                credentials: any UsageCredentialReading = UsageFileCredentialReader()) {
        self.enabled = enabled; self.runner = runner; self.http = http; self.home = home
        self.credentials = credentials
        self.endpoint = endpoint ?? ProcessInfo.processInfo.environment["CURSOR_API_ENDPOINT"]
            .flatMap(URL.init(string:)) ?? URL(string: "https://api2.cursor.sh")!
        self.now = now
    }

    /// Row identifiers shared with the installed-but-disabled placeholder so a consent change
    /// keeps the same row identity.
    public static let rowID = "cursor:cursor"
    public static let rowAccountRef = "cursor"

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = []) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .cursor, accountRef: Self.rowAccountRef, label: "Cursor",
                         plan: nil, windows: windows, state: state, readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        guard let token = token() else { return [finish(.unavailable(.noSignIn))] }
        // cursor-agent does not refresh its stored token on its own; an expired
        // one is reported as an expired sign-in without a request. A browser
        // `cursor-agent login` session lasts about 60 days; API-key sign-ins
        // about an hour.
        if let expiry = UsageJSON.jwtExpiry(token), expiry <= now().addingTimeInterval(60) {
            return [finish(.unavailable(.signInExpired))]
        }
        let usageURL = endpoint.appendingPathComponent("aiserver.v1.DashboardService/GetCurrentPeriodUsage")
        guard let response = http.post(url: usageURL, bearer: token, timeout: 10) else {
            return [finish(.failed(.network))]
        }
        if response.status == 401 || response.status == 403 { return [finish(.failed(.signInRejected))] }
        guard response.status == 200 else { return [finish(.failed(.network))] }
        guard let windows = CursorUsageParser.windows(usage: response.body) else {
            return [finish(.notReporting)]
        }
        return [finish(.ok, windows)]
    }

    /// The Cursor sign-in token: a bounded Keychain probe first, then the bounded
    /// auth-file read. A present-but-invalid or overflowing Keychain answer is
    /// authoritative — it never falls through to a different file's account.
    private func token() -> String? {
        let request = UsageProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", "cursor-user", "-s", "cursor-access-token", "-w"],
            environment: SystemClaudeAppControl.cleanEnvironment(from: ProcessInfo.processInfo.environment),
            workingDirectory: FileManager.default.temporaryDirectory,
            maxOutputBytes: 4098,
            timeout: 3)
        let result = runner.run(request)
        switch result.outcome {
        case .exited(0):
            let raw = result.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                // a nonempty answer that fails token validation is malformed — no fallback
                return UsageJSON.token(raw)
            }
        case .outputLimit:
            return nil // overflowed keychain value is authoritative-bad, not a file's account
        default:
            break // ordinary failure/empty -> file fallback below
        }
        guard !Task.isCancelled else { return nil } // cancelled: no file fallback (audit B-11)
        let auth = home.appendingPathComponent(".cursor/auth.json")
        guard let data = credentials.read(auth),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = UsageJSON.token(object["accessToken"])
        else { return nil }
        return token
    }
}
