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

private struct EmptyTable: ProcessTable {
    func all() -> [ProcInfo]? { [] }
    func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] { [:] }
}

/// A clock stopped at one instant; the CLI reads it for the age of the usage snapshot.
private struct StoppedClock: Clock {
    let date: Date
    func now() -> Date { date }
    func uptime() -> TimeInterval { 0 }
    func sleep(_ seconds: TimeInterval) {}
}

@Suite("CLI exit codes (audit B-13)")
struct CLITests {
    /// CLI.run with a sandboxed switcher + codex manager; returns (exit, stdout, stderr).
    /// The process table is an empty fake — the sandbox env must never see the host's Claude.
    private func run(_ sb: Sandbox, _ args: [String], clock: Clock = SystemClock()) -> (Int32, String, String) {
        let out = StringSink(), err = StringSink()
        let switcher = Switcher(env: sb.env, table: EmptyTable(), clock: clock)
        let codex = CodexManager(env: sb.env, table: EmptyTable())
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

    @Test func usageAddsTheSnapshotAgeAndLeavesTheFileAlone() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = AccountUsage(
            id: "codex:a", provider: .codex, accountRef: "a", label: "Work", plan: nil,
            windows: [UsageWindow(durationMinutes: 10080, usedPercent: 31, resetsAt: written.addingTimeInterval(3600))],
            state: .ok, readAt: written, toolVersion: nil)
        try UsageSnapshot(usages: [reading], generatedAt: written, showEmails: false).write(env: sb.env, fs: sb.fs)
        let file = try Data(contentsOf: sb.env.usageSnapshotFile)
        func result(_ out: String) throws -> [String: Any] {
            let envelope = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
            return try #require(envelope?["result"] as? [String: Any])
        }
        func canonical(_ object: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }

        // Three days on, the snapshot still says "ok"; only the age tells it is old.
        let later = run(sb, ["usage"], clock: StoppedClock(date: written.addingTimeInterval(3 * 86_400 + 0.9)))
        #expect(later.0 == 0)
        var printed = try result(later.1)
        #expect(printed["ageSeconds"] as? Int == 259_200)
        // Every other field is the file's, name for name.
        printed["ageSeconds"] = nil
        #expect(try canonical(printed) == canonical(try JSONSerialization.jsonObject(with: file)))

        // A snapshot dated ahead of the clock is 0 seconds old, not a negative age.
        let earlier = run(sb, ["usage"], clock: StoppedClock(date: written.addingTimeInterval(-60)))
        #expect(try result(earlier.1)["ageSeconds"] as? Int == 0)

        // The age exists at print time only.
        #expect(try Data(contentsOf: sb.env.usageSnapshotFile) == file)
        #expect(!String(decoding: file, as: UTF8.self).contains("ageSeconds"))
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

    @Test func removeNeedsYes() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        // `remove` without --yes asks first — before touching the saved sign-in.
        let (code, out, _) = run(sb, ["remove", "someone@example.com"])
        #expect(code == 3)
        #expect(out.contains("needs_confirmation"))
        #expect(!sb.env.storeDir.appendingPathComponent("snapshots").path.isEmpty)
    }

    @Test func codexRemoveNeedsYes() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let (code, out, _) = run(sb, ["codex", "remove", "work"])
        #expect(code == 3)
        #expect(out.contains("needs_confirmation"))
        // With --yes the guard passes; the removal itself then runs.
        #expect(run(sb, ["codex", "remove", "work", "--yes"]).0 != 3)
    }
}
