import Foundation
import Testing
@testable import SwitcherCore

@Suite("Menu bar usage choice")
struct MenuBarChoiceTests {
    let reset = Date().addingTimeInterval(3600)

    func usage(_ id: String, _ windows: [UsageWindow]) -> AccountUsage {
        AccountUsage(id: id, provider: .codex, accountRef: id, label: id, plan: nil, windows: windows,
                     state: .ok, readAt: Date(), toolVersion: nil)
    }

    func keyed(_ usage: AccountUsage) -> [(key: String, window: UsageWindow)] {
        usage.windows.map { (key: UsagePriority.key(usage, $0), window: $0) }
    }

    @Test("automatic picks the least left that isn't used up")
    func automatic() {
        let a = usage("codex:a", [UsageWindow(durationMinutes: 10080, usedPercent: 40, resetsAt: reset)])
        let b = usage("codex:b", [UsageWindow(durationMinutes: 10080, usedPercent: 90, resetsAt: reset)])
        let c = usage("codex:c", [UsageWindow(durationMinutes: 10080, usedPercent: 100, resetsAt: reset)])
        let selected = MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b), keyed(c)], pins: [])
        #expect(selected?.usedPercent == 90)
    }

    @Test("a chosen window wins over pins and the automatic pick, even when used up")
    func chosenWins() {
        let a = usage("codex:a", [UsageWindow(durationMinutes: 10080, usedPercent: 40, resetsAt: reset)])
        let b = usage("codex:b", [UsageWindow(durationMinutes: 300, usedPercent: 100, resetsAt: reset),
                                  UsageWindow(durationMinutes: 10080, usedPercent: 70, resetsAt: reset)])
        let chosen = UsagePriority.key(b, b.windows[0])
        let pinned = UsagePriority.key(a, a.windows[0])
        let selected = MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [pinned], chosen: chosen)
        #expect(selected == b.windows[0])
    }

    @Test("a chosen window that isn't read right now selects nothing — never another account's limit")
    func chosenMissing() {
        let a = usage("codex:a", [UsageWindow(durationMinutes: 10080, usedPercent: 40, resetsAt: reset)])
        let b = usage("codex:b", [UsageWindow(durationMinutes: 10080, usedPercent: 80, resetsAt: reset)])
        let gone = "codex:z/weekly/"
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [], chosen: gone) == nil)
        let pinned = UsagePriority.key(a, a.windows[0])
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [pinned], chosen: gone) == nil)
        // The chosen account answered, but without the chosen window (stale or dropped).
        let other = usage("codex:z", [UsageWindow(durationMinutes: 300, usedPercent: 10, resetsAt: reset)])
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(other)], pins: [], chosen: gone) == nil)
    }

    @Test("without a choice, pins and the automatic pick work as before")
    func noChoice() {
        let a = usage("codex:a", [UsageWindow(durationMinutes: 10080, usedPercent: 40, resetsAt: reset)])
        let b = usage("codex:b", [UsageWindow(durationMinutes: 10080, usedPercent: 80, resetsAt: reset)])
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [], chosen: nil)?.usedPercent == 80)
        let pinned = UsagePriority.key(a, a.windows[0])
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [pinned], chosen: nil)?.usedPercent == 40)
        // An empty key is how "automatic" is saved: it is no choice either.
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [], chosen: "")?.usedPercent == 80)
    }

    @Test("the setting round-trips, and an empty saved key means automatic")
    func setting() throws {
        let saved = SwitcherSettings(menuBarUsageKey: "codex:a/weekly/")
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(SwitcherSettings.self, from: data)
        #expect(loaded.effectiveMenuBarUsageKey == "codex:a/weekly/")
        #expect(SwitcherSettings(menuBarUsageKey: "").effectiveMenuBarUsageKey == nil)
        #expect(SwitcherSettings().effectiveMenuBarUsageKey == nil)
        let older = try JSONDecoder().decode(SwitcherSettings.self, from: Data(#"{"menuBarShowsUsage":true}"#.utf8))
        #expect(older.effectiveMenuBarUsageKey == nil)
    }
}

/// Audit G-T-1: which readings may feed the bar was decided in the app shell, where no test saw it.
@Suite("Menu bar usage freshness")
struct MenuBarFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var reset: Date { now.addingTimeInterval(3600) }

    func usage(_ id: String, _ windows: [UsageWindow], state: UsageState = .ok,
               age: TimeInterval = 0) -> AccountUsage {
        AccountUsage(id: id, provider: .codex, accountRef: id, label: id, plan: nil, windows: windows,
                     state: state, readAt: now.addingTimeInterval(-age), toolVersion: nil)
    }

    func weekly(_ used: Double, resetsAt: Date? = nil) -> UsageWindow {
        UsageWindow(durationMinutes: 10080, usedPercent: used, resetsAt: resetsAt ?? reset)
    }

    func title(_ usages: [AccountUsage], pins: Set<String> = [], chosen: String? = nil) -> String? {
        MenuBarTitle.usageTitle(usages: usages, pins: pins, chosen: chosen, now: now)
    }

    @Test("a current reading feeds the bar, keyed like a pin")
    func current() {
        let a = usage("codex:a", [weekly(40)])
        let candidates = MenuBarTitle.candidates([a], now: now)
        #expect(candidates.count == 1)
        #expect(candidates[0].map(\.key) == [UsagePriority.key(a, a.windows[0])])
        #expect(candidates[0].map(\.window) == a.windows)
        #expect(title([a]) == MenuBarTitle.usage(windowName: UsageText.name(of: a.windows[0], scoped: false),
                                                 usedPercent: 40))
    }

    @Test("a failed or unavailable read never feeds the bar, even with its last known windows",
          arguments: [UsageState.failed(.network), .failed(.timeout), .unavailable(.noSignIn), .notReporting])
    func notOk(state: UsageState) {
        let failed = usage("codex:a", [weekly(40)], state: state)
        #expect(MenuBarTitle.candidates([failed], now: now).map(\.count) == [0])
        #expect(title([failed]) == nil)
    }

    @Test("a reading older than ten minutes, or dated in the future, is not current")
    func age() {
        let limit = UsagePresentations.verifiedAgeLimit
        #expect(limit == 600)
        #expect(title([usage("codex:a", [weekly(40)], age: limit)]) != nil)
        #expect(title([usage("codex:a", [weekly(40)], age: limit + 1)]) == nil)
        #expect(title([usage("codex:a", [weekly(40)], age: -1)]) == nil)
    }

    @Test("a window whose reset has passed, or with no real number, is left out")
    func windows() {
        let stale = weekly(90, resetsAt: now)
        let live = weekly(40)
        let broken = UsageWindow(durationMinutes: 300, usedPercent: .nan, resetsAt: reset)
        let endless = UsageWindow(durationMinutes: 1440, usedPercent: .infinity, resetsAt: reset)
        let a = usage("codex:a", [stale, broken, endless, live])
        #expect(MenuBarTitle.candidates([a], now: now)[0].map(\.window) == [live])
        // The stale 90% would win the automatic pick if it counted.
        #expect(title([a]) == MenuBarTitle.usage(windowName: UsageText.name(of: live, scoped: false),
                                                 usedPercent: 40))
        #expect(title([usage("codex:b", [stale, broken, endless])]) == nil)
    }

    @Test("an account with nothing current keeps its place, so indices match the list")
    func indices() {
        let a = usage("codex:a", [weekly(40)], state: .failed(.network))
        let b = usage("codex:b", [weekly(70)])
        let candidates = MenuBarTitle.candidates([a, b], now: now)
        #expect(candidates.map(\.count) == [0, 1])
        #expect(candidates[1].first?.window == b.windows[0])
    }

    @Test("the chosen window shows only while it is current — never another account's in its place")
    func chosenMustBeCurrent() {
        let chosen = usage("codex:a", [weekly(40)], age: 601)
        let other = usage("codex:b", [weekly(70)])
        let key = UsagePriority.key(chosen, chosen.windows[0])
        #expect(title([chosen, other], chosen: key) == nil)
        #expect(title([chosen, other]) == MenuBarTitle.usage(
            windowName: UsageText.name(of: other.windows[0], scoped: false), usedPercent: 70))
    }

    @Test("a number that can't be shown as a share left gives no title, not a dash")
    func unshowable() {
        // Only a chosen window can get this far: the automatic pick never selects a negative number.
        let a = usage("codex:a", [weekly(-5)])
        #expect(title([a], chosen: UsagePriority.key(a, a.windows[0])) == nil)
        #expect(title([a]) == nil)
    }
}
