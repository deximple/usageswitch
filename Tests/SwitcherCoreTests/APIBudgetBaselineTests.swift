import Foundation
import Testing
import SwitcherCore

@Suite("API budget: balance baseline and the usage list figure")
struct APIBudgetBaselineTests {
    /// 2025-03-19 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_742_378_400)
    private var today: String { APIBudgetMath.utcDay(now) }
    private var yesterday: String { APIBudgetMath.utcDay(now.addingTimeInterval(-86_400)) }

    private func estimate(complete: Bool = true, reading: Bool = false,
                          spend: [APIDailySpend] = []) -> APIUsageEstimate {
        APIUsageEstimate(hasAPIKeyAccounts: true, spendIsComplete: complete, spendLast7DaysUSD: nil,
                         dailyRateUSD: nil, medianDailyRate14DaysUSD: nil,
                         dailySpend: complete ? spend : [], isReadingLogs: reading)
    }

    // MARK: U-08 — a prepaid balance entered while the logs are still being read

    @Test("no baseline while the spend so far is unknown")
    func noBaselineWhileSpendIsUnknown() {
        #expect(APIBudgetMath.balanceBaseline(nil, at: now) == nil)
        // Still reading logs: the estimate carries no daily spend, which used to be saved as $0.
        #expect(APIBudgetMath.balanceBaseline(estimate(complete: false, reading: true), at: now) == nil)
        // A price the catalog doesn't know leaves the spend incomplete the same way.
        #expect(APIBudgetMath.balanceBaseline(estimate(complete: false), at: now) == nil)
    }

    @Test("a balance entered once the logs are read is measured from today's spend so far")
    func baselineIsTodaysSpend() {
        let read = estimate(spend: [APIDailySpend(day: yesterday, amountUSD: 5),
                                    APIDailySpend(day: today, amountUSD: 30)])
        let baseline = APIBudgetMath.balanceBaseline(read, at: now)
        #expect(baseline == 30)
        // $100 entered now is what is left: today's $30 was paid out of the balance already.
        let budget = APIBudget.balance(amountUSD: 100, asOf: now, asOfDaySpentUSD: baseline ?? 0)
        #expect(APIBudgetMath.remaining(budget, spending: read.dailySpend, now: now) == 100)
        #expect(APIBudgetMath.balanceBaseline(estimate(), at: now) == 0)
    }

    // MARK: The usage list's API figure counts what the API tab counts

    @Test("Anthropic's figure is the monthly quota left after this month's billing read")
    func anthropicCountsTheBillingRead() {
        let read = APICostReadState.ok(APIActualSpend(monthToDateUSD: 30, last7DaysUSD: 12,
                                                      asOf: now.addingTimeInterval(-600)))
        let quota = APIBudget.quota(amountUSD: 100, resetDayOfMonth: 1)
        #expect(APIBudgetMath.budgetRemaining(quota, vendor: .anthropic, estimate: nil, actual: read,
                                              now: now) == 70)
        // The local-log estimate never stands in for Anthropic: it has no API-key logs to price.
        #expect(APIBudgetMath.budgetRemaining(quota, vendor: .anthropic, estimate: estimate(),
                                              actual: nil, now: now) == nil)
    }

    @Test("no Anthropic figure when the billing read can't cover the budget")
    func anthropicWithoutAUsableRead() {
        let read = APICostReadState.ok(APIActualSpend(monthToDateUSD: 30, last7DaysUSD: 12, asOf: now))
        let offCycle = APIBudget.quota(amountUSD: 100, resetDayOfMonth: 15)
        let balance = APIBudget.balance(amountUSD: 100, asOf: now)
        #expect(APIBudgetMath.budgetRemaining(offCycle, vendor: .anthropic, estimate: nil, actual: read,
                                              now: now) == nil)
        #expect(APIBudgetMath.budgetRemaining(balance, vendor: .anthropic, estimate: nil, actual: read,
                                              now: now) == nil)
        #expect(APIBudgetMath.budgetRemaining(.quota(amountUSD: 100, resetDayOfMonth: 1), vendor: .anthropic,
                                              estimate: nil, actual: .keyRejected, now: now) == nil)
    }

    @Test("OpenAI's figure is the budget left after the complete local-log estimate")
    func openAICountsTheLogEstimate() {
        let quota = APIBudget.quota(amountUSD: 100, resetDayOfMonth: 1)
        let read = estimate(spend: [APIDailySpend(day: today, amountUSD: 25)])
        #expect(APIBudgetMath.budgetRemaining(quota, vendor: .openai, estimate: read, actual: nil,
                                              now: now) == 75)
        #expect(APIBudgetMath.budgetRemaining(quota, vendor: .openai, estimate: estimate(complete: false),
                                              actual: nil, now: now) == nil)
        // A billing read for OpenAI is shown beside the estimate, never counted instead of it.
        let billing = APICostReadState.ok(APIActualSpend(monthToDateUSD: 90, last7DaysUSD: 30, asOf: now))
        #expect(APIBudgetMath.budgetRemaining(quota, vendor: .openai, estimate: read, actual: billing,
                                              now: now) == 75)
    }

    @Test("Google and xAI have no figure a budget could be counted against")
    func noBasisNoFigure() {
        let quota = APIBudget.quota(amountUSD: 100, resetDayOfMonth: 1)
        for vendor in [APIVendor.google, .xai] {
            #expect(APIBudgetMath.budgetRemaining(quota, vendor: vendor, estimate: estimate(), actual: nil,
                                                  now: now) == nil)
        }
    }
}
