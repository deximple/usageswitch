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

    @Test("each Antigravity contract is wording the app's screen reader acts on")
    func antigravityMatchesScreenReader() throws {
        let labels = labels(StringContracts.antigravity)
        #expect(labels == ["Models & Quota", "? for shortcuts", "Refreshes in"])

        // The quota screen is found by its title.
        #expect(AntigravityUsageScreen.containsQuotaTitle(Data("Models & Quota\r\n".utf8)))
        #expect(!AntigravityUsageScreen.containsQuotaTitle(Data("Something else\r\n".utf8)))

        // /usage is typed and submitted only at the prompt that shows the shortcuts hint.
        var prompt = AntigravityVTScreenBuffer()
        prompt.feed(Data("> /usage\r\n? for shortcuts\r\n".utf8))
        #expect(prompt.canSubmitUsage)
        var other = AntigravityVTScreenBuffer()
        other.feed(Data("> /usage\r\nSomething else\r\n".utf8))
        #expect(!other.canSubmitUsage)

        // Each limit's reset time is read from the "Refreshes in" line.
        let now = Date(timeIntervalSince1970: 1_794_584_700)
        let screen = "Models & Quota\nGEMINI MODELS\nWeekly Limit Remaining\n[██] 50%\nRefreshes in 2h 5m\n"
        let windows = try #require(AntigravityUsageScreen.parse(Data(screen.utf8), now: now))
        #expect(windows.first?.resetsAt == now.addingTimeInterval(2 * 3600 + 5 * 60))
    }

    // MARK: - Searching a file

    private let contracts = [StringContract("Current session", reason: "a"),
                             StringContract("% used", reason: "b")]

    @Test("text found anywhere in the file is present; the rest is reported missing")
    func scanning() {
        let folder = TempFolder()
        let file = folder.write(bytes(machOMagic, then: "\u{0}…Current session\u{0}junk"), to: "cli")
        #expect(BinaryStrings.scan(contracts, in: file) == .scanned(missing: [contracts[1]]))
        #expect(BinaryStrings.scan([contracts[0]], in: file) == .scanned(missing: []))
    }

    @Test("the panel separator is found however the binary stores its middle dot")
    func separatorEncodings() throws {
        let folder = TempFolder()
        let separator = try #require(StringContracts.claude.first { $0.label.hasPrefix("% used") })
        var latin1 = Data("x% used ".utf8)
        latin1.append(0xB7)
        latin1.append(Data(" resets y".utf8))
        let escaped = Data(#"x% used \xB7 resets ${y}"#.utf8)
        let utf8 = Data("x% used · resets y".utf8)
        let encodings: [Data] = [escaped, utf8, latin1]
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
