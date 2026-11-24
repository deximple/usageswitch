import Foundation
import Testing
@testable import SwitcherCore

@Suite("Claude structured limits")
struct ClaudeUsageLimitsTests {
    /// 2026-11-13T04:00:00Z — the hour the 2.1.330 fixture's resets sit a fraction of a second before.
    static let hour = Date(timeIntervalSince1970: 1_794_542_400)
    static let justBefore = "2026-11-13T03:59:59.632640+00:00"
    static let justAfter = "2026-11-13T04:00:00.124695+00:00"

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// One row of `limits[]`. `scope` is the model's display name; `resetsAt` nil sends JSON null.
    static func limit(kind: String = "weekly_all", group: String = "weekly", percent: Any = 51,
                      resetsAt: String? = justBefore, scope: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["kind": kind, "group": group, "percent": percent,
                                  "severity": "normal", "is_active": false]
        row["resets_at"] = resetsAt ?? NSNull()
        row["scope"] = scope.map { ["model": ["display_name": $0], "surface": NSNull()] as [String: Any] } ?? NSNull()
        return row
    }

    static func result(_ panel: String) -> String {
        line(["type": "result", "subtype": "success", "is_error": false, "num_turns": 0,
              "total_cost_usd": 0, "result": panel])
    }

    /// The stream with `usage_report` as given; nil leaves it off the assistant line, as an older CLI does.
    static func stream(report: [String: Any]?, panel: String = "") -> [String] {
        var assistant: [String: Any] = ["type": "assistant", "message": ["model": "<synthetic>"]]
        if let report { assistant["usage_report"] = report }
        return [#"{"type":"system","subtype":"init"}"#, line(assistant), result(panel)]
    }

    static func stream(limits: Any, panel: String = "") -> [String] {
        stream(report: ["session": [String: Any](), "rate_limits": ["limits": limits]], panel: panel)
    }

    static func reading(_ rows: [[String: Any]]) -> ClaudeUsageLimits.Reading {
        ClaudeUsageLimits.reading(in: stream(limits: rows))
    }

    /// Every row read, none left out.
    static func all(_ windows: [UsageWindow]) -> ClaudeUsageLimits.Reading {
        .windows(windows, complete: true)
    }

    // MARK: - Reading the rows

    @Test("2.1.330 fixture: both weekly rows, each reset on the whole minute")
    func liveFixture() {
        let lines = ClaudeUsageTests.lines(UsageFixture.claude_2_1_330)
        #expect(ClaudeUsageLimits.reading(in: lines) == Self.all([
            UsageWindow(scope: nil, durationMinutes: 10080, usedPercent: 42, resetsAt: Self.hour),
            UsageWindow(scope: "Fable", durationMinutes: 10080, usedPercent: 7, resetsAt: Self.hour),
        ]))
    }

    @Test("a reset the server sends a moment before or after the minute is the same moment")
    func resetIsTheSameFromRunToRun() {
        let before = Self.reading([Self.limit(resetsAt: Self.justBefore)])
        let after = Self.reading([Self.limit(resetsAt: Self.justAfter)])
        #expect(before == Self.all([UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour)]))
        #expect(after == before)
    }

    @Test("a row is classified by its kind alone")
    func classification() {
        #expect(Self.reading([Self.limit(kind: "session", group: "session", percent: 40)])
            == Self.all([UsageWindow(durationMinutes: 300, usedPercent: 40, resetsAt: Self.hour)]))
        // The group is a heading, not a kind: a weekly heading says nothing about which limit it is.
        #expect(Self.reading([Self.limit(kind: "weekly_all", group: "another heading")])
            == Self.all([UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour)]))
        var noKind = Self.limit()
        noKind["kind"] = nil
        #expect(Self.reading([noKind]) == .unreadable)
        noKind["kind"] = 7
        #expect(Self.reading([noKind]) == .unreadable)
    }

    @Test("a row of a kind this build doesn't know is left out and said to be")
    func unknownKinds() {
        let weekly = UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour)
        // Even under the weekly heading and with no scope, it is not the plan-wide weekly limit.
        #expect(Self.reading([Self.limit(), Self.limit(kind: "weekly_credits", percent: 99)])
            == .windows([weekly], complete: false))
        // Its other fields are not this build's to judge.
        #expect(Self.reading([Self.limit(), Self.limit(kind: "monthly_all", group: "monthly", percent: "a lot", resetsAt: "soon")])
            == .windows([weekly], complete: false))
        // Nothing but unknown kinds is nothing this build can use.
        #expect(Self.reading([Self.limit(kind: "monthly_all", group: "monthly")]) == .unreadable)
    }

    @Test("a scope names its model, else its surface; a scoped row without a name is unreadable")
    func scopes() {
        var surface = Self.limit(kind: "weekly_scoped")
        surface["scope"] = ["model": NSNull(), "surface": ["display_name": "Claude Design"]] as [String: Any]
        #expect(Self.reading([surface]) == Self.all([
            UsageWindow(scope: "Claude Design", durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour)]))
        // No scope key at all is the same as null.
        var bare = Self.limit()
        bare["scope"] = nil
        #expect(Self.reading([bare]) == Self.reading([Self.limit()]))
        #expect(Self.reading([Self.limit(kind: "weekly_scoped")]) == .unreadable)
        for broken: Any in ["Fable", ["model": "Fable"], ["model": ["display_name": 3]], ["model": ["display_name": ""]],
                            ["model": ["display_name": String(repeating: "x", count: 129)]]] {
            var row = Self.limit(kind: "weekly_scoped")
            row["scope"] = broken
            #expect(Self.reading([row]) == .unreadable)
        }
    }

    @Test("a null reset is a window without one; a reset that doesn't parse is unreadable")
    func resets() {
        #expect(Self.reading([Self.limit(resetsAt: nil)])
            == Self.all([UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: nil)]))
        #expect(Self.reading([Self.limit(resetsAt: "Nov 13 at 12:59pm")]) == .unreadable)
        var numeric = Self.limit()
        numeric["resets_at"] = 1_794_542_400
        #expect(Self.reading([numeric]) == .unreadable)
    }

    @Test("a percent outside 0…100 or of another type is unreadable", arguments: [-1, 100.5, 250] as [Double])
    func percentRange(_ percent: Double) {
        #expect(Self.reading([Self.limit(percent: percent)]) == .unreadable)
    }

    @Test("percent keeps its fraction; a missing or boolean percent is unreadable")
    func percentShape() {
        #expect(Self.reading([Self.limit(percent: 12.5)])
            == Self.all([UsageWindow(durationMinutes: 10080, usedPercent: 12.5, resetsAt: Self.hour)]))
        #expect(Self.reading([Self.limit(percent: true)]) == .unreadable)
        var missing = Self.limit()
        missing["percent"] = nil
        #expect(Self.reading([missing]) == .unreadable)
    }

    @Test("one row that can't be read spoils the whole report, so a capped limit is never dropped")
    func allOrNothing() {
        #expect(Self.reading([Self.limit(), Self.limit(kind: "weekly_scoped", percent: 100, resetsAt: "soon", scope: "Fable")])
            == .unreadable)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(limits: [Self.limit(), "weekly"] as [Any])) == .unreadable)
    }

    @Test("two rows for the same window are unreadable: nothing says which one counts")
    func duplicates() {
        #expect(Self.reading([Self.limit(), Self.limit(percent: 9)]) == .unreadable)
        // A name is matched to the panel without regard to case, so two spellings are one limit.
        #expect(Self.reading([Self.limit(kind: "weekly_scoped", scope: "Fable"),
                              Self.limit(kind: "weekly_scoped", percent: 9, scope: "FABLE")]) == .unreadable)
        // The same length under different scopes, or the same scope at different lengths, is fine.
        let rows = [Self.limit(kind: "session", group: "session"), Self.limit(),
                    Self.limit(kind: "weekly_scoped", scope: "Fable"), Self.limit(kind: "weekly_scoped", scope: "Sonnet")]
        guard case .windows(let windows, complete: true) = Self.reading(rows) else { Issue.record("should read"); return }
        #expect(windows.map(\.scope) == [nil, nil, "Fable", "Sonnet"])
        #expect(windows.map(\.kind) == [.session, .weekly, .weekly, .weekly])
    }

    @Test("no report, no rate limits or no rows is absent, not unreadable")
    func absent() {
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: nil)) == .absent)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: ["session": [String: Any]()])) == .absent)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: ["rate_limits": NSNull()])) == .absent)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: ["rate_limits": ["limits": NSNull()]])) == .absent)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: ["rate_limits": ["extra_usage": NSNull()]])) == .absent)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(limits: [Any]())) == .absent)
        #expect(ClaudeUsageLimits.reading(in: []) == .absent)
        #expect(ClaudeUsageLimits.reading(in: ClaudeUsageTests.lines(UsageFixture.claude_2_1_317)) == .absent)
    }

    @Test("rate limits or rows of another type are unreadable")
    func wrongContainers() {
        #expect(ClaudeUsageLimits.reading(in: Self.stream(report: ["rate_limits": "none"])) == .unreadable)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(limits: ["weekly": Self.limit()])) == .unreadable)
        #expect(ClaudeUsageLimits.reading(in: Self.stream(limits: "none")) == .unreadable)
    }

    @Test("only the answer's own assistant line is read")
    func whichLine() {
        let report: [String: Any] = ["rate_limits": ["limits": [Self.limit()]]]
        let onInit = Self.line(["type": "system", "subtype": "init", "usage_report": report])
        let onResult = Self.line(["type": "result", "subtype": "success", "is_error": false, "usage_report": report])
        let assistant = #"{"type":"assistant","message":{"model":"<synthetic>"}}"#
        #expect(ClaudeUsageLimits.reading(in: [onInit, assistant, onResult]) == .absent)
        let realTurn = Self.line(["type": "assistant", "message": ["model": "claude-opus-5-5"], "usage_report": report])
        #expect(ClaudeUsageLimits.reading(in: [realTurn]) == .absent)
    }

    // MARK: - The collector

    let readAt = Date(timeIntervalSince1970: 1_794_000_000)

    private func state(_ lines: [String]) throws -> (state: UsageState, windows: [UsageWindow]) {
        let suite = ClaudeUsageTests()
        let home = try suite.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: lines, outcome: .stopped) }
        let usage = suite.collector(home: home, binaryPaths: [try suite.makeBinary(home: home)], runner: runner).collect()
        return (usage.state, usage.windows)
    }

    static let panel = "Current week (all models): 51% used · resets Nov 13 at 12:59pm (Asia/Seoul)"

    @Test("the collector takes each limit's numbers from its structured row")
    func collectorPrefersTheReport() throws {
        let read = try state(ClaudeUsageTests.lines(UsageFixture.claude_2_1_330))
        #expect(read.state == .ok)
        #expect(read.windows.map(\.scope) == [nil, "Fable"])
        #expect(read.windows.map(\.usedPercent) == [42, 7])
        // The panel says 12:59pm; the report's 03:59:59.63Z is the hour.
        #expect(read.windows.map(\.resetsAt) == [Self.hour, Self.hour])
    }

    @Test("two runs whose panels print 12:59pm and 1pm record one reset, so the run-out forecast holds")
    func paceSurvivesTheWobble() throws {
        let first = try state(Self.stream(limits: [Self.limit(percent: 51, resetsAt: Self.justBefore)],
                                          panel: "Current week (all models): 51% used · resets Nov 13 at 12:59pm (Asia/Seoul)"))
        let second = try state(Self.stream(limits: [Self.limit(percent: 57, resetsAt: Self.justAfter)],
                                           panel: "Current week (all models): 57% used · resets Nov 13 at 1pm (Asia/Seoul)"))
        let (earlier, later) = (try #require(first.windows.first), try #require(second.windows.first))
        #expect(earlier.resetsAt == later.resetsAt)
        let sample = UsagePace.Sample(at: readAt, usedPercent: earlier.usedPercent, identityKey: "login",
                                      resetsAt: earlier.resetsAt, durationMinutes: earlier.durationMinutes)
        let pace = UsagePace.reading(later, previous: sample, now: readAt.addingTimeInterval(300), identityKey: "login")
        guard case .depleting = pace else { Issue.record("the two reads should join, got \(pace)"); return }
    }

    @Test("without usable rows the collector falls back to the panel text")
    func collectorFallsBack() throws {
        let fromText = try state(Self.stream(report: nil, panel: Self.panel))
        #expect(fromText.state == .ok)
        #expect(fromText.windows.map(\.usedPercent) == [51])
        let changedRows = try state(Self.stream(limits: [Self.limit(kind: "all", group: "all", percent: 9)], panel: Self.panel))
        #expect(changedRows.state == .ok)
        #expect(changedRows.windows.map(\.usedPercent) == [51])
        let noMeters = try state(Self.stream(limits: [Any](), panel: Self.panel))
        #expect(noMeters.windows.map(\.usedPercent) == [51])
    }

    @Test("the panel says which limits there are and what they are called")
    func panelDecidesTheLimits() throws {
        let panel = """
            Current session: 40% used · resets 7:40pm (Asia/Seoul)
            Current week (all models): 51% used · resets Nov 13 at 12:59pm (Asia/Seoul)
            Current week (Sonnet only): 8% used · resets Nov 13 at 12:59pm (Asia/Seoul)
            Current week (Fable): 11% used · resets Nov 13 at 12:59pm (Asia/Seoul)
            """
        // No session row; the Sonnet row names the model alone and the Fable row is in another
        // case; the last row is one the panel doesn't print.
        let rows = [Self.limit(percent: 51.5), Self.limit(kind: "weekly_scoped", percent: 9.5, scope: "Sonnet"),
                    Self.limit(kind: "weekly_scoped", percent: 11.25, scope: "FABLE"),
                    Self.limit(kind: "weekly_scoped", percent: 3, scope: "Opus")]
        let read = try state(Self.stream(limits: rows, panel: panel))
        #expect(read.state == .ok)
        #expect(read.windows.map(\.scope) == [nil, nil, "Sonnet only", "Fable"])
        #expect(read.windows.map(\.kind) == [.session, .weekly, .weekly, .weekly])
        // Each limit with a row takes the row's numbers; the session line keeps the panel's.
        #expect(read.windows.map(\.usedPercent) == [40, 51.5, 9.5, 11.25])
        #expect(read.windows.dropFirst().map(\.resetsAt) == [Self.hour, Self.hour, Self.hour])
        let panelOnly = try state(Self.stream(report: nil, panel: panel))
        #expect(read.windows[0] == panelOnly.windows[0])
    }

    @Test("a row of an unknown kind never stands in for a limit the panel prints")
    func unknownKindNeverStandsIn() throws {
        // No weekly_all row: the only plan-wide weekly row is of a kind this build doesn't know.
        let rows = [Self.limit(kind: "weekly_credits", percent: 3), Self.limit(kind: "weekly_scoped", percent: 12, scope: "Fable")]
        let panel = Self.panel + "\nCurrent week (Fable): 11% used · resets Nov 13 at 12:59pm (Asia/Seoul)"
        let read = try state(Self.stream(limits: rows, panel: panel))
        #expect(read.state == .ok)
        #expect(read.windows == [
            UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour.addingTimeInterval(-60)),
            UsageWindow(scope: "Fable", durationMinutes: 10080, usedPercent: 12, resetsAt: Self.hour),
        ])
    }

    @Test("a row without a reset keeps the one the panel prints")
    func rowWithoutAReset() throws {
        let read = try state(Self.stream(limits: [Self.limit(percent: 52, resetsAt: nil)], panel: Self.panel))
        #expect(read.windows == [UsageWindow(durationMinutes: 10080, usedPercent: 52,
                                             resetsAt: Self.hour.addingTimeInterval(-60))])
    }

    @Test("rows alone are read only when the panel prints no limit and every row is known")
    func collectorWithoutThePanel() throws {
        let read = try state(Self.stream(limits: [Self.limit()], panel: "Nothing to report here"))
        #expect(read.state == .ok)
        #expect(read.windows == [UsageWindow(durationMinutes: 10080, usedPercent: 51, resetsAt: Self.hour)])
        // A row left out may be the limit that is used up.
        let incomplete = try state(Self.stream(limits: [Self.limit(), Self.limit(kind: "monthly_all", percent: 100)],
                                               panel: "Nothing to report here"))
        #expect(incomplete.state == .unavailable(.schemaChanged))
        #expect(incomplete.windows.isEmpty)
        // A Current line the parser can't read is a limit nothing vouches for, whatever the rows say.
        let broken = try state(Self.stream(limits: [Self.limit()], panel: "Current week: broken shape"))
        #expect(broken.state == .unavailable(.schemaChanged))
        #expect(broken.windows.isEmpty)
    }

    @Test("rows this build can't read are a changed format, never 'not reporting'")
    func unreadableRowsAreNotSilence() throws {
        let rows = [Self.limit(kind: "all", group: "all")]
        #expect(try state(Self.stream(limits: rows, panel: "Nothing to report here")).state == .unavailable(.schemaChanged))
        // Nothing in the report and nothing in the panel is still an account that reports nothing.
        #expect(try state(Self.stream(report: nil, panel: "Nothing to report here")).state == .notReporting)
        #expect(try state(Self.stream(limits: [Any](), panel: "Nothing to report here")).state == .notReporting)
    }

    @Test("a run that did more than answer is refused whatever its report says")
    func refusalsComeFirst() throws {
        let lines = Self.stream(limits: [Self.limit()], panel: Self.panel)
        #expect(try state([#"{"type":"system","subtype":"hook_started"}"#] + lines).state == .unavailable(.refused))
        let cost = Self.line(["type": "result", "subtype": "success", "is_error": false, "num_turns": 1,
                              "total_cost_usd": 0.01, "result": Self.panel])
        #expect(try state(Array(lines.dropLast()) + [cost]).state == .unavailable(.refused))
    }
}
