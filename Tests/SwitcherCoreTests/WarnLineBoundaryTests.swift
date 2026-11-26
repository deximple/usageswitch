import Foundation
import Testing
@testable import SwitcherCore

/// One line for everything that asks "has this limit reached the warning level?" or "is it used
/// up?": the whole percent the row shows. A reading the bar draws as a warning is one the Guide
/// lists, the alert fires on, the Priority sections file and the suggestions leave out — and none
/// of them reacts to a reading the bar still draws as ample.
@Suite("Warning line on the shown percent")
struct WarnLineBoundaryTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now
    private let day: TimeInterval = 86400

    /// One reading under one warning setting, with what its row shows.
    private struct Case {
        let warnAt: Double
        let used: Double
        let left: Int
        let role: UsageBarPalette.Role

        var atWarning: Bool { role != .ample }
        var usedUp: Bool { role == .exhausted }
        var name: String { "warn at \(Int(warnAt)), \(used)% used" }
    }

    /// Either side of each line. `100 - used` ending in .5 rounds away from zero, so 79.5% used
    /// still reads 21% and 99.5% used still reads 1%.
    private var cases: [Case] {
        let lines: [Case] = [
            Case(warnAt: 80, used: 79.5, left: 21, role: .ample),
            Case(warnAt: 80, used: 79.6, left: 20, role: .warning),
            Case(warnAt: 80, used: 80, left: 20, role: .warning),
            Case(warnAt: 80, used: 89.5, left: 11, role: .warning),
            Case(warnAt: 80, used: 89.6, left: 10, role: .critical),
            Case(warnAt: 70, used: 69.5, left: 31, role: .ample),
            Case(warnAt: 70, used: 69.6, left: 30, role: .warning),
            Case(warnAt: 70, used: 70, left: 30, role: .warning),
            Case(warnAt: 70, used: 89.5, left: 11, role: .warning),
            Case(warnAt: 70, used: 89.6, left: 10, role: .critical),
            Case(warnAt: 90, used: 89.5, left: 11, role: .ample),
            Case(warnAt: 90, used: 89.6, left: 10, role: .warning),
            Case(warnAt: 90, used: 90, left: 10, role: .warning),
        ]
        let spent: [Case] = [70.0, 80, 90].flatMap { warnAt -> [Case] in
            [Case(warnAt: warnAt, used: 99.5, left: 1, role: .critical),
             Case(warnAt: warnAt, used: 99.6, left: 0, role: .exhausted),
             Case(warnAt: warnAt, used: 100, left: 0, role: .exhausted)]
        }
        return lines + spent
    }

    /// A weekly limit, a day into its week: too young for the window's average to forecast from.
    private func weekly(_ used: Double) -> UsageWindow {
        Support.window(10080, used: used, resetsIn: 6 * day)
    }

    private func account(_ used: Double, provider: UsageProvider = .codex,
                         resetCredits: UsageResetCredits? = nil) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):a", provider: provider, accountRef: "a", label: "Work",
                     plan: nil, windows: [weekly(used)], state: .ok, readAt: now, toolVersion: nil,
                     authentication: .subscription, identityKey: "login-a", resetCredits: resetCredits)
    }

    private func key(_ usage: AccountUsage) -> String { UsagePriority.key(usage, usage.windows[0]) }

    private func report(_ usages: [AccountUsage], warnAt: Double) throws -> SuggestionReport {
        SuggestionEngine.report(mode: .balanced, task: 0.5, catalog: try Support.singleModelCatalog(),
                                usages: usages, pace: [:], now: now, warnThreshold: warnAt)
    }

    // MARK: - The bar

    @Test("the bar's level follows the number the row shows")
    func bar() {
        for item in cases {
            #expect(UsageText.percentLeft(item.used) == item.left, "\(item.name)")
            #expect(UsageBarPalette.role(usedPercent: item.used, warnAt: item.warnAt, stale: false)
                    == item.role, "\(item.name)")
        }
    }

    @Test("the shared questions give the bar's own answers")
    func sharedLine() {
        for item in cases {
            #expect(UsageBarPalette.isAtWarningLine(usedPercent: item.used, warnAt: item.warnAt)
                    == item.atWarning, "\(item.name)")
            #expect(UsageBarPalette.isUsedUp(usedPercent: item.used) == item.usedUp, "\(item.name)")
        }
    }

    // MARK: - The Guide's attention line

    @Test("the Guide lists a limit exactly when its bar is below ample")
    func guideLine() {
        for item in cases {
            let usage = account(item.used)
            let lines = UsageAttention.lines([usage], label: \.label, warnAt: item.warnAt, now: now)
            let expected: [String] = item.atWarning
                ? [L10n.t(.usageAttnWindow, "\(UsageText.providerName(.codex)) · Work",
                          UsageText.name(of: usage.windows[0]), item.left)]
                : []
            #expect(lines.map(\.text) == expected, "\(item.name)")
            #expect(lines.filter { !$0.warn }.isEmpty, "\(item.name)")
        }
    }

    /// The bar eases a level only once the remaining share is two points above its line. The
    /// list follows the bar through that stretch, so a warning bar never sits beside a silent list.
    @Test("a limit whose bar still holds its level stays on the Guide's list")
    func guideLineFollowsTheHeldBar() {
        var marks: [String: UsageBarMemory.Mark] = [:]
        var listed: [String] = []
        for used in [80.0, 79, 79.4, 78, 79] {
            let usage = account(used)
            marks = UsageBarMemory.update(marks, usages: [usage], warnAt: 80, now: now)
            let shown = marks
            let lines = UsageAttention.lines([usage], label: \.label, warnAt: 80, now: now) { usage, window in
                UsageBarMemory.previous(for: window, of: usage, warnAt: 80, in: shown)
            }
            // The row asks for its level the same way (`UsageModel.heldBarRole`).
            let bar = UsageBarPalette.role(
                usedPercent: used, warnAt: 80, stale: false,
                previous: UsageBarMemory.previous(for: usage.windows[0], of: usage, warnAt: 80, in: shown))
            #expect(lines.count == (bar.isAtWarning ? 1 : 0), "\(used)% used")
            listed.append(lines.first?.text ?? "")
        }
        func line(_ left: Int) -> String {
            L10n.t(.usageAttnWindow, "\(UsageText.providerName(.codex)) · Work",
                   UsageText.name(of: weekly(0)), left)
        }
        // 20% turns the bar; 21% is still held; 22% eases it, and 21% reached from above stays ample.
        #expect(listed == [line(20), line(21), line(21), "", ""])
    }

    @Test("without a held level the Guide judges each limit afresh")
    func guideLineWithoutAHeldLevel() {
        let recovering = account(79)   // reads 21%
        #expect(UsageAttention.lines([recovering], label: \.label, warnAt: 80, now: now).isEmpty)
        let none = UsageAttention.lines([recovering], label: \.label, warnAt: 80, now: now) { _, _ in nil }
        #expect(none.isEmpty)
        let held = UsageAttention.lines([recovering], label: \.label, warnAt: 80, now: now) { _, _ in .warning }
        #expect(held.count == 1)
        // A held level never lists a limit that has clearly recovered.
        let recovered = UsageAttention.lines([account(78)], label: \.label, warnAt: 80, now: now) { _, _ in
            .critical
        }
        #expect(recovered.isEmpty)
    }

    // MARK: - The alert

    @Test("the alert fires exactly when the bar is below ample, as emptied when the row reads 0%")
    func alert() {
        for item in cases {
            let usage = account(item.used)
            let result = UsageAlerts.update(usages: [usage], threshold: item.warnAt, alerted: [:], now: now)
            let emptied: [Bool] = item.atWarning ? [item.usedUp] : []
            #expect(result.alerts.map(\.emptied) == emptied, "\(item.name)")
            #expect(Array(result.alerted.keys) == (item.atWarning ? [key(usage)] : []), "\(item.name)")
        }
    }

    /// The alert arms again once the row shows more than five points above the warning line —
    /// the same whole percent, so two rows that read "25%" are never treated differently.
    @Test("an alert arms again once the row shows more than five points above the line")
    func alertArmsAgain() {
        // (warn at, used that still holds the mark, used that arms it again)
        let lines: [(warnAt: Double, held: Double, armed: Double)] = [
            (80, 74.6, 74.5),   // reads 25% / 26%
            (70, 64.6, 64.5),   // reads 35% / 36%
            (90, 84.6, 84.5),   // reads 15% / 16%
        ]
        for line in lines {
            let warned = account(line.warnAt)
            let marks = UsageAlerts.update(usages: [warned], threshold: line.warnAt, alerted: [:],
                                           now: now).alerted
            #expect(marks.count == 1)
            let held = UsageAlerts.update(usages: [account(line.held)], threshold: line.warnAt,
                                          alerted: marks, now: now)
            #expect(held.alerted == marks, "warn at \(Int(line.warnAt)), \(line.held)% used")
            #expect(held.alerts.isEmpty)
            let armed = UsageAlerts.update(usages: [account(line.armed)], threshold: line.warnAt,
                                           alerted: marks, now: now)
            #expect(armed.alerted.isEmpty, "warn at \(Int(line.warnAt)), \(line.armed)% used")
            // Armed again, it fires on the next reading at the line.
            let again = UsageAlerts.update(usages: [warned], threshold: line.warnAt,
                                           alerted: armed.alerted, now: now)
            #expect(again.alerts.count == 1)
        }
    }

    // MARK: - The Priority sections

    @Test("Running Out and Used Up file a limit by the level its bar shows")
    func sections() {
        for item in cases {
            let usage = account(item.used)
            let sections = UsagePriority.sections([usage], pins: [], now: now, runningOutAt: item.warnAt)
            #expect(sections.usedUp.map(\.key) == (item.usedUp ? [key(usage)] : []), "\(item.name)")
            #expect(sections.runningOut.map(\.key)
                    == (item.atWarning && !item.usedUp ? [key(usage)] : []), "\(item.name)")
        }
    }

    /// A row that reads 0% is filed like one at 100%: under Used Up while its reset is ahead,
    /// and nowhere when the reading names no reset.
    @Test("a row that reads 0% without a reset time is filed like one at 100%")
    func usedUpWithoutAReset() {
        for used in [99.6, 100.0] {
            let window = UsageWindow(durationMinutes: 10080, usedPercent: used, resetsAt: nil)
            let usage = AccountUsage(id: "codex:a", provider: .codex, accountRef: "a", label: "Work",
                                     plan: nil, windows: [window], state: .ok, readAt: now, toolVersion: nil)
            let sections = UsagePriority.sections([usage], pins: [], now: now)
            #expect(sections.usedUp.isEmpty && sections.runningOut.isEmpty, "\(used)% used")
        }
    }

    // MARK: - A reading that isn't a number

    @Test("a reading that isn't a number reaches no line: no alert, no section, no attention line")
    func notANumber() {
        for used in [Double.nan, .infinity, -.infinity, -1] {
            let usage = account(used)
            let result = UsageAlerts.update(usages: [usage], threshold: 80, alerted: [:], now: now)
            #expect(result.alerts.isEmpty && result.alerted.isEmpty, "\(used)")
            // A mark it held is dropped, as before: the reading no longer says it is near the line.
            let marked = UsageAlerts.update(usages: [usage], threshold: 80,
                                            alerted: [key(usage): UsageAlerts.Mark(resetsAt: usage.windows[0].resetsAt)],
                                            now: now)
            #expect(marked.alerted.isEmpty, "\(used)")
            let sections = UsagePriority.sections([usage], pins: [], now: now)
            #expect(sections.usedUp.isEmpty && sections.runningOut.isEmpty, "\(used)")
            #expect(UsageAttention.lines([usage], label: \.label, warnAt: 80, now: now).isEmpty, "\(used)")
        }
    }

    // MARK: - The suggestions

    @Test("the engine leaves an account out exactly when a limit's bar is below ample")
    func engine() throws {
        for item in cases {
            let usage = account(item.used)
            let report = try report([usage], warnAt: item.warnAt)
            let reasons: [SuggestionExclusion] = item.atWarning ? [.overWarnThreshold] : []
            #expect(report.excluded.map(\.reason) == reasons, "\(item.name)")
            #expect(report.options.map(\.accountID) == (item.atWarning ? [] : [usage.id]), "\(item.name)")
        }
    }

    @Test("the comparison of Codex accounts leaves out the same ones")
    func proposals() {
        for item in cases {
            let proposals = UsageGuidance.proposals([account(item.used)], now: now, warnAt: item.warnAt)
            #expect(proposals.count == (item.atWarning ? 0 : 1), "\(item.name)")
        }
    }

    @Test("a limit is forecast to run out only while its bar is still ample")
    func runOuts() {
        for item in cases {
            let usage = account(item.used)
            let pace: [String: UsagePace.Reading] = [key(usage): .depleting(at: now.addingTimeInterval(3600))]
            let runOuts = SuggestionOutlook.runOuts(usages: [usage], pace: pace, now: now,
                                                    warnThreshold: item.warnAt)
            #expect(runOuts.map(\.windowKey) == (item.atWarning ? [] : [key(usage)]), "\(item.name)")
        }
    }

    @Test("a tool the catalog can't rank is said to have room only while its bar is still ample")
    func otherTools() throws {
        let spentCodex = Support.usage("spent", windows: [Support.window(300, used: 100, resetsIn: 1800)])
        for item in cases {
            let cursor = account(item.used, provider: .cursor)
            let usages = [spentCodex, cursor]
            let tools = SuggestionOutlook.otherTools(
                report: try report(usages, warnAt: item.warnAt), usages: usages,
                catalog: try Support.singleModelCatalog(), pace: [:], now: now,
                warnThreshold: item.warnAt)
            #expect(tools.map(\.accountID) == (item.atWarning ? [] : [cursor.id]), "\(item.name)")
        }
    }

    @Test("a held limit reset is pointed out as soon as the row reads 0%")
    func resetTickets() throws {
        for item in cases {
            let usage = account(item.used, resetCredits: UsageResetCredits(available: 1))
            let tickets = SuggestionOutlook.resetTickets(report: try report([usage], warnAt: item.warnAt),
                                                         usages: [usage], now: now)
            let expected: [SuggestionOutlook.ResetTicket] = item.usedUp
                ? [SuggestionOutlook.ResetTicket(accountID: usage.id, reason: .blocked)] : []
            #expect(tickets == expected, "\(item.name)")
        }
    }
}
