import Foundation
import Testing

@testable import SwitcherCore

@Suite("Usage bar memory")
struct UsageBarMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ id: String = "codex:work", state: UsageState = .ok, used: Double,
                         resetsIn: TimeInterval? = 3600) -> AccountUsage {
        AccountUsage(id: id, provider: .codex, accountRef: "work", label: "Work", plan: nil,
                     windows: [UsageWindow(scope: nil, durationMinutes: 300, usedPercent: used,
                                           resetsAt: resetsIn.map(now.addingTimeInterval))],
                     state: state, readAt: now, toolVersion: nil)
    }

    /// One reading after another, the way the app feeds them; returns the level shown each time.
    private func levels(_ readings: [AccountUsage], warnAt: [Double]) -> [UsageBarPalette.Role?] {
        var marks: [String: UsageBarMemory.Mark] = [:]
        var shown: [UsageBarPalette.Role?] = []
        for (usage, line) in zip(readings, warnAt) {
            marks = UsageBarMemory.update(marks, usages: [usage], warnAt: line, now: now)
            shown.append(marks[UsagePriority.key(usage, usage.windows[0])]?.role)
        }
        return shown
    }

    @Test("a level that got worse holds until the remaining share clears its line by two points")
    func holdsAcrossReadings() {
        let readings = [80.0, 79, 79.4, 78, 79].map { account(used: $0) }
        #expect(levels(readings, warnAt: Array(repeating: 80, count: 5))
                == [.warning, .warning, .warning, .ample, .ample])
    }

    @Test("the row asks for the level it showed last")
    func previousLevel() {
        let first = account(used: 80)
        let marks = UsageBarMemory.update([:], usages: [first], warnAt: 80, now: now)
        let next = account(used: 79)
        let key = UsagePriority.key(next, next.windows[0])
        #expect(UsageBarMemory.previous(for: next.windows[0], key: key, warnAt: 80, in: marks) == .warning)
        #expect(UsageBarMemory.previous(for: next.windows[0], key: "codex:other/session/", warnAt: 80,
                                        in: marks) == nil)
    }

    @Test("a new cycle starts without the old level")
    func newCycleForgets() {
        // The reset moved by a day: a different cycle, judged afresh.
        let readings = [account(used: 80), account(used: 79, resetsIn: 3600 + 86400)]
        #expect(levels(readings, warnAt: [80, 80]) == [.warning, .ample])
        // A reset that only wobbles by a few minutes is the same cycle.
        let wobble = [account(used: 80), account(used: 79, resetsIn: 3600 + 300)]
        #expect(levels(wobble, warnAt: [80, 80]) == [.warning, .warning])
        // A reading without a reset time can't name another cycle, so the level holds.
        let unknown = [account(used: 80, resetsIn: nil), account(used: 79, resetsIn: nil)]
        #expect(levels(unknown, warnAt: [80, 80]) == [.warning, .warning])
        let lost = [account(used: 80), account(used: 79, resetsIn: nil)]
        #expect(levels(lost, warnAt: [80, 80]) == [.warning, .warning])
    }

    @Test("a changed warning setting starts without the old level")
    func changedSettingForgets() {
        // 25% left is under the 30% line. At 21% left the 20% line would hold a warning it had
        // reached itself, but this one was reached against another line: judged afresh.
        let readings = [account(used: 75), account(used: 79), account(used: 79)]
        #expect(levels(readings, warnAt: [70, 80, 80]) == [.warning, .ample, .ample])
        // The same readings under one setting do hold.
        #expect(levels([account(used: 80), account(used: 79)], warnAt: [80, 80]) == [.warning, .warning])
    }

    @Test("only a current reading is remembered")
    func onlyCurrentReadings() {
        let ok = account(used: 85)
        let failed = account("codex:failed", state: .failed(.timeout), used: 85)
        let reset = account("codex:reset", used: 85, resetsIn: -60)
        let marks = UsageBarMemory.update([:], usages: [ok, failed, reset], warnAt: 80, now: now)
        #expect(marks.keys.sorted() == [UsagePriority.key(ok, ok.windows[0])])
        // An account that is gone leaves nothing behind, and a stale one drops its mark.
        #expect(UsageBarMemory.update(marks, usages: [], warnAt: 80, now: now).isEmpty)
        let stale = account(state: .failed(.timeout), used: 85)
        #expect(UsageBarMemory.update(marks, usages: [stale], warnAt: 80, now: now).isEmpty)
    }
}
