import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage forecast")
struct UsageForecastTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ minutes: Int?, used: Double, resetsIn: TimeInterval?) -> UsageWindow {
        UsageWindow(durationMinutes: minutes, usedPercent: used,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    @Test("a window ahead of its average pace is projected to stay under its limit")
    func underPace() throws {
        // A week, 6 days in, 30% used: 35% at the reset.
        let projection = try #require(UsageForecast.projection(
            window(10080, used: 30, resetsIn: 86400), now: now))
        #expect(abs(projection.elapsedFraction - 6.0 / 7.0) < 0.000_001)
        #expect(abs(projection.projectedUsedAtReset - 35) < 0.000_001)
        #expect(projection.runsOutAt == nil)
    }

    @Test("a window burning faster than its length allows runs out before the reset")
    func overPace() throws {
        // A week, 3.5 days in, 70% used: 20%/day, so the last 30% lasts 1.5 more days.
        let projection = try #require(UsageForecast.projection(
            window(10080, used: 70, resetsIn: 3.5 * 86400), now: now))
        #expect(abs(projection.projectedUsedAtReset - 140) < 0.000_001)
        let runsOutAt = try #require(projection.runsOutAt)
        #expect(abs(runsOutAt.timeIntervalSince(now) - 1.5 * 86400) < 1)
    }

    @Test("an average pace that lands exactly on the limit at the reset is not an early run-out")
    func exactlyOnPace() throws {
        let projection = try #require(UsageForecast.projection(
            window(10080, used: 50, resetsIn: 3.5 * 86400), now: now))
        #expect(abs(projection.projectedUsedAtReset - 100) < 0.000_001)
        #expect(projection.runsOutAt == nil)
    }

    @Test("an exhausted window is already out, not running out")
    func exhausted() throws {
        let projection = try #require(UsageForecast.projection(
            window(300, used: 100, resetsIn: 3600), now: now))
        #expect(projection.runsOutAt == nil)
    }

    @Test("too little of the window has passed to call a pace")
    func tooEarly() {
        // 14.9% of a week elapsed: nothing; 15%: a projection.
        let week = 7.0 * 86400
        #expect(UsageForecast.projection(
            window(10080, used: 20, resetsIn: week * (1 - 0.149)), now: now) == nil)
        #expect(UsageForecast.projection(
            window(10080, used: 20, resetsIn: week * (1 - 0.15)), now: now) != nil)
    }

    @Test("readings that can't place the window in time give no projection")
    func unplaceable() {
        #expect(UsageForecast.projection(window(10080, used: 40, resetsIn: nil), now: now) == nil)
        #expect(UsageForecast.projection(window(nil, used: 40, resetsIn: 3600), now: now) == nil)
        #expect(UsageForecast.projection(window(0, used: 40, resetsIn: 3600), now: now) == nil)
        #expect(UsageForecast.projection(window(300, used: 40, resetsIn: -1), now: now) == nil)
        // The reset is farther away than the window is long: the two disagree.
        #expect(UsageForecast.projection(window(300, used: 40, resetsIn: 6 * 3600), now: now) == nil)
        #expect(UsageForecast.projection(window(300, used: .nan, resetsIn: 3600), now: now) == nil)
        #expect(UsageForecast.projection(window(300, used: 140, resetsIn: 3600), now: now) == nil)
    }

    @Test("the daily budget spreads what is left over the days to the reset")
    func dailyBudget() throws {
        // 60% left, 4 days to go: 15% a day.
        let budget = try #require(UsageForecast.dailyBudget(
            window(10080, used: 40, resetsIn: 4 * 86400), now: now))
        #expect(abs(budget - 15) < 0.000_001)
    }

    @Test("no daily budget inside the last day, for an unknown reset, or for a bad number")
    func noDailyBudget() {
        #expect(UsageForecast.dailyBudget(window(10080, used: 40, resetsIn: 86399), now: now) == nil)
        #expect(UsageForecast.dailyBudget(window(10080, used: 40, resetsIn: nil), now: now) == nil)
        #expect(UsageForecast.dailyBudget(window(10080, used: .infinity, resetsIn: 4 * 86400),
                                          now: now) == nil)
        #expect(UsageForecast.dailyBudget(window(10080, used: 100, resetsIn: 4 * 86400), now: now) == nil)
    }
}
