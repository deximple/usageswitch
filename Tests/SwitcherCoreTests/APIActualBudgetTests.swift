import Foundation
import Testing
@testable import SwitcherCore

@Suite("API budgets against the billing read")
struct APIActualBudgetTests {
    private let asOf = Date(timeIntervalSince1970: 1_742_378_400)

    @Test func aMonthlyQuotaResetOnDayOneCountsTheMonthsActualSpend() {
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 1),
                                              monthToDateUSD: 30) == .remaining(70))
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 1),
                                              monthToDateUSD: 0) == .remaining(100))
    }

    @Test func aReadFromLastMonthSaysNothingAboutThisMonthsQuota() {
        // Read on 2026-10-31 23:50 UTC. Ten minutes into November that figure is last month's
        // total, and taking it off the new month's quota would show almost nothing left.
        let read = APIActualSpend(monthToDateUSD: 95, last7DaysUSD: 20,
                                  asOf: Date(timeIntervalSince1970: 1_793_490_600))
        let quota = APIBudget.quota(amountUSD: 100, resetDayOfMonth: 1)
        let sameMonth = Date(timeIntervalSince1970: 1_793_490_900)
        let nextMonth = Date(timeIntervalSince1970: 1_793_491_800)
        #expect(APIBudgetMath.actualRemaining(quota, spend: read, now: sameMonth) == .remaining(5))
        #expect(APIBudgetMath.actualRemaining(quota, spend: read, now: nextMonth) == nil)
    }

    @Test func spendOverTheQuotaLeavesZero() {
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 1),
                                              monthToDateUSD: 130) == .remaining(0))
    }

    /// The billing read is summed by UTC calendar month: a cycle that starts on another day, or a
    /// prepaid balance, can't be lined up with it.
    @Test func otherBudgetsAreNotWorkedOut() {
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 15),
                                              monthToDateUSD: 30) == .notCalendarMonth)
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 31),
                                              monthToDateUSD: 30) == .notCalendarMonth)
        #expect(APIBudgetMath.actualRemaining(.balance(amountUSD: 100, asOf: asOf),
                                              monthToDateUSD: 30) == .notCalendarMonth)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1])
    func badFiguresAreRejected(bad: Double) {
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 1),
                                              monthToDateUSD: bad) == nil)
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: bad, resetDayOfMonth: 1),
                                              monthToDateUSD: 30) == nil)
        #expect(APIBudgetMath.actualRemaining(.balance(amountUSD: bad, asOf: asOf),
                                              monthToDateUSD: 30) == nil)
    }

    @Test func aResetDayOutsideTheMonthIsRejected() {
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 0),
                                              monthToDateUSD: 30) == nil)
        #expect(APIBudgetMath.actualRemaining(.quota(amountUSD: 100, resetDayOfMonth: 32),
                                              monthToDateUSD: 30) == nil)
    }

    /// A budget is offered only where there is a spend figure to count against it.
    @Test func onlyVendorsWithASpendFigureGetABudget() {
        #expect(APIVendor.openai.budgetBasis == .localLogs)
        #expect(APIVendor.anthropic.budgetBasis == .actualSpend)
        #expect(APIVendor.google.budgetBasis == nil)
        #expect(APIVendor.xai.budgetBasis == nil)
        // the log estimate and the budget basis agree on who has local logs
        for vendor in APIVendor.allCases {
            #expect((vendor.budgetBasis == .localLogs) == vendor.hasLogReader)
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func theCalendarMonthNoteExistsInEveryLanguage(language: AppLanguage) {
        let note = L10n.string(.apiBudgetCalendarMonthOnly, language: language)
        #expect(note != L10nKey.apiBudgetCalendarMonthOnly.rawValue)
        #expect(note.contains("1"))
    }
}
