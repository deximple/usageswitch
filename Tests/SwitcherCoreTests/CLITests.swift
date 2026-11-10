import Foundation
import Testing
@testable import SwitcherCore

private final class StringSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return _text }
        set { lock.lock(); defer { lock.unlock() }; _text = newValue }
    }
}

@Suite("CLI exit codes (audit B-13)")
struct CLITests {
    /// CLI.run with a sandboxed switcher + codex manager; returns (exit, stdout, stderr).
    private func run(_ sb: Sandbox, _ args: [String]) -> (Int32, String, String) {
        let out = StringSink(), err = StringSink()
        let switcher = Switcher(env: sb.env)
        let codex = CodexManager(env: sb.env)
        let code = CLI.run(args: args, switcher: switcher, codex: codex,
                           out: { out.text += $0 }, err: { err.text += $0 })
        return (code, out.text, err.text)
    }

    @Test func usageErrorsAre64() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        #expect(run(sb, []).0 == 64)                       // no command
        #expect(run(sb, ["bogus"]).0 == 64)               // unknown command
        #expect(run(sb, ["switch"]).0 == 64)              // missing target
        #expect(run(sb, ["codex"]).0 == 64)               // missing subcommand
        #expect(run(sb, ["codex", "bogus"]).0 == 64)
        #expect(run(sb, ["codex", "open"]).0 == 64)       // missing target
    }

    @Test func needsConfirmationIs3() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        // `recover --set-aside` without --yes asks first — before touching the journal.
        let (code, out, _) = run(sb, ["recover", "--set-aside"])
        #expect(code == 3)
        #expect(out.contains("needs_confirmation"))
    }

    @Test func noUsageDataIs1() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let (code, out, _) = run(sb, ["usage"])
        #expect(code == 1)
        #expect(out.contains("no_usage"))
    }

    @Test func statusAndRecoverReport0() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        #expect(run(sb, ["status"]).0 == 0)
        #expect(run(sb, ["recover"]).0 == 0)
    }

    @Test func setAsidePendingJournal() throws {
        // A damaged journal set aside with --yes: destination in JSON, exit 0 when no
        // suspended relauncher needs attention (that path is covered by FakeWorld tests).
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        try Data("{unreadable".utf8).write(to: sb.env.journalFile)
        let (code, out, _) = run(sb, ["recover", "--set-aside", "--yes"])
        #expect(code == 0)
        #expect(out.contains("\"setAside\""))
        #expect(out.contains("needsConfirmation") == false)
    }
}
