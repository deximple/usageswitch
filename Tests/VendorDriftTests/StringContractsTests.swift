import Foundation
import Testing
@testable import SwitcherCore
@testable import VendorDrift

@Suite("String contracts")
struct StringContractsTests {
    private func labels(_ contracts: [StringContract]) -> [String] { contracts.map(\.label) }

    @Test("a command line gives its long options, its output format and its settings keys")
    func invocation() {
        #expect(StringContracts.invocation(["-p", "--alpha", "value", #"{"zeta":true,"beta":1}"#, "/usage",
                                            "--output-format", "stream-json", "{not json"])
            == ["--alpha", "beta", "zeta", "--output-format", "stream-json"])
    }

    @Test("the Claude contracts cover every flag and setting the app's collector passes")
    func claudeCoversInvocation() {
        let labels = labels(StringContracts.claude)
        for flag in ClaudeUsageCollector.arguments where flag.hasPrefix("--") {
            #expect(labels.contains(flag))
        }
        #expect(labels.contains("disableAllHooks"))
        #expect(labels.contains("disableClaudeAiConnectors"))
        #expect(labels.contains("stream-json"))
    }

    @Test("the Claude panel contracts are the text the app's parser reads")
    func claudePanelMatchesParser() throws {
        let labels = labels(StringContracts.claude)
        let separator = try #require(labels.first { $0.hasPrefix("% used") })
        let readAt = Date(timeIntervalSince1970: 1_794_000_000)
        for title in ["Current session", "Current week (all models)"] {
            #expect(labels.contains(title))
            let line = "\(title): 12\(separator)Nov 6 at 12:59pm (Asia/Seoul)"
            #expect(try ClaudeUsageText.windows(line, readAt: readAt).get().count == 1)
        }
    }

    @Test("the Claude stream contracts are the fields the app's output reader decides on")
    func claudeStreamMatchesReader() {
        let labels = labels(StringContracts.claude)
        // A local answer is recognised by the placeholder model name; any other model stops the run.
        #expect(labels.contains("<synthetic>"))
        #expect(ClaudeUsageOutput.stops(#"{"type":"assistant","message":{"model":"<synthetic>"}}"#) == false)
        #expect(ClaudeUsageOutput.stops(#"{"type":"assistant","message":{"model":"another"}}"#))
        // Turns, cost and the error flag each turn a result into a failure.
        for (field, value) in [("num_turns", "1"), ("total_cost_usd", "0.5"), ("is_error", "true")] {
            #expect(labels.contains(field))
            let line = #"{"type":"result","result":"x","\#(field)":\#(value)}"#
            #expect((try? ClaudeUsageOutput.text(in: [line]).get()) == nil)
        }
    }

    @Test("the Codex contracts are what the app's collector sends and its parser maps")
    func codexMatchesApp() {
        let labels = labels(StringContracts.codex)
        let sent = CodexUsageCollector.stdinLines(version: "1.0").joined()
        #expect(labels.contains("account/rateLimits/read") && sent.contains("account/rateLimits/read"))
        #expect(labels.contains("excludeResetCreditDetails") && sent.contains("excludeResetCreditDetails"))
        #expect(labels.contains("chatgpt authentication required"))
        #expect(CodexRateLimitsParser.failure(for: ["message": "chatgpt authentication required"]) == .notReporting)
        #expect(labels.contains("authentication required"))
        #expect(CodexRateLimitsParser.failure(for: ["message": "authentication required"]) == .noSignIn)
    }

    @Test("the Antigravity contract is the title the app's screen reader looks for")
    func antigravityMatchesScreenReader() {
        for label in labels(StringContracts.antigravity) {
            #expect(AntigravityUsageScreen.containsQuotaTitle(Data("\(label)\r\n".utf8)))
        }
        #expect(!AntigravityUsageScreen.containsQuotaTitle(Data("Something else\r\n".utf8)))
    }

    // MARK: - Searching a file

    private let contracts = [StringContract("Current session", reason: "a"),
                             StringContract("% used", reason: "b")]

    @Test("text found anywhere in the file is present; the rest is reported missing")
    func scanning() {
        let folder = TempFolder()
        let binary = Data([0xCF, 0xFA, 0xED, 0xFE, 0x00]) + Data("…Current session\u{0}junk".utf8)
        let file = folder.write(binary, to: "cli")
        #expect(BinaryStrings.scan(contracts, in: file) == .scanned(missing: [contracts[1]]))
        #expect(BinaryStrings.scan([contracts[0]], in: file) == .scanned(missing: []))
    }

    @Test("the panel separator is found however the binary stores its middle dot")
    func separatorEncodings() throws {
        let folder = TempFolder()
        let separator = try #require(StringContracts.claude.first { $0.label.hasPrefix("% used") })
        let encodings: [Data] = [
            Data(#"x% used \xB7 resets ${y}"#.utf8),
            Data("x% used · resets y".utf8),
            Data("x% used ".utf8) + Data([0xB7]) + Data(" resets y".utf8),
        ]
        for (index, bytes) in encodings.enumerated() {
            #expect(BinaryStrings.scan([separator], in: folder.write(bytes, to: "cli-\(index)"))
                == .scanned(missing: []))
        }
        #expect(BinaryStrings.scan([separator], in: folder.write("x% used, resets y", to: "changed"))
            == .scanned(missing: [separator]))
    }

    @Test("a launcher script is told apart; a missing or empty file is unreadable, not drift")
    func unusualFiles() {
        let folder = TempFolder()
        #expect(BinaryStrings.scan(contracts, in: folder.write("#!/bin/sh\nexec real \"$@\"\n", to: "launcher"))
            == .script)
        #expect(BinaryStrings.scan(contracts, in: folder.url.appendingPathComponent("absent")) == .unreadable)
        #expect(BinaryStrings.scan(contracts, in: folder.write(Data(), to: "empty")) == .unreadable)
        #expect(BinaryStrings.scan(contracts, in: folder.write("x", to: "tiny")) == .scanned(missing: contracts))
    }
}
