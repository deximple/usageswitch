import Foundation
import Testing
@testable import SwitcherCore

@Suite("ClaudeLog")
struct ClaudeLogTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ s: TimeInterval) -> Date { Self.t0.addingTimeInterval(s) }

    @Test func parsesLocalTimestampsAndContinuationLines() {
        let text = """
            orphan line before any timestamp
            \(LogFixture.line(at(0), "[info] Starting app {"))
              version: '1.0.0',
            }
            \(LogFixture.line(at(5), "second"))

            """
        let lines = ClaudeLog.parse(text)
        #expect(lines.count == 4)
        #expect(lines.map(\.timestamp) == [at(0), at(0), at(0), at(5)])
        #expect(lines[1].text == "  version: '1.0.0',")
        let seeded = ClaudeLog.parse("continued\n", initialTimestamp: at(9))
        #expect(seeded == [ClaudeLog.Line(timestamp: at(9), text: "continued")])
    }

    @Test(arguments: ["2026/10/17 09:00:00 x", "2026-10-17 9:00:00 x", "short", "2026-10-1a 09:00:00", "  continuation"])
    func rejectsMalformedTimestamps(raw: String) {
        #expect(ClaudeLog.parseTimestamp(Substring(raw)) == nil)
    }

    @Test func parseTimestampUsesLocalTime() throws {
        let date = try #require(ClaudeLog.parseTimestamp("2026-10-17 09:30:15 [info] x"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone.current
        let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 10, 17, 9, 30, 15])
    }

    @Test func logCalendarIsGregorian() {
        #expect(ClaudeLog.logCalendar.identifier == .gregorian)
    }

    @Test func cursorStampsNewLinesWithTheInjectedClock() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let main = sb.env.claudeLogsDir.appendingPathComponent("main.log")
        let observed = at(500)
        let cursor = ClaudeLog.Cursor(log: ClaudeLog(logsDir: sb.env.claudeLogsDir), now: { observed })
        try LogFixture.appendLines(main, [(at(0), "fresh")])
        let lines = cursor.poll()
        #expect(lines.map(\.timestamp) == [at(0)])
        #expect(lines.map(\.observedAt) == [observed])
    }

    @Test func linesSinceSpansRotatedFile() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let dir = sb.env.claudeLogsDir
        try LogFixture.appendLines(dir.appendingPathComponent("main1.log"), [(at(0), "old-a"), (at(10), "old-b")])
        try LogFixture.appendLines(dir.appendingPathComponent("main.log"), [(at(20), "new-a")])
        let log = ClaudeLog(logsDir: dir)
        #expect(log.lines(since: at(10.7)).map { $0.text.components(separatedBy: "[info] ").last } == ["old-b", "new-a"])
        // A tail that starts mid-line drops that fragment; one that starts on a line boundary keeps the line.
        #expect(log.read("main.log", tailBytes: 6) == "")
        let whole = try #require(log.read("main.log"))
        #expect(log.read("main.log", tailBytes: whole.utf8.count) == whole)
        #expect(log.read("main.log", tailBytes: 1_000_000) == whole)
        #expect(log.read("main9.log") == nil)
    }

    // MARK: - Tail-first reads (audit A-02)

    /// About `megabytes` MB of ordinary log lines.
    func filler(megabytes: Double) -> String {
        let line = LogFixture.line(at(0), "noise " + String(repeating: "x", count: 150)) + "\n"
        return String(repeating: line, count: Int(megabytes * 1_000_000) / line.utf8.count)
    }

    func observedLog(_ sb: Sandbox) -> (log: ClaudeLog, bytes: ReadCounter) {
        let bytes = ReadCounter()
        var log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        log.onRead = { name, count in for _ in 0..<max(count / 1024, 1) { bytes.record(name) } }
        return (log, bytes)
    }

    @Test func latestIdentityFindsTheSignalInTheTail() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.append(sb.env.mainLog, LogFixture.line(at(0), LogFixture.initLine(.a)) + "\n" + filler(megabytes: 5))
        try LogFixture.appendLines(sb.env.mainLog, [(at(9), LogFixture.cacheKeyLine(.b)), (at(10), "noise")])
        let (log, bytes) = observedLog(sb)
        #expect(log.latestIdentity() == ClaudeLog.IdentitySignal(
            timestamp: at(9), accountUuid: FakeIdentity.b.account, orgUuid: FakeIdentity.b.org, loggedOutAfter: false))
        #expect(log.signedInSinceLastInit())
        // Two tail reads for latestIdentity; signedInSinceLastInit had to fall back to the whole 5 MB once.
        #expect(bytes.count("main.log") < 6 * 1024)
    }

    @Test func latestIdentityReadsOnlyTheTailWhenTheSignalIsThere() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 5))
        try LogFixture.appendLines(sb.env.mainLog, [(at(9), LogFixture.cacheKeyLine(.b))])
        let (log, bytes) = observedLog(sb)
        #expect(log.latestIdentity()?.accountUuid == FakeIdentity.b.account)
        #expect(bytes.count("main.log") <= ClaudeLog.tailBytes / 1024)
    }

    @Test func latestIdentityFallsBackToTheWholeFileWhenTheTailHasNone() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.mainLog, [(at(1), LogFixture.cacheKeyLine(.a))])
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 1))
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        #expect(log.latestIdentity() == ClaudeLog.IdentitySignal(
            timestamp: at(1), accountUuid: FakeIdentity.a.account, orgUuid: FakeIdentity.a.org, loggedOutAfter: false))
        #expect(!log.signedInSinceLastInit())
    }

    @Test func aLogoutAfterTheSignalIsSeenInTheTail() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 1))
        try LogFixture.appendLines(sb.env.mainLog, [(at(1), LogFixture.initLine(.a)), (at(2), "Navigated to /logout")])
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        #expect(log.latestIdentity()?.loggedOutAfter == true)
        #expect(!log.signedInSinceLastInit())
    }

    @Test func aLogoutInTheTailCountsWhenTheSignalIsOnlyInTheHead() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.mainLog, [(at(1), LogFixture.initLine(.a))])
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 1))
        try LogFixture.appendLines(sb.env.mainLog, [(at(2), "Navigated to /logout")])
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        let signal = try #require(log.latestIdentity())
        #expect(signal.accountUuid == FakeIdentity.a.account)
        #expect(signal.loggedOutAfter)
        #expect(!log.signedInSinceLastInit())
    }

    @Test func aLogoutInANewerFileStillCountsForASignalInARotatedOne() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.claudeLogsDir.appendingPathComponent("main1.log"), [(at(1), LogFixture.initLine(.a))])
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 1))
        try LogFixture.appendLines(sb.env.mainLog, [(at(2), "Navigated to /logout")])
        try LogFixture.append(sb.env.mainLog, filler(megabytes: 1))
        #expect(ClaudeLog(logsDir: sb.env.claudeLogsDir).latestIdentity()?.loggedOutAfter == true)
    }

    @Test func signalsAreNotRecomputedWhileTheFileIsUnchanged() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.mainLog, [(at(1), LogFixture.initLine(.a))])
        let (log, bytes) = observedLog(sb)
        let signals = ClaudeLogSignals(log: log)
        #expect(signals.current().latestIdentity?.accountUuid == FakeIdentity.a.account)
        #expect(!signals.current().nativeMultiAccount)
        let afterFirst = bytes.count("main.log")
        #expect(afterFirst > 0)
        #expect(signals.current().latestIdentity?.accountUuid == FakeIdentity.a.account)
        #expect(bytes.count("main.log") == afterFirst)

        try LogFixture.appendLines(sb.env.mainLog, [(at(2), "GET " + ClaudeLog.multiAccountMarker), (at(3), LogFixture.cacheKeyLine(.b))])
        let changed = signals.current()
        #expect(changed.latestIdentity?.accountUuid == FakeIdentity.b.account)
        #expect(changed.nativeMultiAccount)
        #expect(bytes.count("main.log") > afterFirst)
    }

    @Test func theMultiAccountMarkerIsFoundAcrossAppendsAndResetOnRotation() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let signals = ClaudeLogSignals(log: ClaudeLog(logsDir: sb.env.claudeLogsDir))
        #expect(!signals.current().nativeMultiAccount) // no log at all
        // The marker is split across two appends.
        let marker = ClaudeLog.multiAccountMarker
        try LogFixture.append(sb.env.mainLog, LogFixture.line(at(1), "GET " + String(marker.prefix(6))))
        #expect(!signals.current().nativeMultiAccount)
        try LogFixture.append(sb.env.mainLog, String(marker.dropFirst(6)) + "\n")
        #expect(signals.current().nativeMultiAccount)
        try LogFixture.appendLines(sb.env.mainLog, [(at(2), "noise")])
        #expect(signals.current().nativeMultiAccount) // stays true for this file
        // Rotation: a new main.log without the marker.
        try FileManager.default.moveItem(at: sb.env.mainLog, to: sb.env.claudeLogsDir.appendingPathComponent("main1.log"))
        try LogFixture.appendLines(sb.env.mainLog, [(at(3), "fresh file")])
        #expect(!signals.current().nativeMultiAccount)
    }

    @Test func latestIdentityPrefersNewestSignal() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let main = sb.env.mainLog
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        #expect(log.latestIdentity() == nil)
        try LogFixture.appendLines(sb.env.claudeLogsDir.appendingPathComponent("main1.log"), [(at(0), LogFixture.initLine(.a))])
        try LogFixture.appendLines(main, [(at(1), "noise")])
        // Falls back to the rotated file.
        #expect(log.latestIdentity() == ClaudeLog.IdentitySignal(
            timestamp: at(0), accountUuid: FakeIdentity.a.account, orgUuid: FakeIdentity.a.org, loggedOutAfter: false))
        // LocalAgentModeSessionManager lines are not identity evidence.
        try LogFixture.appendLines(main, [(at(2), LogFixture.agentInitLine(.c))])
        #expect(log.latestIdentity()?.accountUuid == FakeIdentity.a.account)
        // Token-cache lookups count, newest wins.
        try LogFixture.appendLines(main, [(at(3), LogFixture.cacheKeyLine(.b))])
        #expect(log.latestIdentity()?.accountUuid == FakeIdentity.b.account)
        #expect(log.latestIdentity()?.orgUuid == FakeIdentity.b.org)
    }

    @Test(arguments: [LogFixture.logout, LogFixture.loginTransition, "[auth] User is logged out"])
    func logoutAfterSignalIsFlagged(marker: String) throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.mainLog, [(at(0), LogFixture.initLine(.a)), (at(5), marker)])
        let signal = try #require(ClaudeLog(logsDir: sb.env.claudeLogsDir).latestIdentity())
        #expect(signal.loggedOutAfter)
        // A fresh sign-in afterwards clears it.
        try LogFixture.appendLines(sb.env.mainLog, [(at(9), LogFixture.initLine(.b))])
        #expect(ClaudeLog(logsDir: sb.env.claudeLogsDir).latestIdentity()?.loggedOutAfter == false)
    }

    @Test func parseInitRejectsMalformedIds() {
        let ok = ClaudeLog.Line(timestamp: at(0), text: LogFixture.line(at(0), LogFixture.initLine(.a)))
        let pair = ClaudeLog.parseInit(ok)
        #expect(pair?.account == FakeIdentity.a.account)
        #expect(pair?.org == FakeIdentity.a.org)
        let short = ClaudeLog.Line(timestamp: at(0), text: "[LocalSessionManager] Initialization succeeded — accountId=abc, orgId=def")
        #expect(ClaudeLog.parseInit(short) == nil)
        let noOrg = ClaudeLog.Line(timestamp: at(0), text: "[LocalSessionManager] Initialization succeeded — accountId=\(FakeIdentity.a.account)")
        #expect(ClaudeLog.parseInit(noOrg) == nil)
        // A plain hyphen instead of the em dash is a different line.
        let hyphen = ClaudeLog.Line(timestamp: at(0), text: LogFixture.initLine(.a).replacingOccurrences(of: "—", with: "-"))
        #expect(ClaudeLog.parseInit(hyphen) == nil)
        let agent = ClaudeLog.Line(timestamp: at(0), text: LogFixture.agentInitLine(.a))
        #expect(ClaudeLog.parseInit(agent) == nil)
    }

    @Test func parsersAcceptOnlyCanonicalUUIDs() {
        func line(_ text: String) -> ClaudeLog.Line { ClaudeLog.Line(timestamp: at(0), text: text) }
        let notHex = "zzzzzzzz-1111-4111-8111-zzzzzzzzzzzz"
        let dashes = String(repeating: "-", count: 36)
        #expect(ClaudeLog.parseInit(line("[LocalSessionManager] Initialization succeeded — accountId=\(notHex), orgId=\(FakeIdentity.a.org)")) == nil)
        #expect(ClaudeLog.parseInit(line("[LocalSessionManager] Initialization succeeded — accountId=\(FakeIdentity.a.account), orgId=\(dashes)")) == nil)
        // Upper-case UUIDs are canonicalised to the lower-case form used everywhere else.
        let upper = ClaudeLog.parseInit(line(LogFixture.initLine(FakeIdentity(
            account: FakeIdentity.a.account.uppercased(), org: FakeIdentity.a.org.uppercased(), email: "", name: ""))))
        #expect(upper?.account == FakeIdentity.a.account && upper?.org == FakeIdentity.a.org)
        // cacheKey lookups: the regex admits 36 dashes, the UUID check does not.
        #expect(ClaudeLog.parseCacheKey(line(LogFixture.cacheKeyLine(.b)))?.account == FakeIdentity.b.account)
        #expect(ClaudeLog.parseCacheKey(line(LogFixture.cacheKeyLine(.b)))?.org == FakeIdentity.b.org)
        let forged = "[oauth-v2] lookup cacheKey=acct:\(dashes)|\(FakeIdentity.clientUuid):\(FakeIdentity.a.org):https://api"
        #expect(ClaudeLog.parseCacheKey(line(forged)) == nil)
        let forgedOrg = "[oauth-v2] lookup cacheKey=acct:\(FakeIdentity.a.account)|\(FakeIdentity.clientUuid):\(dashes):https://api"
        #expect(ClaudeLog.parseCacheKey(line(forgedOrg)) == nil)
        #expect(ClaudeLog.isUUID(FakeIdentity.a.account))
        for bad in [notHex, dashes, "", FakeIdentity.a.account + "a", String(FakeIdentity.a.account.dropLast()),
                    FakeIdentity.a.account.replacingOccurrences(of: "-", with: "")] {
            #expect(!ClaudeLog.isUUID(bad), "\(bad)")
        }
    }

    @Test func signedInSinceLastInitIsAnchoredOnTheLastInitialization() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        #expect(!log.signedInSinceLastInit()) // no log at all
        try LogFixture.appendLines(sb.env.mainLog, [(at(0), "noise"), (at(1), LogFixture.cacheKeyLine(.a))])
        #expect(!log.signedInSinceLastInit()) // token lookups alone are not sign-in evidence
        try LogFixture.appendLines(sb.env.mainLog, [(at(2), LogFixture.agentInitLine(.a))])
        #expect(!log.signedInSinceLastInit()) // agent-mode initialisation does not count either
        try LogFixture.appendLines(sb.env.mainLog, [(at(3), LogFixture.initLine(.a)), (at(4), LogFixture.cacheKeyLine(.a))])
        #expect(log.signedInSinceLastInit())
        try LogFixture.appendLines(sb.env.mainLog, [(at(5), LogFixture.logout)])
        #expect(!log.signedInSinceLastInit())
        try LogFixture.appendLines(sb.env.mainLog, [(at(6), LogFixture.initLine(.b))])
        #expect(log.signedInSinceLastInit())
    }

    /// The reviewer's sequence: a token-cache lookup after a logout must not count as being signed in again.
    @Test func cacheKeyLookupAfterLogoutDoesNotRestoreSignIn() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try LogFixture.appendLines(sb.env.mainLog, [
            (at(0), LogFixture.initLine(.a)), (at(5), LogFixture.loginTransition), (at(9), LogFixture.cacheKeyLine(.a)),
        ])
        let log = ClaudeLog(logsDir: sb.env.claudeLogsDir)
        #expect(!log.signedInSinceLastInit())
        // latestIdentity (used for "who was it") still names A from the lookup, without a logout after it.
        #expect(log.latestIdentity()?.accountUuid == FakeIdentity.a.account)
        #expect(log.latestIdentity()?.loggedOutAfter == false)
    }

    @Test func signedInSinceLastInitScansRotatedFilesNewestFirst() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let dir = sb.env.claudeLogsDir
        let log = ClaudeLog(logsDir: dir)
        try LogFixture.appendLines(dir.appendingPathComponent("main1.log"), [(at(0), LogFixture.initLine(.a))])
        try LogFixture.appendLines(sb.env.mainLog, [(at(10), "noise")])
        #expect(log.signedInSinceLastInit())
        try LogFixture.appendLines(sb.env.mainLog, [(at(11), "[auth] User is logged out")])
        #expect(!log.signedInSinceLastInit()) // logout in main.log follows the init in main1.log
    }

    @Test func cleanQuitMarkersIncludeClaudesSpellingAndItsFix() {
        #expect(ClaudeLog.cleanQuitMarkers.first == ClaudeLog.cleanQuitMarker)
        #expect(ClaudeLog.cleanQuitMarkers.contains("Successfully ran all onQuitCleanup handlers"))
        #expect(ClaudeLog.cleanQuitMarkers.contains("marking readyForQuit"))
        #expect(ClaudeLog.cleanQuitMarkers.contains("onQuitCleanup handlers done"))
        #expect(LogFixture.cleanQuit.contains(ClaudeLog.cleanQuitMarker))
        // The quit-start line must not look like a finished cleanup.
        #expect(!ClaudeLog.cleanQuitMarkers.contains { LogFixture.quitCleanupStart.contains($0) })
    }

    // MARK: Cursor

    @Test func cursorStartsAtEndAndReadsOnlyCompleteLines() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let main = sb.env.mainLog
        try LogFixture.appendLines(main, [(at(0), "before cursor")])
        let cursor = ClaudeLog.Cursor(log: ClaudeLog(logsDir: sb.env.claudeLogsDir))
        #expect(cursor.poll().isEmpty)
        try LogFixture.append(main, LogFixture.line(at(1), "partial"))
        #expect(cursor.poll().isEmpty)
        try LogFixture.append(main, " line done\n  continuation\n")
        let lines = cursor.poll()
        #expect(lines.map(\.text) == [LogFixture.line(at(1), "partial line done"), "  continuation"])
        #expect(lines.map(\.timestamp) == [at(1), at(1)])
        // A continuation in a later poll inherits the last timestamp seen.
        try LogFixture.append(main, "  more continuation\n")
        #expect(cursor.poll().map(\.timestamp) == [at(1)])
        #expect(cursor.collected.count == 3)
    }

    @Test func cursorSurvivesRotation() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let dir = sb.env.claudeLogsDir
        let main = dir.appendingPathComponent("main.log")
        try LogFixture.appendLines(main, [(at(0), "old")])
        let cursor = ClaudeLog.Cursor(log: ClaudeLog(logsDir: dir))
        try LogFixture.appendLines(main, [(at(1), "tail of old file")])
        // Winston rotates: main.log → main1.log, then a fresh main.log.
        try FileManager.default.moveItem(at: main, to: dir.appendingPathComponent("main1.log"))
        try LogFixture.appendLines(main, [(at(2), "[info] Starting app {"), (at(3), "after rotation")])
        let texts = cursor.poll().map { $0.text.components(separatedBy: "[info] ").last! }
        #expect(texts == ["tail of old file", "Starting app {", "after rotation"])
        try LogFixture.appendLines(main, [(at(4), "next")])
        #expect(cursor.poll().count == 1)
        #expect(cursor.collected.count == 4)
    }

    @Test func cursorHandlesMissingThenCreatedLog() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let cursor = ClaudeLog.Cursor(log: ClaudeLog(logsDir: sb.env.claudeLogsDir))
        #expect(cursor.poll().isEmpty)
        try LogFixture.appendLines(sb.env.mainLog, [(at(0), "first")])
        #expect(cursor.poll().count == 1)
        try FileManager.default.removeItem(at: sb.env.mainLog)
        #expect(cursor.poll().isEmpty)
        try LogFixture.appendLines(sb.env.mainLog, [(at(1), "again")])
        #expect(cursor.poll().count == 1)
    }
}

@Suite("LaunchVerdict (design D5)")
struct LaunchVerdictTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let target = FakeIdentity.b

    func lines(_ items: [(TimeInterval, String)]) -> [ClaudeLog.Line] {
        items.map { ClaudeLog.Line(timestamp: Self.t0.addingTimeInterval($0.0), text: LogFixture.line(Self.t0.addingTimeInterval($0.0), $0.1)) }
    }

    func verdict(_ items: [(TimeInterval, String)], now: TimeInterval) -> LaunchVerdict {
        LaunchVerdict.evaluate(lines: lines(items), targetAccount: target.account, targetOrg: target.org,
                               now: Self.t0.addingTimeInterval(now), settle: 20)
    }

    @Test func pendingUntilStartAndInitAndSettle() {
        #expect(verdict([], now: 100) == .pending)
        #expect(verdict([(0, LogFixture.initLine(target))], now: 100) == .pending) // no Starting app yet
        #expect(verdict([(0, LogFixture.startText)], now: 100) == .pending)
        let ok: [(TimeInterval, String)] = [(0, LogFixture.startText), (2, LogFixture.initLine(target))]
        #expect(verdict(ok, now: 21.9) == .pending)
        #expect(verdict(ok, now: 22) == .success(initAt: Self.t0.addingTimeInterval(2)))
    }

    /// The settle wait must not depend on what calendar year the log line claims (audit A-01).
    func skewed(_ skew: TimeInterval) -> [ClaudeLog.Line] {
        let wrong = Self.t0.addingTimeInterval(skew)
        return [
            ClaudeLog.Line(timestamp: wrong, text: LogFixture.line(wrong, LogFixture.startText), observedAt: Self.t0),
            ClaudeLog.Line(timestamp: wrong, text: LogFixture.line(wrong, LogFixture.initLine(target)), observedAt: Self.t0),
        ]
    }

    func verdict(skew: TimeInterval, now: TimeInterval) -> LaunchVerdict {
        LaunchVerdict.evaluate(lines: skewed(skew), targetAccount: target.account, targetOrg: target.org,
                               now: Self.t0.addingTimeInterval(now), settle: 20)
    }

    @Test func settleCountsFromObservationNotFromTheLogTimestamp() {
        let twoThousandYears: TimeInterval = 2000 * 365.25 * 86400
        #expect(verdict(skew: twoThousandYears, now: 5) == .pending)
        #expect(verdict(skew: twoThousandYears, now: 25) == .success(initAt: Self.t0.addingTimeInterval(twoThousandYears)))
    }

    @Test func aTimestampFarInThePastStillWaitsForSettle() {
        let fiveHundredYearsAgo: TimeInterval = -500 * 365.25 * 86400
        #expect(verdict(skew: fiveHundredYearsAgo, now: 5) == .pending)
        #expect(verdict(skew: fiveHundredYearsAgo, now: 25) == .success(initAt: Self.t0.addingTimeInterval(fiveHundredYearsAgo)))
    }

    @Test func wrongAccountOrOrgFails() {
        for other in [FakeIdentity.a, FakeIdentity(account: target.account, org: FakeIdentity.a.org, email: "", name: "")] {
            let v = verdict([(0, LogFixture.startText), (1, LogFixture.initLine(other))], now: 100)
            guard case .failure(_, let relogin) = v else { Issue.record("expected failure, got \(v)"); continue }
            #expect(!relogin)
        }
    }

    @Test func transientMismatchBeforeMatchStillFails() {
        let v = verdict([(0, LogFixture.startText), (1, LogFixture.initLine(.a)), (2, LogFixture.initLine(target))], now: 100)
        guard case .failure(let reason, false) = v else { Issue.record("expected failure, got \(v)"); return }
        #expect(reason.contains("aaaaaaaa"))
        #expect(!reason.contains(FakeIdentity.a.account)) // only a prefix is reported
    }

    @Test func agentModeLinesAreIgnored() {
        let v = verdict([(0, LogFixture.startText), (1, LogFixture.agentInitLine(.a)), (2, LogFixture.initLine(target))], now: 30)
        #expect(v == .success(initAt: Self.t0.addingTimeInterval(2)))
    }

    @Test func linesBeforeStartAreIgnored() {
        let v = verdict([(0, LogFixture.initLine(.a)), (0, LogFixture.logout), (1, LogFixture.startText),
                         (2, LogFixture.initLine(target))], now: 30)
        #expect(v == .success(initAt: Self.t0.addingTimeInterval(2)))
    }

    @Test(arguments: ClaudeLog.failurePatterns)
    func failurePatternInSettleWindowFails(pattern: String) {
        let v = verdict([(0, LogFixture.startText), (2, LogFixture.initLine(target)), (10, "[auth] something \(pattern) here")],
                        now: 15)
        guard case .failure(let reason, let relogin) = v else { Issue.record("expected failure for \(pattern)"); return }
        #expect(reason.contains(pattern))
        #expect(relogin == ClaudeLog.reloginPatterns.contains(pattern))
    }

    @Test func reloginFlagOnlyForStaleSignIn() {
        let stale = verdict([(0, LogFixture.startText), (1, "[LocalSessionManager] Cannot initialize sessions: no sessionKey cookie")], now: 5)
        #expect(stale == .failure(reason: L10n.t(.reasonLogPattern, "Cannot initialize sessions"), needsRelogin: true))
        let other = verdict([(0, LogFixture.startText), (1, "[oauth] token names a different account; not using it")], now: 5)
        #expect(other == .failure(reason: L10n.t(.reasonLogPattern, "names a different account"), needsRelogin: false))
    }

    @Test func benignIdentityMismatchDropIsNotAFailure() {
        // Every cold start logs this for empty custom groups; it must not fail a switch.
        let v = verdict([(0, LogFixture.startText), (1, "[custom-groups] dropped (identity mismatch) group=empty"),
                         (2, LogFixture.initLine(target))], now: 30)
        #expect(v == .success(initAt: Self.t0.addingTimeInterval(2)))
    }
}
