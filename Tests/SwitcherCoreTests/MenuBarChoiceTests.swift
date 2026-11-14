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

    @Test("a chosen window that isn't read right now falls back to pins, then automatic")
    func chosenMissing() {
        let a = usage("codex:a", [UsageWindow(durationMinutes: 10080, usedPercent: 40, resetsAt: reset)])
        let b = usage("codex:b", [UsageWindow(durationMinutes: 10080, usedPercent: 80, resetsAt: reset)])
        let gone = "codex:z/weekly/"
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [], chosen: gone)?.usedPercent == 80)
        let pinned = UsagePriority.key(a, a.windows[0])
        #expect(MenuBarTitle.selectWindow(accounts: [keyed(a), keyed(b)], pins: [pinned], chosen: gone)?.usedPercent == 40)
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
