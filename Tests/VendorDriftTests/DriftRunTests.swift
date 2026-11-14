import Foundation
import Testing
@testable import SwitcherCore
@testable import VendorDrift

private struct StubGeminiClient: GeminiOAuthClientFinding {
    let found: Bool
    func client(for cli: URL?) -> (id: String, secret: String)? { found ? ("id", "secret") : nil }
}

@Suite("Drift run")
struct DriftRunTests {
    let rig = DriftRig()

    /// A runner standing in for healthy installed CLIs. `schema` edits the bundle the fake
    /// Codex CLI writes; `generates` false makes that command fail.
    private func runner(version: String = "codex-cli 1.2.3", generates: Bool = true, writesSchema: Bool = true,
                        schema: @escaping @Sendable (inout [String: [String: Any]]) -> Void = { _ in }) -> FakeRunner {
        FakeRunner { request in
            switch request.arguments {
            case ["--version"]:
                return UsageProcessResult(lines: [version], outcome: .exited(0))
            case ClaudeUsageCollector.arguments:
                return UsageProcessResult(lines: Sample.claudeStream(Sample.claudePanel), outcome: .stopped)
            case ClaudeProfileUsageCollector.authStatusArguments:
                return UsageProcessResult(lines: [Sample.authStatus()], outcome: .exited(0))
            case ["--disable", "plugins", "app-server"]:
                return UsageProcessResult(lines: Sample.codexAnswer(), outcome: .stopped)
            case let arguments where arguments.prefix(3) == ["app-server", "generate-json-schema", "--out"]:
                guard generates else { return UsageProcessResult(lines: [], outcome: .exited(2)) }
                if writesSchema { Sample.writeSchema(to: URL(fileURLWithPath: arguments[3]), edit: schema) }
                return UsageProcessResult(lines: [], outcome: .exited(0))
            default:
                return UsageProcessResult(lines: [], outcome: .failedToStart)
            }
        }
    }

    private func frozen() -> CodexProtocolSnapshot {
        let folder = TempFolder()
        Sample.writeSchema(to: folder.url)
        return try! CodexProtocolSnapshot.read(schemaDirectory: folder.url, cliVersion: "1.0.0").get()
    }

    private func installClaudeAndCodex() {
        _ = rig.cli("claude", containing: StringContracts.claude)
        _ = rig.cli("codex", containing: StringContracts.codex)
        rig.signIntoCodex()
    }

    private func status(_ report: DriftReport, _ check: String) -> DriftStatus? {
        report.findings.first { $0.check.hasPrefix(check) }?.status
    }

    @Test("healthy CLIs give a clean report that carries no account data")
    func cleanRun() {
        installClaudeAndCodex()
        let report = rig.run(runner(), frozen: frozen()).report()
        #expect(!report.hasDrift)
        #expect(report.findings.map(\.check) == [
            "Codex protocol — the CLI the app runs (1.2.3)",
            "Codex answer fields the app does not read",
            "Claude CLI text", "Codex CLI text — the CLI the app runs",
            "Claude `/usage` (live)", "Claude `auth status --json` (live)",
            "Codex `account/rateLimits/read` (live)",
        ])
        #expect(report.findings.map(\.status) == [.ok, .info, .ok, .ok, .ok, .ok, .ok])
        #expect(report.findings[0].summary == "Matches the snapshot frozen from 1.0.0.")
        #expect(report.findings[1].summary == "The rate-limits answer has 2 fields the app does not read.")
        #expect(report.tools == [
            DriftReport.Tool(name: "Claude", path: "~/bin/claude", version: nil),
            DriftReport.Tool(name: "Codex", path: "~/bin/codex", version: "1.2.3"),
        ])
        let text = Redaction.scrub(report.markdown(), home: rig.home)
        #expect(text.contains("**No drift found.**"))
        for secret in [Sample.email, Sample.accountId, "Asia/Seoul", "private-server", "Someone's Org",
                       rig.home.path, "other-limit"] {
            #expect(!text.contains(secret))
        }
    }

    @Test("a protocol change the parser reads is drift, listed first")
    func protocolDrift() {
        installClaudeAndCodex()
        let runner = runner { files in
            for name in files.keys {
                guard var definitions = files[name]?["definitions"] as? [String: Any],
                      var window = definitions["RateLimitWindow"] as? [String: Any],
                      var properties = window["properties"] as? [String: Any] else { continue }
                properties["usedPercent"] = nil
                properties["usedFraction"] = ["type": "number"]
                window["properties"] = properties
                window["required"] = [String]()
                definitions["RateLimitWindow"] = window
                files[name]?["definitions"] = definitions
            }
        }
        let report = rig.run(runner, frozen: frozen()).report()
        #expect(report.hasDrift)
        let finding = report.findings[0]
        #expect(finding.status == .drift)
        #expect(finding.summary == "1 of 2 changes since the snapshot frozen from 1.0.0 touch what the app sends or reads.")
        #expect(finding.details == [
            "**read by the app** — removed `RateLimitWindow.usedPercent` (was `integer<int32> (required)`)",
            "added `RateLimitWindow.usedFraction`: `number`",
        ])
    }

    @Test("a protocol change the parser doesn't read is only information")
    func protocolInformation() {
        installClaudeAndCodex()
        let runner = runner { files in
            var requests = files["ClientRequest.json"]?["oneOf"] as? [[String: Any]] ?? []
            requests.append(["properties": ["method": ["enum": ["account/securitySetup/read"]],
                                            "params": ["type": "null"]]])
            files["ClientRequest.json"]?["oneOf"] = requests
        }
        let report = rig.run(runner, frozen: frozen()).report()
        #expect(!report.hasDrift)
        #expect(report.findings[0].status == .info)
        #expect(report.findings[0].summary
            == "1 change since the snapshot frozen from 1.0.0; none touches what the app sends or reads.")
        #expect(report.findings[0].details == ["added `request account/securitySetup/read`: `null`"])
    }

    @Test("a retyped member shows both shapes")
    func changedLine() {
        #expect(DriftRun.line(ProtocolChange(kind: .changed, path: "A.b", before: "string", after: "number",
                                             affectsApp: false)) == "changed `A.b`: `string` → `number`")
    }

    @Test("without a frozen snapshot, or a CLI that can't write its schema, nothing is compared")
    func protocolNotCompared() {
        installClaudeAndCodex()
        #expect(status(rig.run(runner()).report(), "Codex protocol") == .attention)
        let failing = rig.run(runner(generates: false), frozen: frozen()).report()
        #expect(status(failing, "Codex protocol") == .attention)
        #expect(!failing.findings.contains { $0.check == "Codex answer fields the app does not read" })
        #expect(!failing.hasDrift)
    }

    @Test("a schema bundle the reader can't follow any more is drift")
    func unreadableBundle() {
        installClaudeAndCodex()
        let report = rig.run(runner(writesSchema: false), frozen: frozen()).report()
        #expect(status(report, "Codex protocol") == .drift)
        #expect(report.findings[0].summary.contains("`ClientRequest.json`"))
    }

    @Test("text gone from a CLI is drift, with the reason it matters")
    func missingText() {
        _ = rig.cli("claude", containing: StringContracts.claude.filter { $0.label != "Current session" })
        let report = rig.run(runner()).report()
        let finding = report.findings.first { $0.check == "Claude CLI text" }
        #expect(finding?.status == .drift)
        #expect(finding?.summary
            == "Gone: 1 of \(StringContracts.claude.count) pieces of text the app's parsers depend on.")
        #expect(finding?.details == ["`Current session` — ClaudeUsageText reads the usage windows from this panel line"])
    }

    @Test("the app's bundled Codex CLI and a different one on PATH are both checked")
    func twoCodexCLIs() throws {
        installClaudeAndCodex()
        let bundled = rig.folder.write("#!/bin/sh\nexec real \"$@\"\n", to: "Codex.app/bin/codex", executable: true)
        let runner = FakeRunner { [fake = runner()] request in
            request.arguments == ["--version"]
                ? UsageProcessResult(lines: [request.executable == bundled ? "codex-cli 2.0.0-alpha.1" : "codex-cli 1.2.3"],
                                     outcome: .exited(0))
                : fake.run(request)
        }
        let report = rig.run(runner, frozen: frozen(), bundledCodexCLI: bundled).report()
        #expect(report.findings.map(\.check).filter { $0.hasPrefix("Codex") } == [
            "Codex protocol — the CLI the app runs (2.0.0-alpha.1)", "Codex protocol — codex on PATH (1.2.3)",
            "Codex answer fields the app does not read",
            "Codex CLI text — the CLI the app runs", "Codex CLI text — codex on PATH",
            "Codex `account/rateLimits/read` (live)",
        ])
        #expect(status(report, "Codex CLI text — the CLI the app runs") == .skipped)
        #expect(status(report, "Codex CLI text — codex on PATH") == .ok)
        // The live read goes through the CLI the app runs.
        let live = try #require(runner.requests.first { $0.arguments == ["--disable", "plugins", "app-server"] })
        #expect(live.executable == bundled)
        #expect(report.tools.last == DriftReport.Tool(name: "Codex", path: Redaction.display(bundled, home: rig.home),
                                                      version: "2.0.0-alpha.1"))
    }

    @Test("a CLI whose version can't be read is still checked")
    func unknownVersion() {
        installClaudeAndCodex()
        let report = rig.run(runner(version: "no version here"), frozen: frozen()).report()
        #expect(report.findings[0].check == "Codex protocol — the CLI the app runs")
        #expect(report.findings[0].status == .ok)
    }

    @Test("tools that need a stored sign-in are listed as not checked and never started")
    func consentedTools() {
        _ = rig.cli("gh")
        _ = rig.cli("cursor-agent")
        _ = rig.cli("agy", containing: StringContracts.antigravity)
        let runner = runner()
        let report = rig.run(runner).report()
        #expect(report.findings.map(\.check) == ["Antigravity CLI text", "Usage reads that need a stored sign-in"])
        #expect(report.findings.map(\.status) == [.ok, .notChecked])
        #expect(report.findings[0].summary == "All present: 1 piece of text the app's parsers depend on.")
        #expect(report.findings[1].details == ["Cursor", "Antigravity", "GitHub Copilot"])
        #expect(runner.requests.isEmpty)
        #expect(!report.hasDrift)
    }

    @Test("the Gemini CLI is asked for its sign-in client through the app's finder")
    func geminiClient() {
        rig.folder.write(Data([0xCF, 0xFA]), to: "pkg/node_modules/@google/gemini-cli/bundle/gemini", executable: true)
        let roots = UsageSearchRoots(
            executableDirectories: [rig.folder.url.appendingPathComponent("pkg/node_modules/@google/gemini-cli/bundle")],
            applicationDirectories: [])
        for (found, expected) in [(true, DriftStatus.ok), (false, .drift)] {
            var run = rig.run(runner(), gemini: StubGeminiClient(found: found))
            run.searchRoots = roots
            let report = run.report()
            #expect(report.findings.first?.check == "Gemini CLI sign-in client")
            #expect(report.findings.first?.status == expected)
        }
    }

    @Test("with nothing installed there is nothing to report")
    func nothingInstalled() {
        let runner = runner()
        let report = rig.run(runner, frozen: frozen()).report()
        #expect(report.tools.isEmpty && report.findings.isEmpty)
        #expect(runner.requests.isEmpty)
        #expect(rig.run(runner).installedSnapshot() == nil)
    }

    @Test("a fresh snapshot comes from the CLI the app runs, or the one that is named")
    func refreshingTheSnapshot() {
        installClaudeAndCodex()
        let fresh = rig.run(runner()).installedSnapshot()
        #expect(fresh?.cliVersion == "1.2.3")
        #expect(fresh?.requests["account/rateLimits/read"] != nil)
        let other = rig.folder.write(Data([0xCF]), to: "other/codex", executable: true)
        let runner = runner(version: "codex-cli 3.0.0")
        #expect(rig.run(runner).installedSnapshot(cli: other)?.cliVersion == "3.0.0")
        #expect(runner.requests.allSatisfy { $0.executable == other })
        #expect(rig.run(self.runner(generates: false)).installedSnapshot() == nil)
    }
}
