import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion report")
struct SuggestionReportTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now

    private func report(_ usages: [AccountUsage], catalog: SuggestionCatalog? = nil,
                        mode: SuggestionMode = .balanced, task: Double = 0.5,
                        pace: [String: UsagePace.Reading] = [:]) throws -> SuggestionReport {
        SuggestionEngine.report(mode: mode, task: task,
                                catalog: try catalog ?? Support.singleModelCatalog(),
                                usages: usages, pace: pace, now: now)
    }

    @Test("the report's result is what suggest returns for the same inputs")
    func resultMatchesSuggest() throws {
        let catalog = try Support.singleModelCatalog()
        let scenarios: [[AccountUsage]] = [
            [],
            [Support.usage("a", windows: [Support.window(300, used: 20, resetsIn: 3600)])],
            [Support.usage("a", windows: [Support.window(300, used: 20, resetsIn: 3600)]),
             Support.usage("b", windows: [Support.window(300, used: 60, resetsIn: 3600)])],
            [Support.usage("a", windows: [Support.window(300, used: 95, resetsIn: 3600)])],
            [Support.usage("a", state: .failed(.network), windows: [])],
        ]
        for usages in scenarios {
            for mode in SuggestionMode.allCases {
                let suggested = SuggestionEngine.suggest(mode: mode, task: 0.5, catalog: catalog,
                                                         usages: usages, pace: [:], now: now)
                #expect(try report(usages, catalog: catalog, mode: mode).result == suggested)
            }
        }
    }

    @Test("options hold each account's best candidate, best first, and the first is the pick")
    func optionsRankAccounts() throws {
        let roomy = Support.usage("roomy", windows: [
            Support.window(300, used: 10, resetsIn: 3600),
            Support.window(10080, used: 30, resetsIn: 4 * 86400),
        ])
        let tight = Support.usage("tight", windows: [
            Support.window(300, used: 60, resetsIn: 3600),
        ])
        let result = try report([tight, roomy])

        #expect(result.options.map(\.accountID) == ["codex:roomy", "codex:tight"])
        let first = try #require(result.options.first)
        #expect(first.limitingWindowKey == "codex:roomy/weekly/")
        #expect(abs(first.remainingShare - 0.7) < 0.000_001)
        #expect(first.modelKey == "openai/solo")
        #expect(result.result == .suggest(accountID: "codex:roomy", provider: .codex,
                                          modelKey: "openai/solo", effort: "medium",
                                          situation: .remainingShare,
                                          limitingWindowKey: "codex:roomy/weekly/"))
        #expect(result.excluded.isEmpty)
    }

    @Test("an account at the warning level is left out with the window that blocks it")
    func excludedOverWarnThreshold() throws {
        let blocked = Support.usage("blocked", windows: [
            Support.window(300, used: 92, resetsIn: 3600),
            Support.window(10080, used: 85, resetsIn: 3 * 86400),
            Support.window(43200, used: 10, resetsIn: 20 * 86400),
        ])
        let result = try report([blocked])

        #expect(result.result == .none(.excluded))
        #expect(result.options.isEmpty)
        // Both the session and the weekly block; the account frees up when the later one resets.
        #expect(result.excluded == [SuggestionReport.Excluded(
            accountID: "codex:blocked", provider: .codex, reason: .overWarnThreshold,
            windowKey: "codex:blocked/weekly/", unblocksAt: now.addingTimeInterval(3 * 86400))])
    }

    @Test("a blocking window with no reset time has no unblock moment")
    func excludedWithoutReset() throws {
        let blocked = Support.usage("blocked", windows: [
            Support.window(300, used: 92, resetsIn: 3600),
            Support.window(10080, used: 85, resetsIn: nil),
        ])
        let excluded = try #require(try report([blocked]).excluded.first)
        #expect(excluded.windowKey == "codex:blocked/weekly/")
        #expect(excluded.unblocksAt == nil)
    }

    @Test("an account draining before its reset is left out with the projected moment")
    func excludedRunsOutEarly() throws {
        let window = Support.window(300, used: 50, resetsIn: 3600)
        let draining = Support.usage("draining", windows: [window])
        let runsOutAt = now.addingTimeInterval(1800)
        let result = try report([draining], pace: [
            UsagePriority.key(draining, window): .depleting(at: runsOutAt),
        ])

        #expect(result.excluded == [SuggestionReport.Excluded(
            accountID: "codex:draining", provider: .codex, reason: .runsOutEarly(at: runsOutAt),
            windowKey: "codex:draining/session/", unblocksAt: now.addingTimeInterval(3600))])
    }

    @Test("a window whose reset already passed is left out as unreadable, never with a time")
    func excludedInvalidWindow() throws {
        let stale = Support.usage("stale", windows: [
            Support.window(300, used: 20, resetsIn: -60),
        ])
        #expect(try report([stale]).excluded == [SuggestionReport.Excluded(
            accountID: "codex:stale", provider: .codex, reason: .invalidWindow,
            windowKey: "codex:stale/session/", unblocksAt: nil)])
    }

    @Test("the unblock moment waits for every blocker, whatever its kind")
    func unblockWaitsForEveryBlocker() throws {
        // The session is spent (resets in 40 min) and the weekly drains before its own reset
        // in 3 days: the account stays blocked until the weekly resets.
        let session = Support.window(300, used: 100, resetsIn: 40 * 60)
        let weekly = Support.window(10080, used: 50, resetsIn: 3 * 86400)
        let account = Support.usage("mixed", windows: [session, weekly])
        let runsOutAt = now.addingTimeInterval(2 * 86400)
        let excluded = try #require(try report([account], pace: [
            UsagePriority.key(account, weekly): .depleting(at: runsOutAt),
        ]).excluded.first)

        #expect(excluded.reason == .runsOutEarly(at: runsOutAt))
        #expect(excluded.windowKey == "codex:mixed/weekly/")
        #expect(excluded.unblocksAt == now.addingTimeInterval(3 * 86400))
    }

    @Test("with two draining windows the later reset is the unblock moment")
    func unblockWaitsForTheLastDrainingWindow() throws {
        let session = Support.window(300, used: 50, resetsIn: 3600)
        let weekly = Support.window(10080, used: 50, resetsIn: 3 * 86400)
        let account = Support.usage("draining", windows: [session, weekly])
        let excluded = try #require(try report([account], pace: [
            UsagePriority.key(account, session): .depleting(at: now.addingTimeInterval(600)),
            UsagePriority.key(account, weekly): .depleting(at: now.addingTimeInterval(86400)),
        ]).excluded.first)

        #expect(excluded.reason == .runsOutEarly(at: now.addingTimeInterval(86400)))
        #expect(excluded.windowKey == "codex:draining/weekly/")
        #expect(excluded.unblocksAt == now.addingTimeInterval(3 * 86400))
    }

    @Test("an unreadable window beside a blocked one leaves no unblock moment")
    func unreadableWindowHidesTheUnblockMoment() throws {
        let account = Support.usage("mixed", windows: [
            Support.window(300, used: 95, resetsIn: 3600),
            Support.window(10080, used: 20, resetsIn: -60),
        ])
        let excluded = try #require(try report([account]).excluded.first)
        #expect(excluded.reason == .invalidWindow)
        #expect(excluded.windowKey == "codex:mixed/weekly/")
        #expect(excluded.unblocksAt == nil)
    }

    @Test("failed, aged and unmapped readings appear in neither list")
    func ignoredReadings() throws {
        let window = Support.window(300, used: 20, resetsIn: 3600)
        let result = try report([
            Support.usage("failed", state: .failed(.network), windows: [window]),
            Support.usage("aged", readAgo: 601, windows: [window]),
            Support.usage("cursor", provider: .cursor, windows: [window]),
        ])
        #expect(result.options.isEmpty)
        #expect(result.excluded.isEmpty)
        #expect(result.result == .none(.noCatalogMatch))
    }

    @Test("an account with one usable model is an option even when another model is blocked")
    func partlyBlockedAccountStaysAnOption() throws {
        let open = Support.Model(vendor: "google", model: "open-model", name: "Open", efforts: [])
        let shut = Support.Model(vendor: "google", model: "shut-model", name: "Shut", efforts: [])
        let catalog = try Support.catalog(models: [open, shut], entries: [
            Support.Entry(modelKey: open.key, effort: "default", tier: "mid", simple: 5, reasoning: 5),
            Support.Entry(modelKey: shut.key, effort: "default", tier: "mid", simple: 1, reasoning: 1),
        ])
        let gemini = Support.usage("current", provider: .gemini, windows: [
            Support.window(nil, used: 20, resetsIn: 3600, scope: "open-model"),
            Support.window(nil, used: 95, resetsIn: 3600, scope: "shut-model"),
        ])
        let result = try report([gemini], catalog: catalog)

        #expect(result.options.map(\.modelKey) == [open.key])
        #expect(result.excluded.isEmpty)
    }

    @Test("the earliest unblock is the left-out account that frees up first")
    func earliestUnblock() throws {
        let later = Support.usage("later", windows: [Support.window(300, used: 95, resetsIn: 7200)])
        let sooner = Support.usage("sooner", windows: [Support.window(300, used: 95, resetsIn: 1800)])
        let unknown = Support.usage("unknown", windows: [Support.window(300, used: 95, resetsIn: nil)])
        let result = try report([later, unknown, sooner])

        #expect(result.excluded.count == 3)
        #expect(result.earliestUnblock?.accountID == "codex:sooner")
        #expect(try report([unknown]).earliestUnblock == nil)
    }

    @Test("an invalid task or warning level reports nothing")
    func invalidInputs() throws {
        let account = Support.usage("a", windows: [Support.window(300, used: 20, resetsIn: 3600)])
        let invalidTask = try report([account], task: 2)
        #expect(invalidTask.result == .none(.invalidTask))
        #expect(invalidTask.options.isEmpty && invalidTask.excluded.isEmpty)

        let invalidWarn = SuggestionEngine.report(
            mode: .balanced, task: 0.5, catalog: try Support.singleModelCatalog(),
            usages: [account], pace: [:], now: now, warnThreshold: 20)
        #expect(invalidWarn.result == .none(.invalidWarnThreshold))
        #expect(invalidWarn.options.isEmpty && invalidWarn.excluded.isEmpty)
    }
}
