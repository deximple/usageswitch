import Foundation
import Testing
@testable import SwitcherCore

@Suite("Claude usage")
struct ClaudeUsageTests {
    /// 2026-11-04 21:00 Asia/Seoul (the reset text "Nov 6 at 12:59pm" is still ahead).
    let readAt = Date(timeIntervalSince1970: 1_793_793_600)

    static func lines(_ fixture: String) -> [String] {
        fixture.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// A collector reading from a temp home, empty managed-settings folders, and an explicit
    /// binary list (the real system locations must never leak into a test).
    func collector(home: URL, binaryPaths: [URL], runner: FakeUsageRunner,
                   managedFolder: URL? = nil, preferences: URL? = nil,
                   workingDirectory: URL = FileManager.default.temporaryDirectory) -> ClaudeUsageCollector {
        let scratch = home.appendingPathComponent("scratch", isDirectory: true)
        let managed = ClaudeManagedSettings(
            folder: managedFolder ?? scratch.appendingPathComponent("ClaudeCode", isDirectory: true),
            preferences: preferences ?? scratch.appendingPathComponent("ManagedPreferences", isDirectory: true))
        return ClaudeUsageCollector(runner: runner, home: home, managed: managed,
                                    binaryPaths: binaryPaths, workingDirectory: workingDirectory, now: { readAt })
    }

    // MARK: - Working directory (audit A-03)

    static let okAnswer = #"{"type":"result","subtype":"success","is_error":false,"result":"You are currently using your subscription to power your Claude Code usage"}"#

    func temporaryUsageSwitchItems() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("usageswitch-") }.count
    }

    @Test func everyReadUsesTheSameWorkingDirectory() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let workDir = home.appendingPathComponent("cli-workdir/claude", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let runner = fakeRunner(answering: Self.okAnswer)
        let collector = collector(home: home, binaryPaths: [try makeBinary(home: home)], runner: runner,
                                  workingDirectory: workDir)
        _ = collector.collect()
        _ = collector.collect()
        #expect(runner.requests.map(\.workingDirectory) == [workDir, workDir])
        #expect(FileManager.default.fileExists(atPath: workDir.path)) // never removed
    }

    @Test func aReadCreatesNothingUnderTheTemporaryDirectory() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let before = temporaryUsageSwitchItems()
        let runner = FakeUsageRunner()
        let seenDuringRun = LockedBox(0)
        runner.respond = { [self] _ in
            seenDuringRun.set(temporaryUsageSwitchItems())
            return UsageProcessResult(lines: Self.lines(Self.okAnswer), outcome: .stopped)
        }
        _ = collector(home: home, binaryPaths: [try makeBinary(home: home)], runner: runner, workingDirectory: home).collect()
        #expect(runner.requests.count == 1)
        #expect(seenDuringRun.get() == before)
        #expect(temporaryUsageSwitchItems() == before)
    }

    @Test func aMissingWorkingDirectoryIsNotReportedAsAMissingCLI() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(answering: Self.okAnswer)
        let missing = home.appendingPathComponent("no-such-dir", isDirectory: true)
        let usage = collector(home: home, binaryPaths: [try makeBinary(home: home)], runner: runner,
                              workingDirectory: missing).collect()
        #expect(usage.state == .failed(.refused))
        #expect(runner.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path)) // the collector never creates it
    }

    func fakeRunner(answering fixture: String, outcome: UsageProcessResult.Outcome = .stopped) -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: Self.lines(fixture), outcome: outcome) }
        return runner
    }

    /// An executable `claude` in the temp home's `.local/bin`.
    @discardableResult
    func makeBinary(home: URL, versioned: Bool = false) throws -> URL {
        let fm = FileManager.default
        if versioned {
            let real = home.appendingPathComponent(".local/share/claude/versions/2.1.317")
            try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: real)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
            let link = home.appendingPathComponent(".local/bin/claude")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
            return link
        }
        let binary = home.appendingPathComponent(".local/bin/claude")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary
    }

    func tempHome(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("us-tests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("2.1.317 fixture: two weekly windows, plan-wide and Fable")
    func liveFixture() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home, versioned: true)
        let runner = fakeRunner(answering: UsageFixture.claude_2_1_317)
        let usage = collector(home: home, binaryPaths: [binary], runner: runner).collect()
        #expect(usage.state == .ok)
        #expect(usage.id == "claude:cli")
        #expect(usage.label == "CLI sign-in")
        #expect(usage.toolVersion == "2.1.317")
        #expect(usage.windows.count == 2)
        #expect(usage.windows.map(\.kind) == [.weekly, .weekly])
        #expect(usage.windows.map(\.scope) == [nil, "Fable"])
        #expect(usage.windows.map(\.usedPercent) == [75, 3])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6,
                                                                       hour: 12, minute: 59)))
        #expect(usage.windows[0].resetsAt == expected)
    }

    @Test("a time-only reset means its next occurrence — after 7:40pm, tomorrow")
    func timeOnlyResetRollsToNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4,
                                                                      hour: 21, minute: 0)))
        let result = ClaudeUsageText.windows(
            "Current session: 40% used · resets 7:40pm (Asia/Seoul)", readAt: evening)
        let windows = try #require(try? result.get())
        #expect(windows.count == 1)
        #expect(windows[0].kind == .session)
        #expect(windows[0].durationMinutes == 300)
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5,
                                                                       hour: 19, minute: 40)))
        #expect(windows[0].resetsAt == expected)
        // Before 7:40pm the same text means tonight.
        let afternoon = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4,
                                                                        hour: 15, minute: 0)))
        let same = try #require(try? ClaudeUsageText.windows(
            "Current session: 40% used · resets 7:40pm (Asia/Seoul)", readAt: afternoon).get())
        #expect(same[0].resetsAt == calendar.date(from: DateComponents(year: 2026, month: 11, day: 4,
                                                                      hour: 19, minute: 40)))
    }

    @Test("text parsing: no Current line is notReporting, an unknown Current line is unreadable")
    func textFailures() {
        let noWindows = ClaudeUsageText.windows("You are on the API plan\nNo limits to show", readAt: readAt)
        #expect(noWindows == .failure(.notReporting))
        let malformed = ClaudeUsageText.windows("Current week: 75% used, resets soon", readAt: readAt)
        #expect(malformed == .failure(.unreadable))
    }

    @Test("a hook event, a real model turn, turns or cost refuse the whole output")
    func outputRefusals() {
        let fixture = Self.lines(UsageFixture.claude_2_1_317)
        guard case .success(let text) = ClaudeUsageOutput.text(in: fixture) else {
            Issue.record("fixture should parse"); return
        }
        #expect(text.hasPrefix("You are currently using your subscription"))
        // each case: replace or prepend the offending line
        let hook = [#"{"type":"system","subtype":"hook_started"}"#] + fixture
        #expect(ClaudeUsageOutput.text(in: hook) == .failure(.stopped))
        let model = fixture.dropLast() + [#"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#,
                                          fixture.last!]
        #expect(ClaudeUsageOutput.text(in: Array(model)) == .failure(.stopped))
        let turns = fixture.dropLast() + [#"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0,"result":"x"}"#]
        #expect(ClaudeUsageOutput.text(in: Array(turns)) == .failure(.stopped))
        let cost = fixture.dropLast() + [#"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"total_cost_usd":0.01,"result":"x"}"#]
        #expect(ClaudeUsageOutput.text(in: Array(cost)) == .failure(.stopped))
        let error = fixture.dropLast() + [#"{"type":"result","subtype":"success","is_error":true,"num_turns":0,"total_cost_usd":0,"result":"x"}"#]
        #expect(ClaudeUsageOutput.text(in: Array(error)) == .failure(.unreadable))
        #expect(ClaudeUsageOutput.text(in: []) == .failure(.unreadable))
    }

    @Test("hook line and non-synthetic turn refuse the run; the stop predicate catches them")
    func collectorRefusals() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home)
        let hooked = """
            {"type":"system","subtype":"hook_started"}
            {"type":"result","subtype":"success","is_error":false,"num_turns":0,"total_cost_usd":0,"result":"x"}
            """
        var runner = fakeRunner(answering: hooked)
        #expect(collector(home: home, binaryPaths: [binary], runner: runner).collect().state == .unavailable(.refused))
        runner = FakeUsageRunner()
        _ = collector(home: home, binaryPaths: [binary], runner: runner).collect()
        let stop = try #require(runner.requests.first?.stopWhen)
        #expect(stop(#"{"type":"system","subtype":"hook_response"}"#))
        #expect(stop(#"{"type":"assistant","message":{"model":"claude-opus-5-5"}}"#))
        #expect(!stop(#"{"type":"assistant","message":{"model":"<synthetic>"}}"#))
        #expect(stop(#"{"type":"result","subtype":"success"}"#))
    }

    @Test("no Current line is notReporting; a malformed one is schemaChanged")
    func collectorTextStates() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home)
        @Sendable func output(_ text: String) -> String {
            #"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"total_cost_usd":0,"result":""#
                + text + "\"}"
        }
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [output("Nothing to report here")], outcome: .stopped) }
        #expect(collector(home: home, binaryPaths: [binary], runner: runner).collect().state == .notReporting)
        runner.respond = { _ in UsageProcessResult(lines: [output("Current week: broken shape")], outcome: .stopped) }
        #expect(collector(home: home, binaryPaths: [binary], runner: runner).collect().state == .unavailable(.schemaChanged))
    }

    @Test("managed settings refuse before the binary ever runs")
    func managedRefusal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home)
        let managedFolder = home.appendingPathComponent("sys/Library/Application Support/ClaudeCode", isDirectory: true)
        try FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: managedFolder.appendingPathComponent("managed-settings.json"))
        let runner = fakeRunner(answering: "")
        let usage = collector(home: home, binaryPaths: [binary], runner: runner,
                              managedFolder: managedFolder).collect()
        #expect(usage.state == .unavailable(.managed))
        #expect(runner.requests.isEmpty)
    }

    @Test("a managed-settings.d drop-in or a remote-settings copy also refuses")
    func managedVariants() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home)
        let folder = home.appendingPathComponent("sys/ClaudeCode", isDirectory: true)
        let dropIns = folder.appendingPathComponent("managed-settings.d", isDirectory: true)
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dropIns.appendingPathComponent("org.json"))
        let runner = fakeRunner(answering: "")
        #expect(collector(home: home, binaryPaths: [binary], runner: runner,
                          managedFolder: folder).collect().state == .unavailable(.managed))
        // clean drop-ins, but the account folder holds a server copy
        try? FileManager.default.removeItem(at: dropIns)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: claudeDir.appendingPathComponent("remote-settings.json"))
        #expect(collector(home: home, binaryPaths: [binary], runner: runner,
                          managedFolder: folder).collect().state == .unavailable(.managed))
    }

    @Test("no binary means cliMissing; a non-versioned binary has no toolVersion")
    func discovery() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(answering: "")
        let missing = collector(home: home, binaryPaths: [home.appendingPathComponent(".local/bin/claude")],
                                runner: runner).collect()
        #expect(missing.state == .unavailable(.cliMissing))
        #expect(runner.requests.isEmpty)
        let binary = try makeBinary(home: home) // a plain file, not a versions/ symlink
        #expect(ClaudeUsageCollector.toolVersion(of: binary) == nil)
    }

    @Test("argv is the plan's fixed invocation; env drops CLAUDE_CONFIG_DIR and adds the four flags")
    func requestShape() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = try makeBinary(home: home)
        let runner = fakeRunner(answering: "")
        _ = collector(home: home, binaryPaths: [binary], runner: runner).collect()
        let request = try #require(runner.requests.first)
        #expect(request.executable == binary)
        #expect(request.arguments == [
            "-p", "--setting-sources", "local", "--strict-mcp-config", "--no-session-persistence",
            "--settings", #"{"disableAllHooks":true,"disableClaudeAiConnectors":true}"#,
            "/usage", "--output-format", "stream-json", "--verbose",
        ])
        #expect(request.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(request.environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(request.environment["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false")
        #expect(request.environment["CLAUDE_CODE_AUTO_CONNECT_IDE"] == "0")
        #expect(request.environment["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] == "1")
        #expect(request.stdinLines == nil)
        #expect(request.timeout == 60)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
