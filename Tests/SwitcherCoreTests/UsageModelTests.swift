import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage model")
struct UsageModelTests {
    func window(_ minutes: Int?, used: Double = 50, scope: String? = nil, resetsAt: Date? = nil) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used, resetsAt: resetsAt)
    }

    func usage(_ windows: [UsageWindow], id: String = "codex:a") -> AccountUsage {
        AccountUsage(id: id, provider: .codex, accountRef: "a", label: "A", plan: nil,
                     windows: windows, state: .ok, readAt: Date(), toolVersion: nil)
    }

    @Test("kind comes from durationMinutes, not from the slot")
    func kindClassification() {
        #expect(window(60).kind == .session)
        #expect(window(300).kind == .session)
        #expect(window(301).kind == .other)
        #expect(window(10080).kind == .weekly)
        #expect(window(40320).kind == .monthly)
        #expect(window(43200).kind == .monthly)
        #expect(window(44640).kind == .monthly)
        #expect(window(44641).kind == .other)
        #expect(window(0).kind == .other)
        #expect(window(-5).kind == .other)
        #expect(window(nil).kind == .other)
    }

    @Test("a window is stale once its reset has passed")
    func staleness() {
        let now = Date()
        #expect(window(300, resetsAt: now.addingTimeInterval(-1)).isStale(now: now))
        #expect(!window(300, resetsAt: now.addingTimeInterval(1)).isStale(now: now))
        #expect(!window(300, resetsAt: nil).isStale(now: now))
    }

    @Test("priority bucketing at the 80/100 edges")
    func priorityEdges() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        let usages = [
            usage([window(300, used: 79, resetsAt: future)], id: "codex:a"),
            usage([window(300, used: 80, resetsAt: future)], id: "codex:b"),
            usage([window(300, used: 99, resetsAt: future)], id: "codex:c"),
            usage([window(10080, used: 100, resetsAt: future)], id: "codex:d"),
            usage([window(10080, used: 100, resetsAt: now.addingTimeInterval(-60))], id: "codex:e"),
        ]
        let sections = UsagePriority.sections(usages, pins: [], now: now)
        #expect(sections.pinned.isEmpty)
        #expect(sections.runningOut.map(\.usage.id) == ["codex:c", "codex:b"]) // sorted by use, high first
        #expect(sections.usedUp.map(\.usage.id) == ["codex:d"])
        // codex:e used 100% but already reset — stale, not Used Up.
    }

    @Test("a stale window never reaches Running Out; pinned shows it anyway")
    func staleNotRunningOut() {
        let now = Date()
        let usage = usage([window(300, used: 90, resetsAt: now.addingTimeInterval(-60))])
        #expect(UsagePriority.sections([usage], pins: [], now: now).runningOut.isEmpty)
        let key = UsagePriority.key(usage, usage.windows[0])
        let pinned = UsagePriority.sections([usage], pins: [key], now: now)
        #expect(pinned.pinned.map(\.key) == [key])
        #expect(pinned.runningOut.isEmpty)
    }

    @Test("a pinned window appears only under Pinned")
    func pinnedOnlyOnce() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        let usage = usage([window(300, used: 85, scope: "Fable", resetsAt: future)])
        let key = UsagePriority.key(usage, usage.windows[0])
        #expect(key == "codex:a/session/Fable")
        let sections = UsagePriority.sections([usage], pins: [key], now: now)
        #expect(sections.pinned.map(\.key) == [key])
        #expect(sections.runningOut.isEmpty)
        #expect(sections.usedUp.isEmpty)
    }

    @Test("settings written by an older version still decode, and new fields round-trip")
    func settingsCompatibility() throws {
        let old = Data(#"{"language":"en","menuBarShowsName":true,"showEmails":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: old)
        #expect(decoded.usagePins == nil)
        #expect(decoded.effectiveUsagePins == [])
        #expect(decoded.effectiveMenuBarShowsUsage == true)
        #expect(decoded.effectiveCursorUsageEnabled == false)

        let settings = SwitcherSettings(usagePins: ["codex:a/weekly/"], menuBarShowsUsage: false,
                                        cursorUsageEnabled: true)
        let roundTrip = try JSONDecoder().decode(SwitcherSettings.self,
                                                 from: JSONEncoder().encode(settings))
        #expect(roundTrip.usagePins == ["codex:a/weekly/"])
        #expect(roundTrip.effectiveUsagePins == ["codex:a/weekly/"])
        #expect(roundTrip.effectiveMenuBarShowsUsage == false)
        #expect(roundTrip.effectiveCursorUsageEnabled == true)
    }
}

@Suite("Menu bar usage title")
struct MenuBarUsageTests {
    init() { L10n.language = .en }

    private func cursorUsage(_ windows: [UsageWindow]) -> AccountUsage {
        AccountUsage(id: "cursor:current", provider: .cursor, accountRef: "current",
                     label: "Cursor", plan: nil, windows: windows, state: .ok,
                     readAt: Date(), toolVersion: nil)
    }

    private func keyedWindows(for usage: AccountUsage) -> [(key: String, window: UsageWindow)] {
        usage.windows.map { (key: UsagePriority.key(usage, $0), window: $0) }
    }

    @Test("usage title shows the REMAINING share, localized")
    func usageTitle() {
        #expect(MenuBarTitle.usage(windowName: "Weekly", usedPercent: 75.4) == "Weekly 25% left")
        #expect(MenuBarTitle.usage(windowName: "Session", usedPercent: 99.6) == "Session 0% left")
    }

    @Test("unscoped totals outrank scoped pools on the menu bar")
    func unscopedTotalWins() {
        let now = Date()
        let total = UsageWindow(durationMinutes: 43_200, usedPercent: 40,
                                resetsAt: now.addingTimeInterval(3600))
        let auto = UsageWindow(scope: "Auto", durationMinutes: 43_200, usedPercent: 95,
                               resetsAt: now.addingTimeInterval(3600))
        let candidates = MenuBarTitle.preferredUsageWindows([total, auto])
        #expect(candidates.map(\.scope) == [nil])
        #expect(MenuBarTitle.usage(
            windowName: UsageText.name(of: candidates[0], scoped: false),
            usedPercent: candidates[0].usedPercent) == "Monthly 60% left")
    }

    @Test("a pin selects a scoped Cursor pool ahead of its total")
    func pinnedScopedWindow() {
        let reset = Date().addingTimeInterval(3600)
        let total = UsageWindow(durationMinutes: 43_200, usedPercent: 25, resetsAt: reset)
        let auto = UsageWindow(scope: "Auto", durationMinutes: 43_200,
                               usedPercent: 24, resetsAt: reset)
        let usage = cursorUsage([total, auto])
        let selected = MenuBarTitle.selectWindow(
            accounts: [keyedWindows(for: usage)],
            pins: [UsagePriority.key(usage, auto)])

        #expect(selected?.scope == "Auto")
        #expect(selected?.usedPercent == 24)
    }

    @Test("without a pin the unscoped Cursor total wins")
    func unpinnedTotalWins() {
        let reset = Date().addingTimeInterval(3600)
        let total = UsageWindow(durationMinutes: 43_200, usedPercent: 25, resetsAt: reset)
        let auto = UsageWindow(scope: "Auto", durationMinutes: 43_200,
                               usedPercent: 24, resetsAt: reset)
        let usage = cursorUsage([total, auto])

        let selected = MenuBarTitle.selectWindow(
            accounts: [keyedWindows(for: usage)], pins: Set())

        #expect(selected?.scope == nil)
        #expect(selected?.usedPercent == 25)
    }

    @Test("an unpinned scoped Cursor pool cannot outrank the total")
    func unpinnedScopedPoolDoesNotWin() {
        let reset = Date().addingTimeInterval(3600)
        let total = UsageWindow(durationMinutes: 43_200, usedPercent: 25, resetsAt: reset)
        let auto = UsageWindow(scope: "Auto", durationMinutes: 43_200,
                               usedPercent: 30, resetsAt: reset)
        let usage = cursorUsage([total, auto])

        let selected = MenuBarTitle.selectWindow(
            accounts: [keyedWindows(for: usage)], pins: Set())

        #expect(selected?.scope == nil)
        #expect(selected?.usedPercent == 25)
    }
}

@Suite("Usage text")
struct UsageTextTests {
    init() { L10n.language = .en }

    @Test("window names, scoped and bare")
    func names() {
        let weekly = UsageWindow(durationMinutes: 10080, usedPercent: 50, resetsAt: nil)
        let fable = UsageWindow(scope: "Fable", durationMinutes: 10080, usedPercent: 3, resetsAt: nil)
        let session = UsageWindow(durationMinutes: 300, usedPercent: 0, resetsAt: nil)
        #expect(UsageText.name(of: weekly) == "Weekly")
        #expect(UsageText.name(of: fable) == "Weekly · Fable")
        #expect(UsageText.name(of: fable, scoped: false) == "Weekly")
        #expect(UsageText.name(of: session) == "Session")
        #expect(UsageText.left(weekly) == "50% left")
    }

    @Test("countdown formats")
    func countdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageText.countdown(to: now.addingTimeInterval(2 * 86400 + 4 * 3600), from: now) == "2d 4h")
        #expect(UsageText.countdown(to: now.addingTimeInterval(3600 + 13 * 60), from: now) == "1h 13m")
        #expect(UsageText.countdown(to: now.addingTimeInterval(5 * 60), from: now) == "5m")
        #expect(UsageText.countdown(to: now.addingTimeInterval(3600), from: now) == "1h")
        #expect(UsageText.countdown(to: now.addingTimeInterval(-60), from: now) == "now")
        #expect(UsageText.updatedAgo(readAt: now, now: now.addingTimeInterval(40 * 60)) == "updated 40m ago")
    }

    @Test("reasons and labels")
    func reasons() {
        #expect(UsageText.reason(.ok, provider: .claude) == nil)
        #expect(UsageText.reason(.notReporting, provider: .codex) == "Not reporting usage")
        #expect(UsageText.reason(.unavailable(.cliMissing), provider: .claude) == "Command-line tool not found")
        #expect(UsageText.reason(.unavailable(.schemaChanged), provider: .codex)
            == "Couldn't read usage — this Codex version may need a UsageSwitch update")
        #expect(UsageText.reason(.failed(.timeout), provider: .codex) == "Timed out reading usage")
        #expect(UsageText.planName("prolite") == "Pro Lite")
        #expect(UsageText.planName("unknownplan") == "unknownplan")
        #expect(UsageText.planName(nil) == nil)
    }
}

@Suite("Usage refresh policy")
struct UsageRefreshPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("status arriving after a refresh without Claude status requests a reread")
    func statusLoadedAfterRefresh() {
        #expect(UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: nil, newAccountIds: Set(["a"]), refreshedWithoutClaudeStatus: true))
        #expect(!UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: nil, newAccountIds: Set(["a"]), refreshedWithoutClaudeStatus: false))
        #expect(UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: nil, newAccountIds: [], refreshedWithoutClaudeStatus: true))
        #expect(!UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: nil, newAccountIds: [], refreshedWithoutClaudeStatus: false))
    }

    @Test("unchanged account ids do not refresh; added or removed ids always do")
    func registeredAccountIdsChanged() {
        #expect(!UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: Set(["a"]), newAccountIds: Set(["a"]),
            refreshedWithoutClaudeStatus: true))
        #expect(UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: Set(["a"]), newAccountIds: Set(["a", "b"]),
            refreshedWithoutClaudeStatus: false))
        #expect(UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: Set(["a", "b"]), newAccountIds: Set(["a"]),
            refreshedWithoutClaudeStatus: false))
    }

    @Test("a refresh is stalled at the watchdog limit")
    func refreshStallThreshold() {
        #expect(!UsageRefreshPolicy.isRefreshStalled(startedAt: nil, now: now.addingTimeInterval(601)))
        #expect(!UsageRefreshPolicy.isRefreshStalled(startedAt: now, now: now.addingTimeInterval(599)))
        #expect(UsageRefreshPolicy.isRefreshStalled(startedAt: now, now: now.addingTimeInterval(600)))
        #expect(UsageRefreshPolicy.isRefreshStalled(startedAt: now, now: now.addingTimeInterval(601)))
    }

    @Test("watchdog restarts stop at the abandoned refresh cap")
    func stalledRefreshRestartCap() {
        #expect(UsageRefreshPolicy.shouldRestartStalledRefresh(
            startedAt: now, now: now.addingTimeInterval(600), abandoned: 0))
        #expect(UsageRefreshPolicy.shouldRestartStalledRefresh(
            startedAt: now, now: now.addingTimeInterval(600), abandoned: 1))
        #expect(!UsageRefreshPolicy.shouldRestartStalledRefresh(
            startedAt: now, now: now.addingTimeInterval(600), abandoned: 2))
        #expect(!UsageRefreshPolicy.shouldRestartStalledRefresh(
            startedAt: now, now: now.addingTimeInterval(599), abandoned: 0))
    }

    func usage(resetsAt: Date?) -> AccountUsage {
        AccountUsage(id: "codex:a", provider: .codex, accountRef: "a", label: "A", plan: nil,
                     windows: [UsageWindow(durationMinutes: 300, usedPercent: 50, resetsAt: resetsAt)],
                     state: .ok, readAt: now, toolVersion: nil)
    }

    @Test("the interval alone makes a read due")
    func intervalDue() {
        #expect(UsageRefreshPolicy.isDue(now: now, nextRefresh: now, lastReadStartedAt: now,
                                         usages: [usage(resetsAt: now.addingTimeInterval(600))]))
    }

    @Test("a reset since the last read began is due")
    func resetAfterReadDue() {
        let readStarted = now.addingTimeInterval(-120)
        #expect(UsageRefreshPolicy.isDue(now: now, nextRefresh: now.addingTimeInterval(300),
                                         lastReadStartedAt: readStarted,
                                         usages: [usage(resetsAt: now.addingTimeInterval(-10))]))
    }

    @Test("a reset before the last read began is not due (the loop case)")
    func staleBeforeReadNotDue() {
        let readStarted = now.addingTimeInterval(-120)
        #expect(!UsageRefreshPolicy.isDue(now: now, nextRefresh: now.addingTimeInterval(300),
                                          lastReadStartedAt: readStarted,
                                          usages: [usage(resetsAt: readStarted.addingTimeInterval(-60))]))
    }

    @Test("no last read counts as distantPast — due once, then not after a read starts")
    func noReadYetDueOnce() {
        let past = usage(resetsAt: now.addingTimeInterval(-10))
        #expect(UsageRefreshPolicy.isDue(now: now, nextRefresh: now.addingTimeInterval(300),
                                         lastReadStartedAt: nil, usages: [past]))
        // After refresh() records lastReadStartedAt, the same stale window is no longer due.
        #expect(!UsageRefreshPolicy.isDue(now: now, nextRefresh: now.addingTimeInterval(300),
                                          lastReadStartedAt: now, usages: [past]))
    }
}
