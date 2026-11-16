import Foundation
import SwitcherCore

/// Passes every run through to the real runner and keeps what was asked and answered, so a
/// check can look at the exact request the app's collector built. Memory only.
final class RecordingRunner: UsageProcessRunner, @unchecked Sendable {
    struct Run {
        let request: UsageProcessRequest
        let result: UsageProcessResult
    }

    private let base: any UsageProcessRunner
    private let lock = NSLock()
    private var recorded: [Run] = []

    init(_ base: any UsageProcessRunner) { self.base = base }

    func run(_ request: UsageProcessRequest) -> UsageProcessResult {
        let result = base.run(request)
        lock.lock(); recorded.append(Run(request: request, result: result)); lock.unlock()
        return result
    }

    var runs: [Run] { lock.lock(); defer { lock.unlock() }; return recorded }
}

extension DriftRun {
    struct ClaudeRead {
        let finding: DriftFinding
        /// What the answer's `usage_report` holds beyond the shape this tool knows; nil when nothing.
        let unreadFields: DriftFinding?
        /// The request the app's collector sent, for running the sign-in status the same way.
        let request: UsageProcessRequest?
        let version: String?
    }

    // MARK: - Claude

    /// Runs the app's own `ClaudeUsageCollector` against the installed CLI.
    func claudeUsage(_ cli: URL) -> ClaudeRead {
        let recorder = RecordingRunner(runner)
        let collector = ClaudeUsageCollector(runner: recorder, home: home, managed: claudeManaged,
                                             binaryPaths: [cli], workingDirectory: workDirectory, now: now)
        let usage: AccountUsage = collector.collect()
        let run: RecordingRunner.Run? = recorder.runs.last

        // What the app's output reader made of the stream: the panel text, or why it was discarded.
        var panel: String?
        var discarded: ClaudeUsageOutput.Failure?
        if let run {
            switch ClaudeUsageOutput.text(in: run.result.lines) {
            case .success(let text): panel = text
            case .failure(let failure): discarded = failure
            }
        }
        var shape: PanelSkeleton.Shape?
        if let panel { shape = PanelSkeleton.shape(of: panel) }
        let windowLines: [String] = shape?.windowLines ?? []
        let lines: [String] = windowLines.map { (line: String) -> String in "`\(line)`" }
        let unreadFields: DriftFinding? = run.flatMap { (run: RecordingRunner.Run) -> DriftFinding? in
            Self.unreadClaudeFields(in: run.result.lines, wasRead: usage.state == .ok)
        }

        func read(_ status: DriftStatus, _ summary: String, details: [String] = []) -> ClaudeRead {
            let finding = DriftFinding(.live, "Claude `/usage` (live)", status, summary, details: details)
            return ClaudeRead(finding: finding, unreadFields: unreadFields, request: run?.request,
                              version: usage.toolVersion)
        }
        switch usage.state {
        case .ok:
            let count: String = Self.count(usage.windows.count, "usage window")
            let unmapped: [String] = Self.linesTheGuideCannotPlace(usage, lines: lines)
            guard unmapped.isEmpty else {
                let limits: String = Self.count(unmapped.count, "model limit")
                let summary = "The app's parser read \(count), but the Guide maps \(limits) to no model, "
                    + "so a model whose limit is used up is still suggested. The name is left out here; "
                    + "`/usage` in Claude Code shows it."
                return read(.drift, summary, details: unmapped)
            }
            return read(.ok, "The app's parser read \(count).", details: lines)
        case .notReporting:
            if shape?.mentionsUsedOutsideWindows == true {
                return read(.drift,
                            "The panel reports usage, but no line starts with `Current `; the app shows nothing.")
            }
            let summary = "The CLI answered without a `Current ` line: signed out, an API-key sign-in, "
                + "or the panel wording changed (see the CLI text check)."
            return read(.attention, summary)
        case .unavailable(.schemaChanged):
            return read(.drift, "A `Current ` line no longer matches the pattern the app reads.", details: lines)
        case .unavailable(.managed):
            return read(.skipped, "Managed Claude Code settings are present, so the app doesn't run it either.")
        case .unavailable(.cliMissing):
            return read(.attention, "The CLI was found but could not be started.")
        case .unavailable(.refused):
            if discarded == .stopped {
                let summary = "The run did more than answer: a hook event, a model turn, turns or cost. "
                    + "The flags that keep it quiet no longer hold."
                return read(.drift, summary)
            }
            if discarded == .unreadable {
                return read(.attention,
                            "The stream-json output had no clean result line. Offline, or its shape changed.")
            }
            return read(.attention, "The read ended without an answer the app can use.")
        case .failed(.timeout):
            return read(.attention, "No answer within the app's 60 s limit.")
        default:
            return read(.attention, "The read ended without an answer the app can use.")
        }
    }

    /// The lines of the model limits no Guide candidate claims. The app's own map and bundled
    /// catalog are asked the way `SuggestionEngine` asks them, so no list of names lives here.
    /// `lines` are the panel's `Current …` lines, one per window and in the parser's order.
    static func linesTheGuideCannotPlace(_ usage: AccountUsage, lines: [String]) -> [String] {
        // Without a catalog the app's Guide is off, and there is no mapping to check.
        guard let catalog = try? SuggestionCatalog.bundled() else { return [] }
        let map = SuggestionHarnessMap.standard
        typealias Candidate = SuggestionHarnessMap.CandidateModel
        let candidates: [Candidate] = map.candidateModels(for: usage.provider, catalog: catalog)
        let claimed: [UsageWindow] = candidates.flatMap { (candidate: Candidate) -> [UsageWindow] in
            map.spentWindows(in: usage, for: candidate)
        }
        let pairs: [(window: UsageWindow, line: String)] = Array(zip(usage.windows, lines))
        let unplaced = pairs.filter { (pair: (window: UsageWindow, line: String)) -> Bool in
            pair.window.scope != nil && !claimed.contains(pair.window)
        }
        return unplaced.map { (pair: (window: UsageWindow, line: String)) -> String in pair.line }
    }

    /// What the answer's `usage_report` holds beyond the shape in `ClaudeUsageReport`; nil when
    /// nothing. The app reads none of it, so this is never drift: a new key is worth a look,
    /// since it may be what the app needs to show Claude's limit resets. Only its name is shown.
    /// `wasRead` is whether the app's parser read the panel, which is when the report is expected.
    static func unreadClaudeFields(in lines: [String], wasRead: Bool) -> DriftFinding? {
        let check = "Claude `/usage` fields the app does not read (live)"
        let difference: ClaudeUsageReport.Difference? = ClaudeUsageReport.difference(in: lines)
        let added: [ClaudeUsageReport.Added] = difference?.added ?? []
        guard added.isEmpty else {
            let fields: String = Self.count(added.count, "field")
            let resets: Int = added.filter { (key: ClaudeUsageReport.Added) -> Bool in key.namesAReset }.count
            var summary = "The answer's `usage_report` has \(fields) this tool has not seen before; the app "
                + "reads none of it. It may be the limit resets an account holds, which the app can't show "
                + "for Claude yet."
            if resets > 0 { summary += " Named like a limit reset: \(resets)." }
            let details: [String] = added.map { (key: ClaudeUsageReport.Added) -> String in
                let mark: String = key.namesAReset ? "**named like a limit reset** — " : ""
                return "\(mark)added `\(key.path)`"
            }
            return DriftFinding(.live, check, .attention, summary, details: details)
        }
        // A read that settled nothing says so in its own finding.
        guard wasRead, difference?.sawRateLimits != true else { return nil }
        let summary = "The answer carries no `usage_report.rate_limits` to compare, so a new field there "
            + "(the limit resets an account holds, say) would go unnoticed. The app reads the panel text "
            + "and is not affected."
        return DriftFinding(.live, check, .attention, summary)
    }

    /// Runs `claude auth status --json` with the app's environment and asks the app's parser
    /// whether it still understands the shape. Only key names ever reach the finding.
    func claudeAuthStatus(_ usage: UsageProcessRequest) -> DriftFinding {
        let check = "Claude `auth status --json` (live)"
        let request = UsageProcessRequest(executable: usage.executable,
                                          arguments: ClaudeProfileUsageCollector.authStatusArguments,
                                          environment: usage.environment,
                                          workingDirectory: usage.workingDirectory, timeout: 20)
        let result: UsageProcessResult = runner.run(request)
        switch result.outcome {
        case .stopped, .exited: break
        default: return DriftFinding(.live, check, .attention, "The command did not finish.")
        }
        let text: String = result.lines.joined(separator: "\n")
        let output = Data(text.utf8)
        guard !ClaudeProfileUsageCollector.understandsAuthStatus(output) else {
            return DriftFinding(.live, check, .ok, "The output has the shape the app reads.")
        }
        var keys: [String] = []
        if let object = try? JSONSerialization.jsonObject(with: output) {
            keys = JSONShape.keys(of: object, depth: 1, known: ClaudeAuthStatusContract.keys)
        }
        let seen: String = keys.isEmpty ? " It is not a JSON object." : " Keys seen:"
        let summary = "The output no longer has the shape the app reads, so a saved Claude profile shows "
            + "\"update required\".\(seen)"
        let details: [String] = keys.map { (key: String) -> String in "`\(key)`" }
        return DriftFinding(.live, check, .drift, summary, details: details)
    }

    // MARK: - Codex

    /// Runs the app's own `CodexUsageCollector` against the standard Codex home and reads the
    /// answer with the app's parser. The sign-in file is checked for existence only; the CLI
    /// uses it itself. Only `account/rateLimits/read` is sent — nothing that changes state.
    func codexRateLimits(_ cli: CodexCLI) -> DriftFinding {
        let check = "Codex `account/rateLimits/read` (live)"
        let codexHome: URL = home.appendingPathComponent(".codex", isDirectory: true)
        let signIn: URL = codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: signIn.path) else {
            return DriftFinding(.live, check, .skipped, "`~/.codex` has no sign-in.")
        }
        // The identity is a placeholder: reading the real one would mean opening the sign-in file.
        let account = CodexAccount(id: "standard", kind: .standard, label: "Codex", customName: nil,
                                   defaultName: "Codex", home: codexHome.path, homePath: "~/.codex",
                                   identity: CodexIdentity(mode: .chatgpt), state: .signedIn, pids: [])
        let status = CodexStatus(installed: true, version: cli.version, accounts: [account], hiddenCount: 0)
        let recorder = RecordingRunner(runner)
        // A cache of its own: every run is an account's first read, which is the one that also
        // asks for the reset-credit details. Both forms of the request only read.
        let collector = CodexUsageCollector(status: { status }, runner: recorder, codexCLI: cli.url,
                                            workingDirectory: workDirectory, bundledCLI: bundledCodexCLI,
                                            userHome: home, resetCredits: CodexResetCreditCache(), now: now)
        _ = collector.collect()
        guard let run = recorder.runs.last else {
            return DriftFinding(.live, check, .attention, "The app's collector did not start the server.")
        }
        switch run.result.outcome {
        case .stopped, .exited: break
        case .timedOut: return DriftFinding(.live, check, .attention, "No answer within the app's 15 s limit.")
        default: return DriftFinding(.live, check, .attention, "The server did not run to an answer.")
        }
        switch CodexRateLimitsParser.read(run.result.lines) {
        case .success(let parsed):
            // The parser drops reset credits it can't read instead of failing the windows, so a
            // changed shape would otherwise pass unnoticed.
            let sentCredits: Bool = Self.answerResult(run.result.lines)?["rateLimitResetCredits"] is [String: Any]
            if sentCredits, parsed.resetCredits == nil {
                let keys: [String] = answerKeys(run.result.lines)
                let details: [String] = keys.map { (key: String) -> String in "`\(key)`" }
                return DriftFinding(.live, check, .drift,
                    "The answer carries reset credits the app's parser no longer reads. Keys seen:",
                    details: details)
            }
            let count: String = Self.count(parsed.windows.count, "usage window")
            let plan: String = parsed.plan == nil ? "absent" : "present"
            let attribution: String = parsed.accountId == nil ? "absent" : "present"
            var credits = "absent"
            if parsed.resetCredits != nil { credits = parsed.resetCreditDetails ? "present, with details" : "count only" }
            let details: [String] = ["plan name: \(plan)", "account attribution: \(attribution)",
                                     "reset credits: \(credits)"]
            return DriftFinding(.live, check, .ok, "The app's parser read \(count).", details: details)
        case .failure(.schemaChanged):
            let keys: [String] = answerKeys(run.result.lines)
            let details: [String] = keys.map { (key: String) -> String in "`\(key)`" }
            return DriftFinding(.live, check, .drift,
                                "The answer no longer has the shape the app reads. Keys seen:", details: details)
        case .failure(.notReporting):
            return DriftFinding(.live, check, .skipped,
                                "`~/.codex` is signed in with an API key; there is no window to read.")
        case .failure(.noSignIn):
            return DriftFinding(.live, check, .skipped, "The sign-in in `~/.codex` is signed out or expired.")
        case .failure(.rateLimited):
            return DriftFinding(.live, check, .attention, "The server asked to retry later.")
        case .failure(.refused):
            return DriftFinding(.live, check, .attention,
                                "The server answered with an error the app has no reason for.")
        case .failure(.noAnswer):
            return DriftFinding(.live, check, .attention,
                "The server ended without answering the rate-limits request; the handshake may have changed.")
        }
    }

    /// The `result` of the rate-limits answer among the server's output lines.
    static func answerResult(_ lines: [String]) -> [String: Any]? {
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? NSNumber, id.intValue == CodexRateLimitsParser.answerID,
                  let result = object["result"] as? [String: Any]
            else { continue }
            return result
        }
        return nil
    }

    /// The key names of the rate-limits answer. Only names the protocol snapshot or the app's
    /// contract knows are shown; limit ids and anything new are folded into `*`.
    func answerKeys(_ lines: [String]) -> [String] {
        guard let result = Self.answerResult(lines) else { return [] }
        var known = Set<String>()
        for members in CodexAppContract.members.values { known.formUnion(members) }
        let frozenTypes: [String: [String: String]] = frozen?.types ?? [:]
        for members in frozenTypes.values { known.formUnion(members.keys) }
        return JSONShape.keys(of: result, depth: 4, known: known)
    }
}

/// The top-level keys of `claude auth status --json` the app's parser requires. A unit test
/// drops each one from a signed-in status and checks the app's parser then rejects it.
enum ClaudeAuthStatusContract {
    static let keys: Set<String> = [
        "loggedIn", "analyticsDisabled", "authMethod", "apiProvider", "projectsDirectory",
        "configDirectory", "email", "orgId", "orgName", "subscriptionType",
    ]
}
