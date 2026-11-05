import CryptoKit
import Foundation

/// Reads the `account/rateLimits/read` answer out of `codex app-server` output. Only windows, the plan
/// name and the failure reason are read; `accountId`, credits and upsell are never looked at, and the
/// server's error text is mapped to a reason without being kept (it can carry identity).
public enum CodexRateLimitsParser {
    /// The id of the rate-limits request (the third message written to the server).
    public static let answerID = 2
    /// The longest window accepted (366 days, in minutes); beyond it the answer's shape isn't trusted.
    static let longestWindowMinutes = 366 * 24 * 60
    /// The latest reset accepted (2100-01-01, Unix seconds).
    static let latestReset = 4_102_444_800

    public struct Parsed: Equatable, Sendable {
        public var windows: [UsageWindow]
        public var plan: String?
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Signed in with an API key, so there is no subscription window to report.
        case notReporting
        /// Signed out or expired token.
        case noSignIn
        /// The answer's shape isn't the one this build knows.
        case schemaChanged
        case rateLimited
        /// Any other server error.
        case refused
        /// No answer with the awaited id was seen.
        case noAnswer
    }

    /// Whether a stdout line is the answer being waited for: a JSON object with the request id and a
    /// `result` or `error`. Notifications and the initialize answer are ignored.
    public static func isAnswer(_ line: String) -> Bool {
        object(line).map { isAnswer($0, id: answerID) } ?? false
    }

    static func isAnswer(_ object: [String: Any], id: Int) -> Bool {
        whole(object["id"]) == id && (object["result"] != nil || object["error"] != nil)
    }

    /// Finds the answer among the server's output lines and reads the windows out of it.
    public static func read(_ lines: [String]) -> Result<Parsed, Failure> {
        let objects = lines.compactMap(object)
        guard let answer = objects.first(where: { isAnswer($0, id: answerID) }) else {
            return .failure(.noAnswer)
        }
        if let error = answer["error"] as? [String: Any] {
            return .failure(failure(for: error))
        }
        // Newer servers group limits by id (`rateLimitsByLimitId.codex`); older ones send `rateLimits`.
        guard let result = answer["result"] as? [String: Any],
              let snapshot = ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
                ?? (result["rateLimits"] as? [String: Any])
        else { return .failure(.schemaChanged) }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let raw = snapshot[key], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any], let used = whole(window["usedPercent"]),
                  (0...100).contains(used),
                  let duration = optionalWhole(window["windowDurationMins"]),
                  duration.map({ (1...longestWindowMinutes).contains($0) }) ?? true,
                  let resets = optionalWhole(window["resetsAt"]),
                  resets.map({ (0...latestReset).contains($0) }) ?? true
            else { return .failure(.schemaChanged) }
            windows.append(UsageWindow(durationMinutes: duration, usedPercent: Double(used),
                                       resetsAt: resets.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
        }
        return .success(Parsed(windows: windows, plan: snapshot["planType"] as? String))
    }

    /// Maps the error to a reason without keeping its text. The chatgpt-specific message must be
    /// checked first — it also contains the generic "authentication required".
    static func failure(for error: [String: Any]) -> Failure {
        let code = whole(error["code"])
        let message = (error["message"] as? String ?? "").lowercased()
        if message.contains("chatgpt authentication required") { return .notReporting }
        if message.contains("authentication required") || message.contains("unauthorized")
            || message.range(of: #"\b401\b"#, options: .regularExpression) != nil { return .noSignIn }
        if code == -32601 || message.contains("unknown variant") { return .schemaChanged }
        if code == -32001 || message.contains("retry later") { return .rateLimited }
        return .refused
    }

    static func object(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// A JSON integer (not a boolean, not a fraction).
    static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// `.some(nil)` for absent or null, `.some(value)` for an integer, `nil` for a wrong shape.
    static func optionalWhole(_ value: Any?) -> Int?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        return whole(value).map { .some($0) }
    }
}

/// Reads the usage of every listed ChatGPT-login Codex account by asking `codex app-server`, one fresh
/// server per account, sequentially. The vendor binary uses its own sign-in from its own home;
/// UsageSwitch only sees the answer.
public struct CodexUsageCollector: Sendable {
    private let status: @Sendable () -> CodexStatus
    private let runner: any UsageProcessRunner
    private let codexCLI: URL
    /// The version sent in the initialize `clientInfo` (the app's own version).
    private let clientVersion: String
    private let now: @Sendable () -> Date

    public init(status: @escaping @Sendable () -> CodexStatus, runner: any UsageProcessRunner,
                codexCLI: URL, clientVersion: String = "2.0.0",
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.status = status; self.runner = runner; self.codexCLI = codexCLI
        self.clientVersion = clientVersion; self.now = now
    }

    public func collect() -> [AccountUsage] {
        let status = status()
        return status.accounts.map { read($0, toolVersion: status.version) }
    }

    private func read(_ account: CodexAccount, toolVersion: String?) -> AccountUsage {
        let authentication: UsageAuthentication = switch account.identity?.mode {
        case .chatgpt: .subscription
        case .apiKey: .apiKey
        case .unknown, nil: .unknown
        }
        // An opaque login fingerprint: two accounts may share a display name, and name edits
        // must not break pace history. SHA256 of accountId|email, both required — memory only.
        let identityKey: String? = {
            guard account.identity?.mode == .chatgpt,
                  let accountId = account.identity?.accountId, !accountId.isEmpty,
                  let email = account.identity?.email, !email.isEmpty else { return nil }
            let digest = SHA256.hash(data: Data("\(accountId)|\(email.lowercased())".utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }()
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], plan: String? = nil) -> AccountUsage {
            AccountUsage(id: "codex:\(account.id)", provider: .codex, accountRef: account.id,
                         label: account.label, plan: plan, windows: windows, state: state,
                         readAt: now(), toolVersion: toolVersion,
                         authentication: authentication, identityKey: identityKey)
        }
        // API-key and unknown sign-ins have no subscription window; found homes are never listed here.
        guard account.identity?.mode == .chatgpt else { return finish(.notReporting) }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageswitch-codex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let request = UsageProcessRequest(
            executable: codexCLI,
            arguments: ["--disable", "plugins", "app-server"],
            environment: SystemCodexAppControl.environment(home: URL(fileURLWithPath: account.home)),
            workingDirectory: workDir,
            stdinLines: Self.stdinLines(version: clientVersion),
            stopWhen: { CodexRateLimitsParser.isAnswer($0) },
            timeout: 15)
        let result = runner.run(request)
        switch result.outcome {
        case .timedOut: return finish(.failed(.timeout))
        case .failedToStart: return finish(.unavailable(.cliMissing))
        case .stopped, .exited:
            switch CodexRateLimitsParser.read(result.lines) {
            case .success(let parsed): return finish(.ok, parsed.windows, plan: parsed.plan)
            case .failure(let failure): return finish(Self.state(for: failure))
            }
        }
    }

    static func state(for failure: CodexRateLimitsParser.Failure) -> UsageState {
        switch failure {
        case .notReporting: return .notReporting
        case .noSignIn: return .unavailable(.noSignIn)
        case .schemaChanged: return .unavailable(.schemaChanged)
        case .rateLimited: return .failed(.rateLimited)
        case .refused, .noAnswer: return .failed(.refused)
        }
    }

    /// The three handshake messages, in order. stdin stays open after these or the server exits
    /// without answering.
    static func stdinLines(version: String) -> [String] {
        [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"usageswitch","version":"\#(version)"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#,
        ]
    }
}
