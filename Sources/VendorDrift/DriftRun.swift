import Foundation
import SwitcherCore

/// One pass over the vendor tools installed on this Mac: the Codex protocol against the frozen
/// snapshot, the text the parsers depend on inside the vendor binaries, and live reads through
/// the app's own collectors. Read-only, and it never opens a credential: the vendor CLIs use
/// their own sign-ins, exactly as they do for the app.
public struct DriftRun: Sendable {
    public var home: URL
    /// The caller's PATH, searched the way the app searches it.
    public var path: String
    public var bundledCodexCLI: URL?
    /// Explicit folders to search instead of the real ones; a seam for tests.
    public var searchRoots: UsageSearchRoots?
    /// The snapshot kept in the repository; nil when it is missing or unreadable.
    public var frozen: CodexProtocolSnapshot?
    /// An existing empty folder. The Codex CLI writes its schema bundles below it and the
    /// vendor CLIs start in it; this tool itself never writes a file.
    public var workDirectory: URL
    public var runner: any UsageProcessRunner
    /// Where managed Claude Code settings would be; the app refuses to run the CLI under them.
    public var claudeManaged: ClaudeManagedSettings = .system
    public var geminiClient: any GeminiOAuthClientFinding
    public var now: @Sendable () -> Date

    public init(home: URL, path: String, bundledCodexCLI: URL?, frozen: CodexProtocolSnapshot?,
                workDirectory: URL, runner: any UsageProcessRunner, searchRoots: UsageSearchRoots? = nil,
                geminiClient: any GeminiOAuthClientFinding = GeminiOAuthClientFinder(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home; self.path = path; self.bundledCodexCLI = bundledCodexCLI
        self.searchRoots = searchRoots
        self.frozen = frozen; self.workDirectory = workDirectory; self.runner = runner
        self.geminiClient = geminiClient; self.now = now
    }

    struct CodexCLI {
        let label: String
        let url: URL
        let version: String?
    }

    private func installations(bundled: URL?) -> [UsageInstallation] {
        UsageInstallations.discover(home: home, path: path, bundledCodexCLI: bundled, searchRoots: searchRoots)
    }

    public func report() -> DriftReport {
        let installations = installations(bundled: bundledCodexCLI)
        func cli(_ provider: UsageProvider) -> URL? { installations.first { $0.provider == provider }?.cli }
        let codex = codexCLIs(appChoice: cli(.codex))
        let claude = cli(.claude).map(claudeUsage)

        let schemas = codex.map(schemaResult)
        var findings = zip(codex, schemas).map(protocolFinding)
        if let snapshot = try? schemas.first??.get() {
            findings.append(DriftFinding(.codexProtocol, "Codex answer fields the app does not read", .info,
                "The rate-limits answer has \(Self.count(snapshot.unreadByApp.count, "field")) the app does not read.",
                details: snapshot.unreadByApp))
        }
        findings += [cli(.claude).map { stringFinding("Claude CLI text", StringContracts.claude, in: $0) }]
            .compactMap { $0 }
        findings += codex.map { stringFinding("Codex CLI text — \($0.label)", StringContracts.codex, in: $0.url) }
        findings += [cli(.antigravity).map { stringFinding("Antigravity CLI text", StringContracts.antigravity, in: $0) },
                     cli(.gemini).map(geminiClientFinding)].compactMap { $0 }
        if let claude {
            findings += [claude.finding, claude.request.map(claudeAuthStatus)].compactMap { $0 }
        }
        if let app = codex.first { findings.append(codexRateLimits(app)) }
        let consented = installations.filter(\.provider.requiresConsent).map { UsageText.providerName($0.provider) }
        if !consented.isEmpty {
            findings.append(DriftFinding(.notChecked, "Usage reads that need a stored sign-in", .notChecked,
                "These read a stored sign-in token and call the vendor's API. This tool never opens "
                    + "a credential, so their answers are not checked here.",
                details: consented))
        }

        let tools = installations.compactMap { installation -> DriftReport.Tool? in
            guard let url = installation.cli else { return nil }
            let version: String? = switch installation.provider {
            case .claude: claude?.version
            case .codex: codex.first?.version
            default: nil
            }
            return DriftReport.Tool(name: UsageText.providerName(installation.provider),
                                    path: Redaction.display(url, home: home), version: version)
        }
        return DriftReport(generatedAt: now(), tools: tools, findings: findings)
    }

    /// The snapshot of the Codex CLI at `cli`, or of the one the app runs; nil when there is
    /// none or its schema can't be generated. For refreshing the frozen snapshot.
    public func installedSnapshot(cli: URL? = nil) -> CodexProtocolSnapshot? {
        guard let url = cli ?? installations(bundled: bundledCodexCLI).first(where: { $0.provider == .codex })?.cli
        else { return nil }
        return try? schemaResult(of: CodexCLI(label: "", url: url, version: version(of: url)))?.get()
    }

    // MARK: - Codex protocol

    /// The CLI the app runs first, then the one on PATH when it is a different file.
    func codexCLIs(appChoice: URL?) -> [CodexCLI] {
        let onPath = installations(bundled: nil).first { $0.provider == .codex }?.cli
        let other = onPath.flatMap { $0.resolvingSymlinksInPath() == appChoice?.resolvingSymlinksInPath() ? nil : $0 }
        return [appChoice.map { CodexCLI(label: "the CLI the app runs", url: $0, version: version(of: $0)) },
                other.map { CodexCLI(label: "codex on PATH", url: $0, version: version(of: $0)) }].compactMap { $0 }
    }

    private func version(of cli: URL) -> String? {
        let result = runner.run(UsageProcessRequest(executable: cli, arguments: ["--version"],
            environment: UsageChildEnvironment.make(for: cli, home: home),
            workingDirectory: workDirectory, timeout: 10))
        guard case .exited(0) = result.outcome, let line = result.lines.first,
              let range = line.range(of: #"[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*"#, options: .regularExpression)
        else { return nil }
        return String(line[range])
    }

    private func schemaDirectory(of cli: CodexCLI) -> URL {
        workDirectory.appendingPathComponent("codex-schema-\(cli.version ?? "unknown")", isDirectory: true)
    }

    /// nil when the CLI could not generate its schema.
    private func schemaResult(of cli: CodexCLI) -> SchemaResult? {
        let directory = schemaDirectory(of: cli)
        let result = runner.run(UsageProcessRequest(executable: cli.url,
            arguments: ["app-server", "generate-json-schema", "--out", directory.path],
            environment: UsageChildEnvironment.make(for: cli.url, home: home),
            workingDirectory: workDirectory, timeout: 60))
        guard case .exited(0) = result.outcome else { return nil }
        return CodexProtocolSnapshot.read(schemaDirectory: directory, cliVersion: cli.version)
    }

    private typealias SchemaResult = Result<CodexProtocolSnapshot, CodexProtocolSnapshot.ReadFailure>

    private func protocolFinding(_ cli: CodexCLI, _ schema: SchemaResult?) -> DriftFinding {
        let check = "Codex protocol — \(cli.label)" + (cli.version.map { " (\($0))" } ?? "")
        guard let frozen else {
            return DriftFinding(.codexProtocol, check, .attention,
                                "There is no frozen snapshot to compare with; run with --update-snapshot.")
        }
        switch schema {
        case nil:
            return DriftFinding(.codexProtocol, check, .attention,
                "`codex app-server generate-json-schema` did not finish, so the protocol was not compared.")
        case .failure(.unreadable(let file)):
            return DriftFinding(.codexProtocol, check, .drift,
                "The schema bundle no longer has a readable `\(file)`; its layout changed.")
        case .success(let installed):
            let changes = frozen.changes(to: installed)
            let since = "the snapshot frozen from \(frozen.cliVersion ?? "an unknown version")"
            guard !changes.isEmpty else {
                return DriftFinding(.codexProtocol, check, .ok, "Matches \(since).")
            }
            let breaking = changes.filter(\.affectsApp)
            let details = (breaking + changes.filter { !$0.affectsApp }).map(Self.line)
            return breaking.isEmpty
                ? DriftFinding(.codexProtocol, check, .info,
                    "\(Self.count(changes.count, "change")) since \(since); none touches what the app sends or reads.",
                    details: details)
                : DriftFinding(.codexProtocol, check, .drift,
                    "\(breaking.count) of \(Self.count(changes.count, "change")) since \(since) "
                        + "touch what the app sends or reads.",
                    details: details)
        }
    }

    /// "1 change", "3 changes".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    static func line(_ change: ProtocolChange) -> String {
        let mark = change.affectsApp ? "**read by the app** — " : ""
        switch change.kind {
        case .added: return "\(mark)added `\(change.path)`: `\(change.after ?? "")`"
        case .removed: return "\(mark)removed `\(change.path)` (was `\(change.before ?? "")`)"
        case .changed:
            return "\(mark)changed `\(change.path)`: `\(change.before ?? "")` → `\(change.after ?? "")`"
        }
    }

    // MARK: - Text inside the vendor binaries

    private func stringFinding(_ check: String, _ contracts: [StringContract], in cli: URL) -> DriftFinding {
        let binary = cli.resolvingSymlinksInPath()
        switch BinaryStrings.scan(contracts, in: binary) {
        case .unreadable:
            return DriftFinding(.strings, check, .attention, "The CLI file could not be read.")
        case .script:
            return DriftFinding(.strings, check, .skipped,
                "The CLI is a launcher script; the program it starts is not searched.")
        case .scanned(let missing) where missing.isEmpty:
            return DriftFinding(.strings, check, .ok,
                                "All present: \(Self.count(contracts.count, "piece")) of text the app's parsers depend on.")
        case .scanned(let missing):
            return DriftFinding(.strings, check, .drift,
                "Gone: \(missing.count) of \(Self.count(contracts.count, "piece")) of text the app's parsers depend on.",
                details: missing.map { "`\($0.label)` — \($0.reason)" })
        }
    }

    private func geminiClientFinding(_ cli: URL) -> DriftFinding {
        let check = "Gemini CLI sign-in client"
        return geminiClient.client(for: cli) != nil
            ? DriftFinding(.strings, check, .ok, "The CLI package still carries the sign-in client the app looks up.")
            : DriftFinding(.strings, check, .drift,
                "The app can no longer find the sign-in client inside the CLI package, so a consented "
                    + "Gemini token refresh can't work.")
    }
}
