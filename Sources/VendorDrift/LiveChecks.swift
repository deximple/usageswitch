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
        /// The request the app's collector sent, for running the sign-in status the same way.
        let request: UsageProcessRequest?
        let version: String?
    }

    // MARK: - Claude

    /// Runs the app's own `ClaudeUsageCollector` against the installed CLI.
    func claudeUsage(_ cli: URL) -> ClaudeRead {
        let check = "Claude `/usage` (live)"
        let recorder = RecordingRunner(runner)
        let usage = ClaudeUsageCollector(runner: recorder, home: home, managed: claudeManaged,
                                         binaryPaths: [cli], workingDirectory: workDirectory, now: now).collect()
        let run = recorder.runs.last
        let output = run.map { ClaudeUsageOutput.text(in: $0.result.lines) }
        let shape = (try? output?.get()).map(PanelSkeleton.shape)
        let lines = shape?.windowLines.map { "`\($0)`" } ?? []
        func read(_ status: DriftStatus, _ summary: String, details: [String] = []) -> ClaudeRead {
            ClaudeRead(finding: DriftFinding(.live, check, status, summary, details: details),
                       request: run?.request, version: usage.toolVersion)
        }
        switch usage.state {
        case .ok:
            return read(.ok, "The app's parser read \(Self.count(usage.windows.count, "usage window")).", details: lines)
        case .notReporting:
            return shape?.mentionsUsedOutsideWindows == true
                ? read(.drift, "The panel reports usage, but no line starts with `Current `; the app shows nothing.")
                : read(.attention, "The CLI answered without a `Current ` line: signed out, an API-key "
                    + "sign-in, or the panel wording changed (see the CLI text check).")
        case .unavailable(.schemaChanged):
            return read(.drift, "A `Current ` line no longer matches the pattern the app reads.", details: lines)
        case .unavailable(.managed):
            return read(.skipped, "Managed Claude Code settings are present, so the app doesn't run it either.")
        case .unavailable(.cliMissing):
            return read(.attention, "The CLI was found but could not be started.")
        case .unavailable(.refused) where output == .failure(.stopped):
            return read(.drift, "The run did more than answer: a hook event, a model turn, turns or "
                + "cost. The flags that keep it quiet no longer hold.")
        case .unavailable(.refused) where output == .failure(.unreadable):
            return read(.attention, "The stream-json output had no clean result line. Offline, or its shape changed.")
        case .failed(.timeout):
            return read(.attention, "No answer within the app's 60 s limit.")
        default:
            return read(.attention, "The read ended without an answer the app can use.")
        }
    }

    /// Runs `claude auth status --json` with the app's environment and asks the app's parser
    /// whether it still understands the shape. Only key names ever reach the finding.
    func claudeAuthStatus(_ usage: UsageProcessRequest) -> DriftFinding {
        let check = "Claude `auth status --json` (live)"
        let result = runner.run(UsageProcessRequest(executable: usage.executable,
            arguments: ClaudeProfileUsageCollector.authStatusArguments, environment: usage.environment,
            workingDirectory: usage.workingDirectory, timeout: 20))
        switch result.outcome {
        case .stopped, .exited: break
        default: return DriftFinding(.live, check, .attention, "The command did not finish.")
        }
        let output = Data(result.lines.joined(separator: "\n").utf8)
        guard !ClaudeProfileUsageCollector.understandsAuthStatus(output) else {
            return DriftFinding(.live, check, .ok, "The output has the shape the app reads.")
        }
        let keys = (try? JSONSerialization.jsonObject(with: output))
            .map { JSONShape.keys(of: $0, depth: 1, known: ClaudeAuthStatusContract.keys) } ?? []
        return DriftFinding(.live, check, .drift,
            "The output no longer has the shape the app reads, so a saved Claude profile shows "
                + "\"update required\"." + (keys.isEmpty ? " It is not a JSON object." : " Keys seen:"),
            details: keys.map { "`\($0)`" })
    }

    // MARK: - Codex

    /// Runs the app's own `CodexUsageCollector` against the standard Codex home and reads the
    /// answer with the app's parser. The sign-in file is checked for existence only; the CLI
    /// uses it itself. Only `account/rateLimits/read` is sent — nothing that changes state.
    func codexRateLimits(_ cli: CodexCLI) -> DriftFinding {
        let check = "Codex `account/rateLimits/read` (live)"
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        guard FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path) else {
            return DriftFinding(.live, check, .skipped, "`~/.codex` has no sign-in.")
        }
        // The identity is a placeholder: reading the real one would mean opening the sign-in file.
        let account = CodexAccount(id: "standard", kind: .standard, label: "Codex", customName: nil,
                                   defaultName: "Codex", home: codexHome.path, homePath: "~/.codex",
                                   identity: CodexIdentity(mode: .chatgpt), state: .signedIn, pids: [])
        let status = CodexStatus(installed: true, version: cli.version, accounts: [account], hiddenCount: 0)
        let recorder = RecordingRunner(runner)
        _ = CodexUsageCollector(status: { status }, runner: recorder, codexCLI: cli.url,
                                workingDirectory: workDirectory, bundledCLI: bundledCodexCLI,
                                userHome: home, now: now).collect()
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
            return DriftFinding(.live, check, .ok, "The app's parser read \(Self.count(parsed.windows.count, "usage window")).",
                details: ["plan name: \(parsed.plan == nil ? "absent" : "present")",
                          "account attribution: \(parsed.accountId == nil ? "absent" : "present")"])
        case .failure(.schemaChanged):
            return DriftFinding(.live, check, .drift,
                "The answer no longer has the shape the app reads. Keys seen:",
                details: answerKeys(run.result.lines).map { "`\($0)`" })
        case .failure(.notReporting):
            return DriftFinding(.live, check, .skipped, "`~/.codex` is signed in with an API key; there is no window to read.")
        case .failure(.noSignIn):
            return DriftFinding(.live, check, .skipped, "The sign-in in `~/.codex` is signed out or expired.")
        case .failure(.rateLimited):
            return DriftFinding(.live, check, .attention, "The server asked to retry later.")
        case .failure(.refused):
            return DriftFinding(.live, check, .attention, "The server answered with an error the app has no reason for.")
        case .failure(.noAnswer):
            return DriftFinding(.live, check, .attention,
                "The server ended without answering the rate-limits request; the handshake may have changed.")
        }
    }

    /// The key names of the rate-limits answer. Only names the protocol snapshot or the app's
    /// contract knows are shown; limit ids and anything new are folded into `*`.
    func answerKeys(_ lines: [String]) -> [String] {
        let answer = lines.lazy.compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }.first { ($0["id"] as? NSNumber)?.intValue == CodexRateLimitsParser.answerID && $0["result"] != nil }
        let known = Set(CodexAppContract.members.values.joined())
            .union((frozen?.types.values ?? [:].values).flatMap(\.keys))
        return JSONShape.keys(of: answer?["result"] ?? [:], depth: 4, known: known)
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
