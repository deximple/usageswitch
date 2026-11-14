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
        let installations: [UsageInstallation] = installations(bundled: bundledCodexCLI)
        let claudeCLI: URL? = Self.cli(.claude, in: installations)
        let codex: [CodexCLI] = codexCLIs(appChoice: Self.cli(.codex, in: installations))
        let schemas: [SchemaResult?] = codex.map { (cli: CodexCLI) -> SchemaResult? in schemaResult(of: cli) }
        var claude: ClaudeRead?
        if let claudeCLI { claude = claudeUsage(claudeCLI) }

        var findings: [DriftFinding] = []
        for (index, cli) in codex.enumerated() {
            findings.append(protocolFinding(cli, schemas[index]))
        }
        if let first = schemas.first, case .success(let snapshot)? = first {
            findings.append(unreadFinding(snapshot))
        }
        if let claudeCLI {
            findings.append(stringFinding("Claude CLI text", StringContracts.claude, in: claudeCLI))
        }
        for cli in codex {
            findings.append(stringFinding("Codex CLI text — \(cli.label)", StringContracts.codex, in: cli.url))
        }
        if let antigravity = Self.cli(.antigravity, in: installations) {
            findings.append(stringFinding("Antigravity CLI text", StringContracts.antigravity, in: antigravity))
        }
        if let gemini = Self.cli(.gemini, in: installations) {
            findings.append(geminiClientFinding(gemini))
        }
        if let claude {
            findings.append(claude.finding)
            if let request = claude.request { findings.append(claudeAuthStatus(request)) }
        }
        if let app = codex.first {
            findings.append(codexRateLimits(app))
        }
        if let notChecked = Self.notCheckedFinding(installations) {
            findings.append(notChecked)
        }

        let tools: [DriftReport.Tool] = installations.compactMap { (installation: UsageInstallation) -> DriftReport.Tool? in
            guard let url = installation.cli else { return nil }
            var version: String?
            if installation.provider == .claude { version = claude?.version }
            if installation.provider == .codex { version = codex.first?.version }
            return DriftReport.Tool(name: UsageText.providerName(installation.provider),
                                    path: Redaction.display(url, home: home), version: version)
        }
        return DriftReport(generatedAt: now(), tools: tools, findings: findings)
    }

    /// The snapshot of the Codex CLI at `cli`, or of the one the app runs; nil when there is
    /// none or its schema can't be generated. For refreshing the frozen snapshot.
    public func installedSnapshot(cli: URL? = nil) -> CodexProtocolSnapshot? {
        let appChoice: URL? = Self.cli(.codex, in: installations(bundled: bundledCodexCLI))
        guard let url = cli ?? appChoice else { return nil }
        let chosen = CodexCLI(label: "", url: url, version: version(of: url))
        guard let schema = schemaResult(of: chosen), case .success(let snapshot) = schema else { return nil }
        return snapshot
    }

    private static func cli(_ provider: UsageProvider, in installations: [UsageInstallation]) -> URL? {
        let installation: UsageInstallation? = installations.first { (candidate: UsageInstallation) -> Bool in
            candidate.provider == provider
        }
        return installation?.cli
    }

    private static func notCheckedFinding(_ installations: [UsageInstallation]) -> DriftFinding? {
        let consented: [UsageInstallation] = installations.filter { (installation: UsageInstallation) -> Bool in
            installation.provider.requiresConsent
        }
        guard !consented.isEmpty else { return nil }
        let names: [String] = consented.map { (installation: UsageInstallation) -> String in
            UsageText.providerName(installation.provider)
        }
        let summary = "These read a stored sign-in token and call the vendor's API. "
            + "This tool never opens a credential, so their answers are not checked here."
        return DriftFinding(.notChecked, "Usage reads that need a stored sign-in", .notChecked, summary,
                            details: names)
    }

    // MARK: - Codex protocol

    /// The CLI the app runs first, then the one on PATH when it is a different file.
    func codexCLIs(appChoice: URL?) -> [CodexCLI] {
        var found: [CodexCLI] = []
        if let appChoice {
            found.append(CodexCLI(label: "the CLI the app runs", url: appChoice, version: version(of: appChoice)))
        }
        let onPath: URL? = Self.cli(.codex, in: installations(bundled: nil))
        if let onPath, onPath.resolvingSymlinksInPath() != appChoice?.resolvingSymlinksInPath() {
            found.append(CodexCLI(label: "codex on PATH", url: onPath, version: version(of: onPath)))
        }
        return found
    }

    private func version(of cli: URL) -> String? {
        let request = UsageProcessRequest(executable: cli, arguments: ["--version"],
                                          environment: UsageChildEnvironment.make(for: cli, home: home),
                                          workingDirectory: workDirectory, timeout: 10)
        let result: UsageProcessResult = runner.run(request)
        guard case .exited(0) = result.outcome, let line = result.lines.first else { return nil }
        let pattern = #"[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[range])
    }

    private func schemaDirectory(of cli: CodexCLI) -> URL {
        let version: String = cli.version ?? "unknown"
        return workDirectory.appendingPathComponent("codex-schema-\(version)", isDirectory: true)
    }

    private typealias SchemaResult = Result<CodexProtocolSnapshot, CodexProtocolSnapshot.ReadFailure>

    /// nil when the CLI could not generate its schema.
    private func schemaResult(of cli: CodexCLI) -> SchemaResult? {
        let directory: URL = schemaDirectory(of: cli)
        let request = UsageProcessRequest(executable: cli.url,
                                          arguments: ["app-server", "generate-json-schema", "--out", directory.path],
                                          environment: UsageChildEnvironment.make(for: cli.url, home: home),
                                          workingDirectory: workDirectory, timeout: 60)
        let result: UsageProcessResult = runner.run(request)
        guard case .exited(0) = result.outcome else { return nil }
        return CodexProtocolSnapshot.read(schemaDirectory: directory, cliVersion: cli.version)
    }

    private func unreadFinding(_ snapshot: CodexProtocolSnapshot) -> DriftFinding {
        let unread: [String] = snapshot.unreadByApp
        let summary = "The rate-limits answer has \(Self.count(unread.count, "field")) the app does not read."
        return DriftFinding(.codexProtocol, "Codex answer fields the app does not read", .info, summary,
                            details: unread)
    }

    private func protocolFinding(_ cli: CodexCLI, _ schema: SchemaResult?) -> DriftFinding {
        var check = "Codex protocol — \(cli.label)"
        if let version = cli.version { check += " (\(version))" }
        guard let frozen else {
            return DriftFinding(.codexProtocol, check, .attention,
                                "There is no frozen snapshot to compare with; run with --update-snapshot.")
        }
        guard let schema else {
            return DriftFinding(.codexProtocol, check, .attention,
                "`codex app-server generate-json-schema` did not finish, so the protocol was not compared.")
        }
        let installed: CodexProtocolSnapshot
        switch schema {
        case .failure(.unreadable(let file)):
            return DriftFinding(.codexProtocol, check, .drift,
                                "The schema bundle no longer has a readable `\(file)`; its layout changed.")
        case .success(let snapshot):
            installed = snapshot
        }
        let changes: [ProtocolChange] = frozen.changes(to: installed)
        let frozenVersion: String = frozen.cliVersion ?? "an unknown version"
        let since = "the snapshot frozen from \(frozenVersion)"
        guard !changes.isEmpty else {
            return DriftFinding(.codexProtocol, check, .ok, "Matches \(since).")
        }
        let breaking: [ProtocolChange] = changes.filter { (change: ProtocolChange) -> Bool in change.affectsApp }
        let other: [ProtocolChange] = changes.filter { (change: ProtocolChange) -> Bool in !change.affectsApp }
        let ordered: [[ProtocolChange]] = [breaking, other]
        let details: [String] = ordered.flatMap { $0 }.map(Self.line)
        let total: String = Self.count(changes.count, "change")
        guard !breaking.isEmpty else {
            let summary = "\(total) since \(since); none touches what the app sends or reads."
            return DriftFinding(.codexProtocol, check, .info, summary, details: details)
        }
        let summary = "\(breaking.count) of \(total) since \(since) touch what the app sends or reads."
        return DriftFinding(.codexProtocol, check, .drift, summary, details: details)
    }

    /// "1 change", "3 changes".
    static func count(_ number: Int, _ noun: String) -> String {
        let plural: String = number == 1 ? "" : "s"
        return "\(number) \(noun)\(plural)"
    }

    static func line(_ change: ProtocolChange) -> String {
        let mark: String = change.affectsApp ? "**read by the app** — " : ""
        let before: String = change.before ?? ""
        let after: String = change.after ?? ""
        switch change.kind {
        case .added: return "\(mark)added `\(change.path)`: `\(after)`"
        case .removed: return "\(mark)removed `\(change.path)` (was `\(before)`)"
        case .changed: return "\(mark)changed `\(change.path)`: `\(before)` → `\(after)`"
        }
    }

    // MARK: - Text inside the vendor binaries

    private func stringFinding(_ check: String, _ contracts: [StringContract], in cli: URL) -> DriftFinding {
        let binary: URL = cli.resolvingSymlinksInPath()
        let total: String = Self.count(contracts.count, "piece")
        switch BinaryStrings.scan(contracts, in: binary) {
        case .unreadable:
            return DriftFinding(.strings, check, .attention, "The CLI file could not be read.")
        case .script:
            return DriftFinding(.strings, check, .skipped,
                                "The CLI is a launcher script; the program it starts is not searched.")
        case .scanned(let missing):
            guard !missing.isEmpty else {
                let summary = "All present: \(total) of text the app's parsers depend on."
                return DriftFinding(.strings, check, .ok, summary)
            }
            let summary = "Gone: \(missing.count) of \(total) of text the app's parsers depend on."
            let details: [String] = missing.map { (contract: StringContract) -> String in
                "`\(contract.label)` — \(contract.reason)"
            }
            return DriftFinding(.strings, check, .drift, summary, details: details)
        }
    }

    private func geminiClientFinding(_ cli: URL) -> DriftFinding {
        let check = "Gemini CLI sign-in client"
        guard geminiClient.client(for: cli) == nil else {
            return DriftFinding(.strings, check, .ok,
                                "The CLI package still carries the sign-in client the app looks up.")
        }
        let summary = "The app can no longer find the sign-in client inside the CLI package, "
            + "so a consented Gemini token refresh can't work."
        return DriftFinding(.strings, check, .drift, summary)
    }
}
