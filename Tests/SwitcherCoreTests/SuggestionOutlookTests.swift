import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion outlook")
struct SuggestionOutlookTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now
    private let day: TimeInterval = 86400

    private func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        L10n.string(key, language: L10n.language, args)
    }

    /// A week, half gone, 70% used: the average pace empties it 1.5 days from now.
    private let overPace = SuggestionTestSupport.window(10080, used: 70, resetsIn: 3.5 * 86400)

    @Test("a window over its average pace is forecast from that average")
    func windowAverageRunOut() {
        let account = Support.usage("a", windows: [overPace])
        let runOuts = SuggestionOutlook.runOuts(usages: [account], pace: [:], now: now)
        #expect(runOuts.count == 1)
        #expect(runOuts.first?.accountID == "codex:a")
        #expect(runOuts.first?.windowKey == "codex:a/weekly/")
        #expect(runOuts.first?.basis == .windowAverage)
        #expect(abs((runOuts.first?.at.timeIntervalSince(now) ?? 0) - 1.5 * day) < 1)
    }

    @Test("a measured pace is used before the window's average")
    func recentPaceComesFirst() {
        let account = Support.usage("a", windows: [overPace])
        let measured = now.addingTimeInterval(3600)
        let runOuts = SuggestionOutlook.runOuts(
            usages: [account], pace: [UsagePriority.key(account, overPace): .depleting(at: measured)],
            now: now)
        #expect(runOuts == [SuggestionOutlook.RunOut(
            accountID: "codex:a", windowKey: "codex:a/weekly/", at: measured, basis: .recentPace)])
    }

    @Test("a window on course to last, or one already at the warning level, is not forecast")
    func quietWindows() {
        let lasting = Support.usage("lasting", windows: [
            Support.window(10080, used: 30, resetsIn: day),
        ])
        let warned = Support.usage("warned", windows: [
            Support.window(10080, used: 85, resetsIn: 3.5 * day),
        ])
        let spent = Support.usage("spent", windows: [
            Support.window(300, used: 100, resetsIn: 3600),
        ])
        #expect(SuggestionOutlook.runOuts(usages: [lasting, warned, spent], pace: [:],
                                          now: now).isEmpty)
    }

    @Test("failed and aged readings are never forecast")
    func untrustedReadings() {
        let failed = Support.usage("failed", state: .failed(.timeout), windows: [overPace])
        let aged = Support.usage("aged", readAgo: 601, windows: [overPace])
        #expect(SuggestionOutlook.runOuts(usages: [failed, aged], pace: [:], now: now).isEmpty)
    }

    @Test("a warning level outside 50…99 forecasts nothing")
    func invalidWarnThreshold() {
        let account = Support.usage("a", windows: [overPace])
        for threshold in [Double.nan, -1, 0, 20, 100, .infinity] {
            #expect(SuggestionOutlook.runOuts(usages: [account], pace: [:], now: now,
                                              warnThreshold: threshold).isEmpty)
        }
    }

    @Test("each account shows its soonest run-out, soonest first, three at most")
    func soonestPerAccountCapped() {
        // Session 60% used with 2.5 of 5 hours gone: empty in 100 minutes; the weekly later.
        let two = Support.usage("two", windows: [
            overPace, Support.window(300, used: 60, resetsIn: 2.5 * 3600),
        ])
        let others = (1...4).map { index in
            Support.usage("other-\(index)", windows: [
                Support.window(10080, used: 60 + Double(index), resetsIn: 3.5 * day),
            ])
        }
        let runOuts = SuggestionOutlook.runOuts(usages: others + [two], pace: [:], now: now)
        #expect(runOuts.count == SuggestionOutlook.maximumRunOuts)
        #expect(runOuts.first?.windowKey == "codex:two/session/")
        #expect(runOuts.map(\.at) == runOuts.map(\.at).sorted())
        #expect(Set(runOuts.map(\.accountID)).count == runOuts.count)
    }

    @Test("the pick's weekly limit becomes a daily allowance")
    func budgetForThePick() throws {
        let account = Support.usage("a", windows: [
            Support.window(300, used: 10, resetsIn: 3600),
            Support.window(10080, used: 40, resetsIn: 4 * day),
        ])
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5,
                                             catalog: try Support.singleModelCatalog(),
                                             usages: [account], pace: [:], now: now)
        let budget = try #require(SuggestionOutlook.budget(for: report.options.first,
                                                           usages: [account], now: now))
        #expect(budget.windowKey == "codex:a/weekly/")
        #expect(abs(budget.percentPerDay - 15) < 0.000_001)
        #expect(SuggestionText.budgetLine(budget) == string(.suggestionBudget, 15))
    }

    @Test("no allowance for a session limit, a missing pick, or less than a point a day")
    func noBudget() throws {
        let session = Support.usage("a", windows: [Support.window(300, used: 40, resetsIn: 3600)])
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5,
                                             catalog: try Support.singleModelCatalog(),
                                             usages: [session], pace: [:], now: now)
        #expect(SuggestionOutlook.budget(for: report.options.first, usages: [session], now: now) == nil)
        #expect(SuggestionOutlook.budget(for: nil, usages: [session], now: now) == nil)
        #expect(SuggestionText.budgetLine(nil) == nil)
        #expect(SuggestionText.budgetLine(SuggestionOutlook.Budget(
            accountID: "codex:a", windowKey: "codex:a/monthly/", percentPerDay: 0.4)) == nil)
    }

    @Test("outlook lines name the account, the limit, the time to empty and the reset")
    func outlookLines() {
        let account = Support.usage("a", label: "Work", windows: [overPace])
        let measured = SuggestionOutlook.RunOut(accountID: "codex:a", windowKey: "codex:a/weekly/",
                                                at: now.addingTimeInterval(7200), basis: .recentPace)
        let average = SuggestionOutlook.RunOut(accountID: "codex:a", windowKey: "codex:a/weekly/",
                                               at: now.addingTimeInterval(1.5 * day),
                                               basis: .windowAverage)
        let unknown = SuggestionOutlook.RunOut(accountID: "codex:gone", windowKey: "x",
                                               at: now.addingTimeInterval(7200), basis: .recentPace)
        let lines = SuggestionText.outlookLines([measured, average, unknown], usages: [account],
                                                now: now, label: { $0.label })
        let reset = " · " + string(.usageResetsIn,
                                   UsageText.countdown(to: now.addingTimeInterval(3.5 * day), from: now))
        #expect(lines.map(\.text) == [
            string(.suggestionOutlookRecent, "Codex · Work", UsageText.name(of: overPace),
                   UsageText.countdown(to: measured.at, from: now)) + reset,
            string(.suggestionOutlookAverage, "Codex · Work", UsageText.name(of: overPace),
                   UsageText.countdown(to: average.at, from: now)) + reset,
        ])
        #expect(lines.map(\.basis) == [.recentPace, .windowAverage])
    }

    @Test("a pick on expiring headroom says which limit resets and when")
    func expiringSituationLine() throws {
        let weekly = Support.window(10080, used: 40, resetsIn: 3 * 3600)
        let account = Support.usage("a", label: "Work", windows: [weekly])
        let catalog = try Support.singleModelCatalog()
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5, catalog: catalog,
                                             usages: [account], pace: [:], now: now)
        let text = SuggestionText.explanation(for: report, usages: [account], catalog: catalog,
                                              now: now, label: { $0.label })
        #expect(text.situation == string(.suggestionSituationExpiring, UsageText.name(of: weekly), 60,
            UsageText.countdown(to: now.addingTimeInterval(3 * 3600), from: now)))
    }
}
