import Foundation
import Testing
@testable import SwitcherCore

/// A long limit about to reset loses whatever is left on it, so it stops binding the ranking.
@Suite("Suggestion expiring headroom")
struct SuggestionExpiringTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    private func report(_ usages: [AccountUsage], warnThreshold: Double = 80,
                        pace: [String: UsagePace.Reading] = [:]) throws -> SuggestionReport {
        SuggestionEngine.report(mode: .balanced, task: 0.5,
                                catalog: try Support.singleModelCatalog(), usages: usages,
                                pace: pace, now: now, warnThreshold: warnThreshold)
    }

    @Test("the account whose weekly limit resets in hours wins over a fuller one days away")
    func expiringWeeklyWins() throws {
        let expiring = Support.usage("expiring", windows: [
            Support.window(10080, used: 40, resetsIn: 3 * hour),
        ])
        let fuller = Support.usage("fuller", windows: [
            Support.window(10080, used: 30, resetsIn: 6 * day),
        ])
        let result = try report([fuller, expiring])

        let pick = try #require(result.options.first)
        #expect(pick.accountID == "codex:expiring")
        #expect(pick.situation == .expiringHeadroom)
        #expect(pick.expiringWindowKey == "codex:expiring/weekly/")
        #expect(pick.limitingWindowKey == "codex:expiring/weekly/")
        #expect(pick.remainingShare == 1)
        #expect(result.options.last?.expiringWindowKey == nil)
        #expect(result.result == .suggest(accountID: "codex:expiring", provider: .codex,
                                          modelKey: "openai/solo", effort: "medium",
                                          situation: .expiringHeadroom,
                                          limitingWindowKey: "codex:expiring/weekly/"))
    }

    @Test("a shorter limit still binds beside an expiring long one")
    func shorterLimitStillBinds() throws {
        let account = Support.usage("a", windows: [
            Support.window(300, used: 35, resetsIn: 2 * hour),
            Support.window(10080, used: 40, resetsIn: 3 * hour),
        ])
        let pick = try #require(try report([account]).options.first)
        #expect(pick.situation == .expiringHeadroom)
        #expect(pick.limitingWindowKey == "codex:a/session/")
        #expect(abs(pick.remainingShare - 0.65) < 0.000_001)
        #expect(pick.expiringWindowKey == "codex:a/weekly/")
    }

    @Test("only the longest limit can expire")
    func onlyTheLongestLimitExpires() throws {
        let account = Support.usage("a", windows: [
            Support.window(300, used: 35, resetsIn: 600),
            Support.window(10080, used: 40, resetsIn: 6 * day),
        ])
        let pick = try #require(try report([account]).options.first)
        #expect(pick.situation == .remainingShare)
        #expect(pick.expiringWindowKey == nil)
        #expect(pick.limitingWindowKey == "codex:a/weekly/")
    }

    @Test("soon means the last tenth of the limit's length, and never more than a day")
    func soonBoundaries() throws {
        func expires(_ minutes: Int, resetsIn: TimeInterval) throws -> Bool {
            let account = Support.usage("a", windows: [
                Support.window(minutes, used: 40, resetsIn: resetsIn),
            ])
            return try #require(try report([account]).options.first).expiringWindowKey != nil
        }
        // A week: a tenth is 16.8 hours.
        #expect(try expires(10080, resetsIn: 16.8 * hour))
        #expect(try !expires(10080, resetsIn: 16.9 * hour))
        // A 30-day month: a tenth would be 3 days, capped at one.
        #expect(try expires(43200, resetsIn: 24 * hour))
        #expect(try !expires(43200, resetsIn: 24 * hour + 60))
    }

    @Test("a limit its own pace would use up before the reset keeps binding")
    func leftoverFloor() throws {
        // 10% left with 10 hours to go; the week's average pace spends ~5.7 of it: under 10 left over.
        let thin = Support.usage("thin", windows: [
            Support.window(10080, used: 90, resetsIn: 10 * hour),
        ])
        let pick = try #require(try report([thin], warnThreshold: 95).options.first)
        #expect(pick.expiringWindowKey == nil)
        #expect(abs(pick.remainingShare - 0.1) < 0.000_001)
    }

    @Test("the warning level and a measured early run-out still leave an expiring account out")
    func exclusionsStillWin() throws {
        let warned = Support.usage("warned", windows: [
            Support.window(10080, used: 85, resetsIn: hour),
        ])
        #expect(try report([warned]).result == .none(.excluded))

        let window = Support.window(10080, used: 40, resetsIn: 3 * hour)
        let draining = Support.usage("draining", windows: [window])
        #expect(try report([draining], pace: [
            UsagePriority.key(draining, window): .depleting(at: now.addingTimeInterval(hour)),
        ]).result == .none(.excluded))
    }

    @Test("limits of the same longest length expire together")
    func sameLengthLimitsExpireTogether() throws {
        let fable = Support.Model(vendor: "claude", model: "claude-fable-5-1", name: "Fable",
                                  efforts: ["medium"])
        let catalog = try Support.catalog(models: [fable], entries: [
            Support.Entry(modelKey: fable.key, effort: "medium", tier: "mid", simple: 1, reasoning: 1),
        ])
        let claude = Support.usage("cli", provider: .claude, windows: [
            Support.window(10080, used: 40, resetsIn: 3 * hour),
            Support.window(10080, used: 10, resetsIn: 3 * hour, scope: "Fable"),
        ])
        let pick = try #require(SuggestionEngine.report(
            mode: .balanced, task: 0.5, catalog: catalog, usages: [claude], pace: [:], now: now
        ).options.first)
        #expect(pick.remainingShare == 1)
        #expect(pick.expiringWindowKey == "claude:cli/weekly/")
    }

    @Test("a limit without a length or a reset never expires")
    func unplaceableLimitsNeverExpire() throws {
        let noReset = Support.usage("a", windows: [Support.window(10080, used: 40, resetsIn: nil)])
        #expect(try #require(try report([noReset]).options.first).expiringWindowKey == nil)
    }
}
