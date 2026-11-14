import CryptoKit
import Foundation

/// Reads the `account/rateLimits/read` answer out of `codex app-server` output. Only windows, the plan
/// name, the attributed `accountId`, the reset-credit count and expiries, and the failure reason are
/// read; the credit balance, credit ids/titles and upsell are never looked at, and the server's error
/// text is mapped to a reason without being kept (it can carry identity).
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
        /// The account the server attributes this read to; nil when an older server omits it.
        public var accountId: String? = nil
        /// Limit resets the account holds; nil when the server sent none or an unknown shape.
        public var resetCredits: UsageResetCredits? = nil
        /// Whether `resetCredits` came with per-credit details (expiries), not the count alone.
        public var resetCreditDetails = false
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
        let accountId = result["accountId"]
        guard accountId == nil || accountId is NSNull || accountId is String else { return .failure(.schemaChanged) }
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
        let credits = resetCredits(result["rateLimitResetCredits"])
        return .success(Parsed(windows: windows, plan: snapshot["planType"] as? String,
                               accountId: accountId as? String,
                               resetCredits: credits?.credits, resetCreditDetails: credits?.detailed ?? false))
    }

    /// `rateLimitResetCredits`: `availableCount` and, when details were asked for, `credits` (null
    /// means count only). Optional and additive, so an unknown shape drops the credits rather than
    /// failing the windows. Only the expiry of each `available` credit is read.
    static func resetCredits(_ value: Any?) -> (credits: UsageResetCredits, detailed: Bool)? {
        guard let summary = value as? [String: Any], let count = whole(summary["availableCount"]), count >= 0
        else { return nil }
        guard let list = summary["credits"] as? [Any] else {
            return (UsageResetCredits(available: count), false)
        }
        let expiries = list.compactMap { item -> Date? in
            guard let credit = item as? [String: Any], credit["status"] as? String == "available",
                  let expires = whole(credit["expiresAt"]), (0...latestReset).contains(expires)
            else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(expires))
        }
        return (UsageResetCredits(available: count, expiries: expiries), true)
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
    /// The app's embedded CLI: it is a real binary, not a script launcher (audit B-05).
    private let bundledCLI: URL?
    /// The version sent in the initialize `clientInfo` (the app's own version).
    private let clientVersion: String
    /// Must already exist; never created or removed here.
    private let workingDirectory: URL
    /// The user's home, for the interpreter PATH. An account's `home` is its Codex folder
    /// (`~/.codex`, or one in the store), not a home with `.local/bin` and the like.
    private let userHome: URL
    /// Decides when a read asks for reset-credit details and keeps their expiries between polls.
    private let resetCredits: CodexResetCreditCache
    private let now: @Sendable () -> Date

    public init(status: @escaping @Sendable () -> CodexStatus, runner: any UsageProcessRunner,
                codexCLI: URL, clientVersion: String = ProductInfo.fallbackVersion, workingDirectory: URL,
                bundledCLI: URL? = nil, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                resetCredits: CodexResetCreditCache = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.status = status; self.runner = runner; self.codexCLI = codexCLI; self.bundledCLI = bundledCLI
        self.clientVersion = clientVersion; self.workingDirectory = workingDirectory
        self.userHome = userHome; self.resetCredits = resetCredits; self.now = now
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
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], plan: String? = nil,
                    credits: UsageResetCredits? = nil, attributed: Bool = true) -> AccountUsage {
            AccountUsage(id: "codex:\(account.id)", provider: .codex, accountRef: account.id,
                         label: account.label, plan: plan, windows: windows, state: state,
                         readAt: now(), toolVersion: toolVersion,
                         authentication: authentication, identityKey: attributed ? identityKey : nil,
                         resetCredits: credits)
        }
        // API-key and unknown sign-ins have no subscription window; found homes are never listed here.
        guard account.identity?.mode == .chatgpt else { return finish(.notReporting) }
        guard ClaudeUsageCollector.isDirectory(workingDirectory) else { return finish(.failed(.refused)) }
        var env = codexCLI.standardizedFileURL != bundledCLI?.standardizedFileURL
            ? UsageChildEnvironment.make(for: codexCLI, home: userHome)
            : SystemCodexAppControl.environment(home: URL(fileURLWithPath: account.home))
        env["CODEX_HOME"] = account.home
        let details = resetCredits.wantsDetails(account: account.id, login: identityKey, now: now())
        let request = UsageProcessRequest(
            executable: codexCLI,
            arguments: ["--disable", "plugins", "app-server"],
            environment: env,
            workingDirectory: workingDirectory,
            stdinLines: Self.stdinLines(version: clientVersion, resetCreditDetails: details),
            stopWhen: { CodexRateLimitsParser.isAnswer($0) },
            timeout: 15)
        let result = runner.run(request)
        switch result.outcome {
        case .timedOut: return finish(.failed(.timeout))
        case .failedToStart: return finish(.unavailable(.cliMissing))
        case .outputLimit: return finish(.unavailable(.refused))
        case .cancelled: return finish(.unavailable(.refused))
        case .stopped, .exited:
            switch CodexRateLimitsParser.read(result.lines) {
            case .success(let parsed):
                // A read attributed to another account (a login changed mid-read) is never this home's
                // quota, and drops the login fingerprint so no earlier windows are kept for it either.
                if let reported = parsed.accountId, account.identity?.owns(accountId: reported) != true {
                    resetCredits.forget(account: account.id)
                    return finish(.failed(.accountMismatch), attributed: false)
                }
                // A read that asked for details counts as detailed even when the server sent the count
                // alone — otherwise every 5-minute poll would keep asking for them.
                let credits = resetCredits.merge(account: account.id, login: identityKey, read: parsed.resetCredits,
                                                 detailed: details || parsed.resetCreditDetails, now: now())
                return finish(.ok, parsed.windows, plan: parsed.plan, credits: credits)
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
    /// without answering. A background poll skips the reset-credit detail lookup, as Codex asks;
    /// the count still comes back either way.
    static func stdinLines(version: String, resetCreditDetails: Bool = false) -> [String] {
        [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"usageswitch","version":"\#(version)"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":\#(!resetCreditDetails)}}"#,
        ]
    }
}
