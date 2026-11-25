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
        let rig = try Rig.make(); defer { rig.cleanup() }
        // `remove` without --yes asks first — before touching the saved sign-in.
        let out = StringSink()
        let code = CLI.run(args: ["remove", FakeIdentity.b.key], switcher: rig.switcher,
                           codex: CodexManager(env: rig.env, table: EmptyTable()),
                           out: { out.text += $0 }, err: { _ in })
        #expect(code == 3)
        #expect(out.text.contains("needs_confirmation"))
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) != nil)
    }

    // MARK: - A failed switch (audit T-2): the only signal a script has to tell "restored" from "needs recovery"

    /// The exit code and the printed `error` object of `switch`.
    private func runSwitch(_ rig: Rig, fault: Bool = true) throws -> (Int32, [String: String]) {
        let out = StringSink()
        var args = ["switch", FakeIdentity.b.key]
        if fault { args += ["--inject-fault", "post-swap-verify"] }
        let code = CLI.run(args: args, switcher: rig.switcher, codex: CodexManager(env: rig.env, table: EmptyTable()),
                           out: { out.text += $0 }, err: { _ in })
        let envelope = try JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any]
        return (code, try #require(envelope?["error"] as? [String: String]))
    }

    private func faultRig() throws -> Rig {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        return try Rig.make(options: options)
    }

    @Test func aConfirmedRollbackIs1() throws {
        let rig = try faultRig(); defer { rig.cleanup() }
        let (code, error) = try runSwitch(rig)
        #expect(code == 1)
        #expect(error["rollback"] == "verified")
    }

    @Test func anUnconfirmedRollbackIs2() throws {
        let rig = try faultRig(); defer { rig.cleanup() }
        rig.world.update { $0.afterLaunch = { $0.launchError = .launchFailed("LaunchServices refused") } }
        let (code, error) = try runSwitch(rig)
        #expect(code == 2)
        #expect(error["rollback"] == "unverified")
    }

    @Test func aFailedRollbackIs4() throws {
        let rig = try faultRig(); defer { rig.cleanup() }
        rig.world.update { $0.afterLaunch = { $0.quitMode = .ignore } }
        let (code, error) = try runSwitch(rig)
        #expect(code == 4)
        #expect(error["rollback"] == "failed")
    }

    @Test func anInterruptedSwapIs4() throws {
        // Claude starts mid-swap and won't quit: the files are left for recovery.
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .ignore; $0.spawnClaudeWhenJournalApplied = 1 }
        let (code, error) = try runSwitch(rig, fault: false)
        #expect(code == 4)
        #expect(error["code"] == "swap_interrupted")
    }

    // MARK: - Signals (audit T-5)

    @Test func theTestableEntryPointLeavesSignalsAlone() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let previous = signal(SIGINT, SIG_DFL)
        defer { signal(SIGINT, previous) }
        _ = run(sb, ["status"])
        var current = sigaction()
        sigaction(SIGINT, nil, &current)
        // SIG_DFL is 0 and SIG_IGN is 1.
        #expect(unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 0)
    }

    @Test func commandsThatMoveFilesIgnoreInterruption() {
        for args in [["switch", "x"], ["capture"], ["enroll"], ["recover"], ["remove", "x"], ["status"], ["list"],
                     ["codex", "remove", "x"], ["codex", "reauth", "x"], ["--lang", "ko", "status"]] {
            #expect(CLI.ignoresInterruption(args), "\(args)")
        }
        for args in [[], ["usage"], ["rename", "x", "y"], ["language", "ko"], ["codex", "status"], ["codex"]] {
            #expect(!CLI.ignoresInterruption(args), "\(args)")
        }
    }

    @Test func codexRemoveNeedsYes() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let (code, out, _) = run(sb, ["codex", "remove", "work"])
        #expect(code == 3)
        #expect(out.contains("needs_confirmation"))
        // With --yes the guard passes; the removal itself then runs and finds no such account.
        let removed = run(sb, ["codex", "remove", "work", "--yes"])
        #expect(removed.0 == 1)
        #expect(removed.1.contains("unknown_account"))
    }
}

/// A reader that went away (`--cli switch … | head -1`, a script that died) must not end the CLI in
/// the middle of a switch: SIGPIPE killed it before relaunchers were restored (audit C-1).
@Suite("CLI output to a closed pipe (audit C-1)")
struct CLIBrokenPipeTests {
    /// A pipe whose read end is already closed: every write gets EPIPE.
    static func brokenPipe() throws -> Int32 {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        return fds[1]
    }

    @Test func brokenPipesStopRaisingSIGPIPE() throws {
        let fd = try Self.brokenPipe()
        defer { close(fd) }
        CLI.ignoreBrokenPipes(on: [fd])
        #expect(fcntl(fd, F_GETNOSIGPIPE) == 1)
        let byte: [UInt8] = [0x78]
        // Still alive: the write fails with EPIPE instead of killing the process.
        #expect(write(fd, byte, 1) == -1 && errno == EPIPE)
    }

    @Test func writingToABrokenPipeReportsFailureInsteadOfRaising() throws {
        let fd = try Self.brokenPipe()
        CLI.ignoreBrokenPipes(on: [fd])
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #expect(!CLI.write("{\"ok\":true}\n", to: handle))
        let open = try Self.openPipe()
        defer { close(open.read) }
        #expect(CLI.write("x", to: FileHandle(fileDescriptor: open.write, closeOnDealloc: true)))
    }

    static func openPipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }
}
