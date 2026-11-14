import Foundation
import Testing
@testable import SwitcherCore

/// What the Guide adds beside the ranking: a lighter model for a draining account, and
/// tools the catalog can't rank that still have room.
@Suite("Suggestion alternatives")
struct SuggestionAlternativesTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now
    private let day: TimeInterval = 86400

    private func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        L10n.string(key, language: L10n.language, args)
    }

    private func lighterCatalog() throws -> SuggestionCatalog {
        let big = Support.Model(vendor: "openai", model: "big", name: "Big",
                                efforts: ["medium", "high"], outputPrice: 20)
        let small = Support.Model(vendor: "openai", model: "small", name: "Small",
                                  efforts: ["medium", "high"], outputPrice: 5)
        return try Support.catalog(models: [big, small], entries: [
            Support.Entry(modelKey: big.key, effort: "high", tier: "mid", simple: 1, reasoning: 1),
            Support.Entry(modelKey: big.key, effort: "medium", tier: "mid", simple: 9, reasoning: 9),
            Support.Entry(modelKey: small.key, effort: "high", tier: "mid", simple: 4, reasoning: 4),
        ])
    }

    @Test("a draining account with a recent model on record gets a lighter option")
    func lighterOptionForADrainingAccount() throws {
        let catalog = try lighterCatalog()
        let runOut = SuggestionOutlook.RunOut(accountID: "codex:a", windowKey: "codex:a/weekly/",
                                              at: now.addingTimeInterval(day), basis: .windowAverage)
        let hints = [
            "codex:a": SuggestionLogSummary.Hint(model: "openai/big", effort: "high"),
            "codex:calm": SuggestionLogSummary.Hint(model: "openai/big", effort: "high"),
        ]
        let options = SuggestionOutlook.lighterOptions(runOuts: [runOut], hints: hints,
                                                       catalog: catalog, task: 0.5)
        #expect(options == [SuggestionOutlook.Lighter(
            accountID: "codex:a", modelKey: "openai/big", effort: "high",
            lighterModelKey: "openai/small", lighterEffort: "high")])

        let account = Support.usage("a", label: "Work", windows: [
            Support.window(10080, used: 70, resetsIn: 3.5 * day),
        ])
        #expect(SuggestionText.lighterLines(options, usages: [account], catalog: catalog,
                                            label: { $0.label }) == [
            string(.suggestionLighter, "Codex · Work",
                   "Big · " + string(.suggestionEffortHigh),
                   "Small · " + string(.suggestionEffortHigh)),
        ])
    }

    @Test("no lighter option without a run-out, without a model on record, or with nothing lighter")
    func noLighterOption() throws {
        let catalog = try lighterCatalog()
        let runOut = SuggestionOutlook.RunOut(accountID: "codex:a", windowKey: "codex:a/weekly/",
                                              at: now.addingTimeInterval(day), basis: .recentPace)
        let hint = SuggestionLogSummary.Hint(model: "openai/big", effort: "high")
        #expect(SuggestionOutlook.lighterOptions(runOuts: [], hints: ["codex:a": hint],
                                                 catalog: catalog, task: 0.5).isEmpty)
        #expect(SuggestionOutlook.lighterOptions(runOuts: [runOut], hints: [:],
                                                 catalog: catalog, task: 0.5).isEmpty)
        let lightest = SuggestionLogSummary.Hint(model: "openai/small", effort: "medium")
        #expect(SuggestionOutlook.lighterOptions(runOuts: [runOut], hints: ["codex:a": lightest],
                                                 catalog: catalog, task: 0.5).isEmpty)
    }

    private let blockedCodex = SuggestionTestSupport.usage("blocked", windows: [
        SuggestionTestSupport.window(300, used: 100, resetsIn: 1800),
    ])

    private func otherTools(_ usages: [AccountUsage],
                            pace: [String: UsagePace.Reading] = [:]
    ) throws -> [SuggestionOutlook.OtherTool] {
        let catalog = try Support.singleModelCatalog()
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5, catalog: catalog,
                                             usages: usages, pace: [:], now: now)
        return SuggestionOutlook.otherTools(report: report, usages: usages, catalog: catalog,
                                            pace: pace, now: now)
    }

    @Test("with no pick, a tool the catalog can't rank is listed by its tightest plan-wide limit")
    func unrankedToolWithRoom() throws {
        let cursor = Support.usage("cursor", provider: .cursor, label: "Cursor sign-in", windows: [
            Support.window(43200, used: 30, resetsIn: 12 * day),
            Support.window(43200, used: 95, resetsIn: 12 * day, scope: "Other Models"),
        ])
        let tools = try otherTools([blockedCodex, cursor])
        #expect(tools == [SuggestionOutlook.OtherTool(
            accountID: "cursor:cursor", windowKey: "cursor:cursor/monthly/", remainingShare: 0.7)])
        #expect(SuggestionText.otherToolLines(tools, usages: [blockedCodex, cursor], now: now,
                                              label: { $0.label }) == [
            string(.suggestionOtherTool, "Cursor · Cursor sign-in",
                   UsageText.name(of: cursor.windows[0]), 70)
                + " · " + string(.usageResetsIn, UsageText.countdown(
                    to: now.addingTimeInterval(12 * day), from: now)),
        ])
    }

    @Test("a tool with only model-scoped limits is judged by all of them")
    func scopedOnlyTool() throws {
        let copilot = Support.usage("current", provider: .copilot, windows: [
            Support.window(43200, used: 10, resetsIn: 12 * day, scope: "chat"),
            Support.window(43200, used: 40, resetsIn: 12 * day, scope: "completions"),
        ])
        let tools = try otherTools([blockedCodex, copilot])
        #expect(tools.map(\.windowKey) == ["copilot:current/monthly/completions"])
        #expect(abs((tools.first?.remainingShare ?? 0) - 0.6) < 0.000_001)
    }

    @Test("unranked tools are listed roomiest first, two at most")
    func roomiestFirstAndCapped() throws {
        let tools = try otherTools([blockedCodex] + [20.0, 60, 40].enumerated().map { index, used in
            Support.usage("tool-\(index)", provider: [.cursor, .devin, .copilot][index], windows: [
                Support.window(10080, used: used, resetsIn: 3 * day),
            ])
        })
        #expect(tools.map(\.accountID) == ["cursor:tool-0", "copilot:tool-2"])
    }

    @Test("nothing is listed beside a pick, or for a blocked, aged, failed or unreadable tool")
    func notListed() throws {
        let roomyCodex = Support.usage("roomy", windows: [
            Support.window(300, used: 10, resetsIn: 3600),
        ])
        let cursor = Support.usage("cursor", provider: .cursor, windows: [
            Support.window(43200, used: 30, resetsIn: 12 * day),
        ])
        #expect(try otherTools([roomyCodex, cursor]).isEmpty)

        let window = Support.window(43200, used: 30, resetsIn: 12 * day)
        #expect(try otherTools([
            blockedCodex,
            Support.usage("warned", provider: .cursor, windows: [
                Support.window(43200, used: 85, resetsIn: 12 * day),
            ]),
            Support.usage("aged", provider: .devin, readAgo: 601, windows: [window]),
            Support.usage("failed", provider: .copilot, state: .failed(.network), windows: [window]),
            Support.usage("stale", provider: .antigravity, windows: [
                Support.window(43200, used: 30, resetsIn: -60),
            ]),
            Support.usage("empty", provider: .grok, windows: []),
        ]).isEmpty)
    }

    @Test("a tool on course to run out before its reset is not said to have room")
    func drainingToolIsNotListed() throws {
        // A 30-day month, 5 days in, 60% used: the average pace empties it in about 3 days.
        let overPace = Support.usage("cursor", provider: .cursor, windows: [
            Support.window(43200, used: 60, resetsIn: 25 * day),
        ])
        #expect(try otherTools([blockedCodex, overPace]).isEmpty)

        let window = Support.window(43200, used: 30, resetsIn: 12 * day)
        let measured = Support.usage("devin", provider: .devin, windows: [window])
        #expect(try otherTools([blockedCodex, measured]).count == 1)
        #expect(try otherTools([blockedCodex, measured], pace: [
            UsagePriority.key(measured, window): .depleting(at: now.addingTimeInterval(day)),
        ]).isEmpty)
    }

    @Test("an account the engine ranked or blocked is not an unranked tool")
    func rankedProvidersAreNotOtherTools() throws {
        #expect(try otherTools([blockedCodex]).isEmpty)
    }
}
