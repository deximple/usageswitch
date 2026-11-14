import Foundation
import Testing
@testable import SwitcherCore

/// The Guide points at a limit reset the account holds; it never uses one.
@Suite("Suggestion reset tickets")
struct SuggestionResetTicketTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    private func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        L10n.string(key, language: L10n.language, args)
    }

    private func tickets(_ usages: [AccountUsage],
                         pace: [String: UsagePace.Reading] = [:]) throws -> [SuggestionOutlook.ResetTicket] {
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5,
                                             catalog: try Support.singleModelCatalog(),
                                             usages: usages, pace: pace, now: now)
        return SuggestionOutlook.resetTickets(report: report, usages: usages, now: now)
    }

    private func blocked(_ ref: String, credits: UsageResetCredits?, state: UsageState = .ok,
                         readAgo: TimeInterval = 0) -> AccountUsage {
        Support.usage(ref, state: state, readAgo: readAgo, windows: [
            Support.window(10080, used: 100, resetsIn: 2 * day),
        ], resetCredits: credits)
    }

    private func roomy(_ ref: String, credits: UsageResetCredits?) -> AccountUsage {
        Support.usage(ref, windows: [Support.window(10080, used: 30, resetsIn: 5 * day)],
                      resetCredits: credits)
    }

    @Test("an account left out at the warning level that holds a reset is pointed out")
    func blockedAccountWithAReset() throws {
        let account = blocked("spent", credits: UsageResetCredits(
            available: 2, expiries: [now.addingTimeInterval(18 * day)]))
        #expect(try tickets([account]) == [
            SuggestionOutlook.ResetTicket(accountID: "codex:spent", reason: .blocked),
        ])
    }

    @Test("a reset expiring within two days is pointed out even when the account has room")
    func expiringReset() throws {
        let soon = now.addingTimeInterval(30 * hour)
        #expect(try tickets([roomy("a", credits: UsageResetCredits(available: 1, expiries: [soon]))])
            == [SuggestionOutlook.ResetTicket(accountID: "codex:a", reason: .expiring(at: soon))])
        #expect(try tickets([roomy("a", credits: UsageResetCredits(
            available: 1, expiries: [now.addingTimeInterval(2 * day + 60)]))]).isEmpty)
        // No expiry on record: nothing is about to lapse.
        #expect(try tickets([roomy("a", credits: UsageResetCredits(available: 1))]).isEmpty)
    }

    @Test("blocked accounts come first, then the soonest expiry, two lines at most")
    func orderAndCap() throws {
        let later = roomy("later", credits: UsageResetCredits(
            available: 1, expiries: [now.addingTimeInterval(40 * hour)]))
        let sooner = roomy("sooner", credits: UsageResetCredits(
            available: 1, expiries: [now.addingTimeInterval(10 * hour)]))
        let spent = blocked("spent", credits: UsageResetCredits(available: 1))
        let result = try tickets([later, sooner, spent])
        #expect(result.map(\.accountID) == ["codex:spent", "codex:sooner"])
        #expect(result.count == SuggestionOutlook.maximumResetTickets)
    }

    @Test("an account with no reset left to use is not pointed out")
    func noUsableReset() throws {
        #expect(try tickets([blocked("none", credits: nil)]).isEmpty)
        #expect(try tickets([blocked("zero", credits: UsageResetCredits(available: 0))]).isEmpty)
        // The one reset on record has already expired.
        #expect(try tickets([blocked("lapsed", credits: UsageResetCredits(
            available: 1, expiries: [now.addingTimeInterval(-60)]))]).isEmpty)
        // Two held, one expiry known and passed: the other may still be good.
        #expect(try tickets([blocked("partly", credits: UsageResetCredits(
            available: 2, expiries: [now.addingTimeInterval(-60)]))]).count == 1)
    }

    @Test("failed and aged readings never point at a reset")
    func untrustedReadings() throws {
        let credits = UsageResetCredits(available: 1, expiries: [now.addingTimeInterval(hour)])
        #expect(try tickets([
            blocked("failed", credits: credits, state: .failed(.timeout)),
            blocked("aged", credits: credits, readAgo: 601),
        ]).isEmpty)
    }

    @Test("an account draining early is not blocked at its limit, so only an expiry is pointed out")
    func drainingAccount() throws {
        let window = Support.window(10080, used: 50, resetsIn: 3 * day)
        let far = Support.usage("draining", windows: [window],
                                resetCredits: UsageResetCredits(available: 1))
        #expect(try tickets([far], pace: [
            UsagePriority.key(far, window): .depleting(at: now.addingTimeInterval(day)),
        ]).isEmpty)
    }

    @Test("the lines repeat the row's reset wording and say what the user could do")
    func lines() throws {
        let spentCredits = UsageResetCredits(available: 2, expiries: [now.addingTimeInterval(18 * day)])
        let spent = Support.usage("spent", label: "Work", windows: [
            Support.window(10080, used: 100, resetsIn: 2 * day),
        ], resetCredits: spentCredits)
        let soonCredits = UsageResetCredits(available: 1, expiries: [now.addingTimeInterval(30 * hour)])
        let soon = Support.usage("soon", label: "Personal", windows: [
            Support.window(10080, used: 30, resetsIn: 5 * day),
        ], resetCredits: soonCredits)
        let usages = [spent, soon]
        let text = SuggestionText.resetTicketLines(try tickets(usages), usages: usages, now: now,
                                                   label: { $0.label })
        #expect(text == [
            string(.suggestionTicketBlocked, "Codex · Work",
                   try #require(UsageText.resetCredits(spentCredits, now: now))),
            string(.suggestionTicketExpiring, "Codex · Personal",
                   try #require(UsageText.resetCredits(soonCredits, now: now))),
        ])
    }
}
