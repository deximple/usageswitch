import Foundation
import Testing
@testable import VendorDrift

@Suite("Drift report")
struct DriftReportTests {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let utc = TimeZone(identifier: "UTC")!

    private func report(_ findings: [DriftFinding], tools: [DriftReport.Tool] = []) -> DriftReport {
        DriftReport(generatedAt: Date(timeIntervalSince1970: 1_794_000_000), tools: tools, findings: findings)
    }

    @Test("a clean run says so and lists every check under its section")
    func cleanReport() {
        let report = report([
            DriftFinding(.codexProtocol, "Codex protocol", .ok, "Matches."),
            DriftFinding(.live, "Claude read", .attention, "No answer.", details: ["one", "two"]),
        ], tools: [DriftReport.Tool(name: "Claude", path: "~/.local/bin/claude", version: "2.1.323"),
                   DriftReport.Tool(name: "Cursor", path: "~/.local/bin/cursor-agent", version: nil)])
        let text = report.markdown(timeZone: utc)
        #expect(!report.hasDrift)
        #expect(text.hasPrefix("# Vendor drift report — 2026-11-06 21:20\n"))
        #expect(text.contains("**No drift found.** 1 more worth a look."))
        #expect(text.contains("| Codex protocol | ok | Matches. |"))
        #expect(text.contains("- Claude: `~/.local/bin/claude` — 2.1.323\n- Cursor: `~/.local/bin/cursor-agent`\n"))
        #expect(text.contains("## Codex app-server protocol\n\n### Codex protocol — ok\n\nMatches.\n"))
        #expect(text.contains("### Claude read — look\n\nNo answer.\n\n- one\n- two\n"))
        #expect(!text.contains("## Text the parsers depend on"))
        #expect(text.contains("## Running this regularly\n\nNothing was scheduled by this run."))
    }

    @Test("drift is counted in the headline", arguments: [(1, "1 check needs a fix"), (2, "2 checks need a fix")])
    func driftHeadline(count: Int, phrase: String) {
        let report = report((0..<count).map { DriftFinding(.strings, "Check \($0)", .drift, "Gone.") })
        #expect(report.hasDrift)
        #expect(report.markdown(timeZone: utc).contains("**Drift found: \(phrase).**\n"))
    }

    @Test("with nothing installed the report says so; table cells can't break the table")
    func edges() {
        #expect(report([]).markdown(timeZone: utc).contains("None of the tools UsageSwitch reads is installed."))
        let text = report([DriftFinding(.notChecked, "a|b", .notChecked, "line one\nline two")]).markdown(timeZone: utc)
        #expect(text.contains(#"| a\|b | not checked | line one line two |"#))
        #expect(DriftStatus.info.label == "info" && DriftStatus.skipped.label == "skipped")
    }

    @Test("anything shaped like account data is taken out of the printed text")
    func scrubbing() {
        // Put together here so the repository itself holds nothing shaped like a secret.
        let jwt = ["eyJ" + "hbGciOiJIUzI1NiJ9", "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIn0", "abc_DEF-123"].joined(separator: ".")
        let key = "sk-" + "proj-" + "abcdefghijklmnop1234"
        let text = """
            path /Users/someone/.local/bin/claude and /Users/someone
            mail \(Sample.email) id \(Sample.accountId)
            jwt \(jwt) key \(key)
            other /private/Users/someone/bin/x and /Users/another-person/bin/y
            ids org-AbCdEf123456 user_0123456789 header Bearer abc.def hex 0123456789abcdef0123456789abcdef
            kept: usedPercent integer<int32> 0.169.0-alpha.11.1 ConsumeAccountRateLimitResetCreditResponse
            """
        #expect(Redaction.scrub(text, home: home) == """
            path ~/.local/bin/claude and ~
            mail <email> id <id>
            jwt <token> key <token>
            other /private/Users/<user>/bin/x and /Users/<user>/bin/y
            ids <id> <id> header <token> hex <token>
            kept: usedPercent integer<int32> 0.169.0-alpha.11.1 ConsumeAccountRateLimitResetCreditResponse
            """)
    }

    @Test("paths under the home folder are shown from ~")
    func displayPaths() {
        #expect(Redaction.display(URL(fileURLWithPath: "/Users/someone/.local/bin/claude"), home: home)
            == "~/.local/bin/claude")
        #expect(Redaction.display(home, home: home) == "~")
        #expect(Redaction.display(URL(fileURLWithPath: "/Users/someone-else/bin/x"), home: home)
            == "/Users/someone-else/bin/x")
        #expect(Redaction.display(URL(fileURLWithPath: "/opt/homebrew/bin/gh"), home: home) == "/opt/homebrew/bin/gh")
    }

    @Test("a JSON shape is key names and types — never a value, never an unvetted key")
    func jsonShape() {
        let value: [String: Any] = [
            "email": Sample.email, "count": 3, "on": true, "none": NSNull(), "list": [1, 2],
            "nested": ["inner": ["deep": ["deeper": "x"]]],
            "byId": ["first-id": ["used": 1], "second-id": ["used": 2, "extra": "x"]],
            "surprise-\(Sample.accountId)": "x",
        ]
        let known: Set<String> = ["email", "count", "on", "none", "list", "nested", "inner", "deep", "deeper",
                                  "byId", "used"]
        #expect(JSONShape.keys(of: value, depth: 3, known: known) == [
            "*: string", "byId.*.*: string", "byId.*.used: number", "byId.*: object", "byId: object",
            "count: number", "email: string", "list: array", "nested.inner.deep: object",
            "nested.inner: object", "nested: object", "none: null", "on: boolean",
        ])
        #expect(JSONShape.keys(of: value, depth: 1, known: ["email"]) == [
            "*: array", "*: boolean", "*: null", "*: number", "*: object", "*: string", "email: string",
        ])
        #expect(JSONShape.keys(of: "text", known: []).isEmpty)
    }

    @Test("the command line is parsed, and its mistakes are named")
    func arguments() {
        #expect(DriftArguments.parse(["--work", "/w", "--snapshot", "/s"])
            == .success(DriftArguments(work: "/w", snapshot: "/s", updateSnapshot: false, codex: nil)))
        #expect(DriftArguments.parse(["--update-snapshot", "--codex", "/c", "--work", "/w"])
            == .success(DriftArguments(work: "/w", snapshot: nil, updateSnapshot: true, codex: "/c")))
        #expect(DriftArguments.parse(["--snapshot", "/s"]) == .failure(.workRequired))
        #expect(DriftArguments.parse(["--work"]) == .failure(.missingValue("--work")))
        #expect(DriftArguments.parse(["--work", "/w", "--nope"]) == .failure(.unknown("--nope")))
    }
}
