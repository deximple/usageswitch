import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion engine")
struct SuggestionEngineTests {
    private struct TestModel {
        let vendor: String
        let model: String
        let name: String
        let efforts: [String]
        var factSource: String? = nil

        var key: String { "\(vendor)/\(model)" }
    }

    private struct TestEntry {
        let modelKey: String
        let effort: String
        let tier: String
        let simple: Int
        let reasoning: Int
    }

    private struct Selected {
        let accountID: String
        let provider: UsageProvider
        let modelKey: String
        let effort: String?
        let situation: SituationCode
        let limitingWindowKey: String
        let neutral: Bool
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCatalog(models: [TestModel], entries: [TestEntry]) throws -> SuggestionCatalog {
        let facts = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "date": "2027-01-01",
            "models": models.map { model in
                let values: [[String: Any]] = model.factSource.map { source in
                    [["id": "\(model.vendor)/\(model.model)/inputPricePerMTok",
                      "code": "inputPricePerMTok", "number": 1,
                      "source": source, "checkedAt": "2027-01-01"]]
                } ?? []
                return ["vendorId": model.vendor, "model": model.model, "name": model.name,
                        "efforts": model.efforts, "values": values] as [String: Any]
            },
        ])
        let tiers = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "date": "2027-01-01",
            "factsDate": "2027-01-01",
            "axis": ["simpleCoding", "reasoning"],
            "entries": entries.map {
                ["key": $0.modelKey, "effort": $0.effort, "tier": $0.tier,
                 "rank": ["simpleCoding": $0.simple, "reasoning": $0.reasoning],
                 "evidence": [["kind": "benchmark",
                               "source": "https://benchmark.example.invalid/models",
                               "checkedAt": "2027-01-01"]]] as [String: Any]
            },
        ])
        return try SuggestionCatalog(facts: facts, tiers: tiers)
    }

    private func usage(_ id: String = "codex:account", provider: UsageProvider = .codex,
                       state: UsageState = .ok, readAt: Date? = nil,
                       windows: [UsageWindow]? = nil) -> AccountUsage {
        AccountUsage(id: id, provider: provider, accountRef: "account", label: "Test",
                     plan: nil, windows: windows ?? [
                        UsageWindow(durationMinutes: 300, usedPercent: 20,
                                    resetsAt: now.addingTimeInterval(3600)),
                     ], state: state, readAt: readAt ?? now, toolVersion: nil)
    }

    private func selected(_ result: SuggestionResult) -> Selected? {
        switch result {
        case .suggest(let accountID, let provider, let modelKey, let effort,
                      let situation, let limitingWindowKey):
            return Selected(accountID: accountID, provider: provider, modelKey: modelKey,
                            effort: effort, situation: situation,
                            limitingWindowKey: limitingWindowKey, neutral: false)
        case .neutral(let accountID, let provider, let modelKey, let effort,
                      let situation, let limitingWindowKey):
            return Selected(accountID: accountID, provider: provider, modelKey: modelKey,
                            effort: effort, situation: situation,
                            limitingWindowKey: limitingWindowKey, neutral: true)
        case .none:
            return nil
        }
    }

    private func run(_ mode: SuggestionMode, task: Double = 0.5,
                     catalog: SuggestionCatalog, usages: [AccountUsage],
                     pace: [String: UsagePace.Reading] = [:]) -> SuggestionResult {
        SuggestionEngine.suggest(mode: mode, task: task, catalog: catalog,
                                 usages: usages, pace: pace, now: now)
    }

    @Test("mode ceilings filter effort and tier, and an empty effort list passes every ceiling")
    func modeCeilings() throws {
        let model = TestModel(vendor: "openai", model: "ceiling-model",
                              name: "Ceiling Model",
                              efforts: ["low", "medium", "high", "max"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "low", tier: "low", simple: 20, reasoning: 20),
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid", simple: 10, reasoning: 10),
            TestEntry(modelKey: model.key, effort: "high", tier: "mid", simple: 2, reasoning: 2),
            TestEntry(modelKey: model.key, effort: "max", tier: "frontier", simple: 1, reasoning: 1),
        ])
        let account = usage()
        #expect(selected(run(.saver, catalog: catalog, usages: [account]))?.effort == "medium")
        #expect(selected(run(.balanced, catalog: catalog, usages: [account]))?.effort == "high")
        #expect(selected(run(.focus, catalog: catalog, usages: [account]))?.effort == "high")
        #expect(selected(run(.urgent, catalog: catalog, usages: [account]))?.effort == "max")

        let noEffort = TestModel(vendor: "google", model: "effortless-model",
                                 name: "Effortless Model", efforts: [])
        let emptyCatalog = try makeCatalog(models: [noEffort], entries: [
            TestEntry(modelKey: noEffort.key, effort: "default", tier: "low",
                      simple: 1, reasoning: 1),
        ])
        let google = usage("gemini:account", provider: .gemini,
                           windows: [UsageWindow(scope: noEffort.model, durationMinutes: nil,
                                                usedPercent: 20,
                                                resetsAt: now.addingTimeInterval(3600))])
        for mode in SuggestionMode.allCases {
            let choice = try #require(selected(run(mode, catalog: emptyCatalog, usages: [google])))
            #expect(choice.effort == nil)
        }
    }

    @Test("balanced admits frontier at medium and mid at high")
    func balancedCeilingBranches() throws {
        let model = TestModel(vendor: "openai", model: "balanced-model",
                              name: "Balanced Model", efforts: ["low", "medium", "high"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "low", tier: "low", simple: 50, reasoning: 50),
            TestEntry(modelKey: model.key, effort: "medium", tier: "frontier", simple: 1, reasoning: 1),
            TestEntry(modelKey: model.key, effort: "high", tier: "mid", simple: 2, reasoning: 2),
        ])
        let account = usage()
        #expect(selected(run(.balanced, catalog: catalog, usages: [account]))?.effort == "medium")

        let midHigh = TestModel(vendor: "openai", model: "mid-high",
                                name: "Mid High", efforts: ["low", "medium", "high"])
        let secondCatalog = try makeCatalog(models: [midHigh], entries: [
            TestEntry(modelKey: midHigh.key, effort: "low", tier: "low", simple: 50, reasoning: 50),
            TestEntry(modelKey: midHigh.key, effort: "medium", tier: "frontier", simple: 50, reasoning: 50),
            TestEntry(modelKey: midHigh.key, effort: "high", tier: "mid", simple: 1, reasoning: 1),
        ])
        #expect(selected(run(.balanced, catalog: secondCatalog, usages: [account]))?.effort == "high")
    }

    @Test("task interpolates the model-tf simple-coding and reasoning ranks")
    func taskRankInterpolation() throws {
        let simpleModel = TestModel(vendor: "openai", model: "simple-model",
                                    name: "Simple Model", efforts: ["medium"])
        let reasoningModel = TestModel(vendor: "openai", model: "reasoning-model",
                                       name: "Reasoning Model", efforts: ["medium"])
        let catalog = try makeCatalog(models: [simpleModel, reasoningModel], entries: [
            TestEntry(modelKey: simpleModel.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 100),
            TestEntry(modelKey: reasoningModel.key, effort: "medium", tier: "mid",
                      simple: 100, reasoning: 1),
        ])
        let account = usage()
        #expect(selected(run(.balanced, task: 0, catalog: catalog,
                             usages: [account]))?.modelKey == simpleModel.key)
        #expect(selected(run(.balanced, task: 1, catalog: catalog,
                             usages: [account]))?.modelKey == reasoningModel.key)
    }

    @Test("state, age, reset and warning exclusions are independent")
    func exclusions() throws {
        let model = TestModel(vendor: "openai", model: "eligible",
                              name: "Eligible", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        let expired = UsageWindow(durationMinutes: 300, usedPercent: 20,
                                  resetsAt: now.addingTimeInterval(-1))
        let warning = UsageWindow(durationMinutes: 300, usedPercent: 80,
                                  resetsAt: now.addingTimeInterval(3600))
        #expect(run(.balanced, catalog: catalog,
                    usages: [usage(state: .failed(.network))]) == .none(.noCatalogMatch))
        #expect(run(.balanced, catalog: catalog,
                    usages: [usage(readAt: now.addingTimeInterval(-601))]) == .none(.noCatalogMatch))
        #expect(run(.balanced, catalog: catalog,
                    usages: [usage(windows: [expired])]) == .none(.excluded))
        #expect(run(.balanced, catalog: catalog,
                    usages: [usage(windows: [warning])]) == .none(.excluded))
    }

    @Test("a window projected to run out before reset excludes its candidates")
    func runsOutBeforeReset() throws {
        let model = TestModel(vendor: "openai", model: "depleting",
                              name: "Depleting", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        let window = UsageWindow(durationMinutes: 300, usedPercent: 50,
                                 resetsAt: now.addingTimeInterval(3600))
        let account = usage(windows: [window])
        let reading: [String: UsagePace.Reading] = [
            UsagePriority.key(account, window): .depleting(at: now.addingTimeInterval(1800)),
        ]
        #expect(run(.balanced, catalog: catalog, usages: [account], pace: reading)
                == .none(.excluded))
        #expect(!SuggestionGuideFallback.shouldShowLegacyProposal(
            for: run(.balanced, catalog: catalog, usages: [account], pace: reading)))
        #expect(SuggestionGuideFallback.shouldShowLegacyProposal(for: .none(.noCatalogMatch)))
    }

    @Test("unknown pace uses current remaining share and produces a neutral single candidate")
    func unknownPaceAndNeutral() throws {
        let model = TestModel(vendor: "openai", model: "single",
                              name: "Single", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 2, reasoning: 2),
        ])
        let window = UsageWindow(durationMinutes: 300, usedPercent: 35,
                                 resetsAt: now.addingTimeInterval(3600))
        let account = usage(windows: [window])
        let choice = try #require(selected(run(.balanced, catalog: catalog, usages: [account])))
        #expect(choice.neutral)
        #expect(choice.situation == .remainingShare)
        #expect(choice.limitingWindowKey == UsagePriority.key(account, window))
    }

    @Test("one account with multiple model candidates remains neutral")
    func oneAccountMultipleModelsIsNeutral() throws {
        let first = TestModel(vendor: "openai", model: "first",
                              name: "First", efforts: ["medium"])
        let second = TestModel(vendor: "openai", model: "second",
                               name: "Second", efforts: ["medium"])
        let catalog = try makeCatalog(models: [first, second], entries: [
            TestEntry(modelKey: first.key, effort: "medium", tier: "mid",
                      simple: 2, reasoning: 2),
            TestEntry(modelKey: second.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        let choice = try #require(selected(run(.balanced, catalog: catalog, usages: [usage()])))
        #expect(choice.neutral)
        #expect(choice.modelKey == second.key)
    }

    @Test("equal scores break by AccountUsage id")
    func tieBreak() throws {
        let model = TestModel(vendor: "openai", model: "tie",
                              name: "Tie", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 5, reasoning: 5),
        ])
        let first = usage("z-account")
        let second = usage("a-account")
        let choice = try #require(selected(run(.balanced, catalog: catalog,
                                               usages: [first, second])))
        #expect(choice.accountID == "a-account")
        #expect(!choice.neutral)
    }

    @Test("scoped windows require exact IDs except for explicitly mapped Claude Fable")
    func scopedWindowMatching() throws {
        let model = TestModel(vendor: "claude", model: "claude-fable-5-1",
                              name: "Claude Fable 5.1", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 5, reasoning: 5),
        ])
        let common = UsageWindow(durationMinutes: 300, usedPercent: 20,
                                 resetsAt: now.addingTimeInterval(3600))
        let fable = UsageWindow(scope: "weekly/Fable", durationMinutes: 10080,
                                usedPercent: 60, resetsAt: now.addingTimeInterval(86400))
        let unrelated = UsageWindow(scope: "weekly/Opus", durationMinutes: 10080,
                                    usedPercent: 70, resetsAt: now.addingTimeInterval(86400))
        let account = usage("claude:account", provider: .claude,
                            windows: [common, fable, unrelated])
        let mapped = try #require(SuggestionHarnessMap.standard
            .candidateModels(for: .claude, catalog: catalog).first)
        #expect(SuggestionHarnessMap.standard.spentWindows(in: account, for: mapped)
                == [common, fable])
        let choice = try #require(selected(run(.balanced, catalog: catalog,
                                               usages: [account])))
        #expect(choice.limitingWindowKey == UsagePriority.key(account, fable))
    }

    @Test("Gemini scopes match full normalized IDs, not shared family words")
    func geminiScopedModelIdentity() throws {
        let model = TestModel(vendor: "google", model: "gemini-3.5-flash-lite",
                              name: "Gemini 3.5 Flash Lite", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        let common = UsageWindow(durationMinutes: 300, usedPercent: 20,
                                 resetsAt: now.addingTimeInterval(3600))
        let unrelated = UsageWindow(scope: "gemini-3.8-flash", durationMinutes: 1440,
                                    usedPercent: 79, resetsAt: now.addingTimeInterval(7200))
        let account = usage("gemini:account", provider: .gemini,
                            windows: [common, unrelated])
        let mapped = try #require(SuggestionHarnessMap.standard
            .candidateModels(for: .gemini, catalog: catalog).first)
        #expect(SuggestionHarnessMap.standard.spentWindows(in: account, for: mapped) == [common])
        let choice = try #require(selected(run(.balanced, catalog: catalog, usages: [account])))
        #expect(choice.limitingWindowKey == UsagePriority.key(account, common))

        let equivalent = UsageWindow(scope: "models/Gemini_3.5.Flash-Lite",
                                     durationMinutes: 1440, usedPercent: 45,
                                     resetsAt: now.addingTimeInterval(7200))
        #expect(SuggestionHarnessMap.standard.spentWindows(
            in: usage("gemini:account", provider: .gemini, windows: [equivalent]),
            for: mapped) == [equivalent])
    }

    @Test("Cursor and Devin 2-bundle rows are never scored")
    func twoBundleProvidersNeverScored() throws {
        let model = TestModel(vendor: "openai", model: "available",
                              name: "Available", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        for provider in [UsageProvider.cursor, .devin] {
            #expect(run(.balanced, catalog: catalog,
                        usages: [usage("\(provider.rawValue):account", provider: provider)])
                    == .none(.noCatalogMatch))
        }
    }

    @Test("catalogs can carry an Anthropic model under model-tf's claude maker id")
    func claudeMakerAlias() throws {
        let model = TestModel(vendor: "claude", model: "claude-fable-5-1",
                              name: "Claude Fable 5.1", efforts: ["medium"])
        let catalog = try makeCatalog(models: [model], entries: [
            TestEntry(modelKey: model.key, effort: "medium", tier: "mid",
                      simple: 1, reasoning: 1),
        ])
        #expect(SuggestionHarnessMap.standard.candidateModels(for: .claude,
                                                              catalog: catalog).map(\.model.key)
                == [model.key])
    }

    @Test("provider mappings select makers, OpenCode facts, and the future Antigravity raw key")
    func providerMappings() throws {
        let openai = TestModel(vendor: "openai", model: "openai-model",
                               name: "OpenAI Model", efforts: ["medium"])
        let xai = TestModel(vendor: "xai", model: "grok-model",
                            name: "Grok Model", efforts: ["medium"])
        let google = TestModel(vendor: "google", model: "gemini-model",
                               name: "Gemini Model", efforts: ["medium"])
        let opencode = TestModel(vendor: "xai", model: "opencode-model",
                                 name: "OpenCode Model", efforts: ["medium"],
                                 factSource: "https://opencode.ai/docs/go/")
        let catalog = try makeCatalog(models: [openai, xai, google, opencode], entries: [])
        let map = SuggestionHarnessMap.standard
        #expect(map.candidateModels(for: .codex, catalog: catalog).map(\.model.key)
                == [openai.key])
        #expect(map.candidateModels(for: .grok, catalog: catalog).map(\.model.key)
                == [xai.key, opencode.key])
        #expect(map.candidateModels(for: .gemini, catalog: catalog).map(\.model.key)
                == [google.key])
        #expect(map.candidateModels(forProviderKey: "antigravity", catalog: catalog)
                .map(\.model.key) == [google.key])
        #expect(map.candidateModels(for: .opencode, catalog: catalog).map(\.model.key)
                == [opencode.key])
    }
}
