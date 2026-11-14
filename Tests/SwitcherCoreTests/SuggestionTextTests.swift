import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion text")
struct SuggestionTextTests {
    private typealias Support = SuggestionTestSupport
    private let now = SuggestionTestSupport.now

    private func string(_ key: L10nKey, _ args: CVarArg...) -> String {
        L10n.string(key, language: L10n.language, args)
    }

    private func explanation(_ usages: [AccountUsage],
                             pace: [String: UsagePace.Reading] = [:],
                             recentEffort: @escaping (AccountUsage) -> String? = { _ in nil }
    ) throws -> SuggestionText.Explanation {
        let catalog = try Support.singleModelCatalog()
        let report = SuggestionEngine.report(mode: .balanced, task: 0.5, catalog: catalog,
                                             usages: usages, pace: pace, now: now)
        return SuggestionText.explanation(for: report, usages: usages, catalog: catalog, now: now,
                                          label: { $0.label }, recentEffort: recentEffort)
    }

    private let roomy = SuggestionTestSupport.usage("roomy", label: "Personal", windows: [
        SuggestionTestSupport.window(10080, used: 30, resetsIn: 4 * 86400),
    ])
    private let tight = SuggestionTestSupport.usage("tight", label: "Work", windows: [
        SuggestionTestSupport.window(10080, used: 60, resetsIn: 2 * 86400),
    ])

    @Test("the headline names the provider, the account, the model and the effort")
    func headlineNamesThePick() throws {
        let text = try explanation([roomy, tight])
        #expect(text.headline == string(.suggestionHeadline,
            "Codex · Personal · Solo · " + string(.suggestionEffortMedium)))
        #expect(text.empty.isEmpty)
    }

    @Test("a single account reads as available, not as a recommendation")
    func singleAccountIsNeutral() throws {
        let text = try explanation([roomy])
        #expect(text.headline == string(.suggestionHeadlineNeutral,
            "Codex · Personal · Solo · " + string(.suggestionEffortMedium)))
    }

    @Test("the situation line says how the limiting window stands and what was used lately")
    func situationLine() throws {
        let window = roomy.windows[0]
        let unknownPace = try explanation([roomy, tight])
        #expect(unknownPace.situation == string(.suggestionSituationRemaining,
                                                UsageText.name(of: window), 70))

        let steady = try explanation([roomy, tight],
                                     pace: [UsagePriority.key(roomy, window): .steady],
                                     recentEffort: { $0.id == "codex:roomy" ? "high" : nil })
        #expect(steady.situation == string(.suggestionSituationHeadroom,
                                           UsageText.name(of: window), 70)
            + string(.suggestionRecentEffort, string(.suggestionEffortHigh)))
    }

    @Test("compared lines list every weighed account in rank order with its reset")
    func comparedLines() throws {
        let text = try explanation([tight, roomy])
        let model = "Solo · " + string(.suggestionEffortMedium)
        #expect(text.compared == [
            string(.suggestionBasisOption, "Codex · Personal", model,
                   UsageText.name(of: roomy.windows[0]), 70)
                + " · " + string(.usageResetsIn, UsageText.countdown(
                    to: now.addingTimeInterval(4 * 86400), from: now)),
            string(.suggestionBasisOption, "Codex · Work", model,
                   UsageText.name(of: tight.windows[0]), 40)
                + " · " + string(.usageResetsIn, UsageText.countdown(
                    to: now.addingTimeInterval(2 * 86400), from: now)),
        ])
        #expect(text.leftOut.isEmpty)
    }

    @Test("compared lines stop at four accounts")
    func comparedLinesAreCapped() throws {
        let many = (1...6).map { index in
            Support.usage("acct-\(index)", windows: [
                Support.window(10080, used: Double(index * 5), resetsIn: 86400),
            ])
        }
        #expect(try explanation(many).compared.count == 4)
    }

    @Test("left-out lines give each reason in plain words")
    func leftOutLines() throws {
        let warned = Support.usage("warned", label: "Warned", windows: [
            Support.window(300, used: 92, resetsIn: 3600),
        ])
        let drainingWindow = Support.window(300, used: 50, resetsIn: 3600)
        let draining = Support.usage("draining", label: "Draining", windows: [drainingWindow])
        let stale = Support.usage("stale", label: "Stale", windows: [
            Support.window(300, used: 20, resetsIn: -60),
        ])
        let text = try explanation([roomy, warned, draining, stale], pace: [
            UsagePriority.key(draining, drainingWindow): .depleting(at: now.addingTimeInterval(900)),
        ])
        let session = UsageText.name(of: drainingWindow)
        #expect(text.leftOut == [
            string(.suggestionLeftOutWarn, "Codex · Warned", session, 8)
                + " · " + string(.usageResetsIn, UsageText.countdown(
                    to: now.addingTimeInterval(3600), from: now)),
            string(.suggestionLeftOutPace, "Codex · Draining", session),
            string(.suggestionLeftOutStale, "Codex · Stale", session),
        ])
    }

    @Test("with every account at its limit the empty state says which one frees up first")
    func emptyStateNamesTheEarliestReset() throws {
        let later = Support.usage("later", label: "Later", windows: [
            Support.window(300, used: 95, resetsIn: 7200),
        ])
        let sooner = Support.usage("sooner", label: "Sooner", windows: [
            Support.window(300, used: 100, resetsIn: 1800),
        ])
        let text = try explanation([later, sooner])
        #expect(text.headline == nil)
        #expect(text.situation == nil)
        #expect(text.empty == [
            string(.suggestionNoneExcluded),
            string(.suggestionFreesFirst, "Codex · Sooner", UsageText.name(of: sooner.windows[0]),
                   UsageText.countdown(to: now.addingTimeInterval(1800), from: now)),
        ])
        #expect(text.leftOut.count == 2)
    }

    @Test("an unknown reset leaves the empty state at one line")
    func emptyStateWithoutResetTime() throws {
        let blocked = Support.usage("blocked", windows: [
            Support.window(300, used: 95, resetsIn: nil),
        ])
        #expect(try explanation([blocked]).empty == [string(.suggestionNoneExcluded)])
    }

    @Test("no candidate for the mode and task has its own line; an unmapped provider has none")
    func emptyStateForNoFitAndNoMatch() throws {
        let frontierOnly = Support.Model(vendor: "openai", model: "frontier-only",
                                         name: "Frontier Only", efforts: ["max"])
        let catalog = try Support.catalog(models: [frontierOnly], entries: [
            Support.Entry(modelKey: frontierOnly.key, effort: "max", tier: "frontier",
                          simple: 1, reasoning: 1),
        ])
        let noFit = SuggestionEngine.report(mode: .saver, task: 0.5, catalog: catalog,
                                            usages: [roomy], pace: [:], now: now)
        #expect(noFit.result == .none(.noCandidates))
        #expect(SuggestionText.explanation(for: noFit, usages: [roomy], catalog: catalog, now: now,
                                           label: { $0.label }).empty
            == [string(.suggestionNoneNoFit)])

        let cursor = Support.usage("cursor", provider: .cursor, windows: [
            Support.window(43200, used: 30, resetsIn: 86400),
        ])
        let noMatch = try explanation([cursor])
        #expect(noMatch.empty.isEmpty)
        #expect(noMatch.headline == nil)
    }

    @Test("every effort level has a name and an unknown one falls back")
    func effortNames() {
        let named: [(String, L10nKey)] = [
            ("none", .suggestionEffortNone), ("minimal", .suggestionEffortMinimal),
            ("low", .suggestionEffortLow), ("medium", .suggestionEffortMedium),
            ("high", .suggestionEffortHigh), ("xhigh", .suggestionEffortXHigh),
            ("max", .suggestionEffortMax),
        ]
        for (effort, key) in named {
            #expect(SuggestionText.effortName(effort) == string(key))
        }
        #expect(SuggestionText.effortName("turbo") == string(.suggestionEffortUnspecified))
        #expect(SuggestionText.effortName(nil) == string(.suggestionEffortUnspecified))
    }
}
