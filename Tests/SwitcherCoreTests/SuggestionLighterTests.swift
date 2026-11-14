import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion lighter option")
struct SuggestionLighterTests {
    private typealias Support = SuggestionTestSupport

    private let big = SuggestionTestSupport.Model(
        vendor: "claude", model: "big", name: "Big", efforts: ["low", "medium", "high", "max"],
        outputPrice: 20)
    private let small = SuggestionTestSupport.Model(
        vendor: "claude", model: "small", name: "Small", efforts: ["low", "medium", "high", "max"],
        outputPrice: 10)
    private let pricey = SuggestionTestSupport.Model(
        vendor: "claude", model: "pricey", name: "Pricey", efforts: ["low", "high"], outputPrice: 50)
    private let unpriced = SuggestionTestSupport.Model(
        vendor: "claude", model: "unpriced", name: "Unpriced", efforts: ["low", "high"])
    private let foreign = SuggestionTestSupport.Model(
        vendor: "openai", model: "foreign", name: "Foreign", efforts: ["low", "high"], outputPrice: 1)

    private func entry(_ model: Support.Model, _ effort: String, _ rank: Int,
                       reasoning: Int? = nil) -> Support.Entry {
        Support.Entry(modelKey: model.key, effort: effort, tier: "mid", simple: rank,
                      reasoning: reasoning ?? rank)
    }

    private func catalog(_ entries: [Support.Entry]) throws -> SuggestionCatalog {
        try Support.catalog(models: [big, small, pricey, unpriced, foreign], entries: entries)
    }

    private func alternative(to model: Support.Model, effort: String?, in catalog: SuggestionCatalog,
                             task: Double = 0.5) -> SuggestionLighter.Alternative? {
        SuggestionLighter.alternative(to: model.key, effort: effort, catalog: catalog, task: task)
    }

    @Test("the same model at a lower effort is a lighter option")
    func lowerEffortOfTheSameModel() throws {
        let catalog = try catalog([
            entry(big, "low", 30), entry(big, "medium", 10), entry(big, "high", 4),
            entry(big, "max", 1),
        ])
        #expect(alternative(to: big, effort: "high", in: catalog)
            == SuggestionLighter.Alternative(modelKey: big.key, effort: "medium"))
    }

    @Test("a cheaper model of the same maker wins when it ranks better, at no higher effort")
    func cheaperModel() throws {
        let catalog = try catalog([
            entry(big, "medium", 10), entry(big, "high", 4),
            entry(small, "high", 6), entry(small, "max", 2),
        ])
        // Small at max ranks best but asks for more effort than the current high.
        #expect(alternative(to: big, effort: "high", in: catalog)
            == SuggestionLighter.Alternative(modelKey: small.key, effort: "high"))
    }

    @Test("pricier, unpriced and other makers' models are never lighter")
    func notLighter() throws {
        let catalog = try catalog([
            entry(big, "high", 4),
            entry(pricey, "low", 1), entry(unpriced, "low", 1), entry(foreign, "low", 1),
        ])
        #expect(alternative(to: big, effort: "high", in: catalog) == nil)
    }

    @Test("nothing is lighter than the cheapest model at its lowest effort, or than an unknown model")
    func nothingLighter() throws {
        let catalog = try catalog([entry(small, "low", 9), entry(big, "low", 5)])
        #expect(alternative(to: small, effort: "low", in: catalog) == nil)
        #expect(SuggestionLighter.alternative(to: "claude/unknown", effort: "high",
                                              catalog: catalog, task: 0.5) == nil)
    }

    @Test("with no effort on record the model's default effort stands in")
    func defaultEffortStandsIn() throws {
        let defaulted = Support.Model(vendor: "claude", model: "defaulted", name: "Defaulted",
                                      efforts: ["low", "medium", "high", "max"], outputPrice: 20,
                                      defaultEffort: "high")
        let catalog = try Support.catalog(models: [defaulted, small], entries: [
            entry(defaulted, "medium", 10), entry(small, "high", 6), entry(small, "max", 2),
        ])
        #expect(alternative(to: defaulted, effort: nil, in: catalog)
            == SuggestionLighter.Alternative(modelKey: small.key, effort: "high"))
    }

    @Test("with no effort on record and no default, nothing with an effort setting is called lighter")
    func unknownEffort() throws {
        let catalog = try catalog([
            entry(big, "low", 30), entry(small, "max", 2), entry(small, "low", 20),
        ])
        #expect(alternative(to: big, effort: nil, in: catalog) == nil)
    }

    @Test("a model without an effort setting is undercut only by a cheaper one without it")
    func effortlessModels() throws {
        let plain = Support.Model(vendor: "google", model: "plain", name: "Plain", efforts: [],
                                  outputPrice: 20)
        let lite = Support.Model(vendor: "google", model: "lite", name: "Lite", efforts: [],
                                 outputPrice: 5)
        let tunable = Support.Model(vendor: "google", model: "tunable", name: "Tunable",
                                    efforts: ["low", "max"], outputPrice: 5)
        let catalog = try Support.catalog(models: [plain, lite, tunable], entries: [
            entry(plain, "default", 5), entry(lite, "default", 9), entry(tunable, "max", 1),
        ])
        #expect(alternative(to: plain, effort: nil, in: catalog)
            == SuggestionLighter.Alternative(modelKey: lite.key, effort: nil))
        // Lite costs the same as Tunable, so it is not cheaper.
        #expect(alternative(to: tunable, effort: "max", in: catalog) == nil)
        // A known effort still admits a cheaper model that has no effort setting at all.
        let pricierTunable = Support.Model(vendor: "google", model: "tunable", name: "Tunable",
                                           efforts: ["low", "max"], outputPrice: 30)
        let second = try Support.catalog(models: [pricierTunable, lite], entries: [
            entry(pricierTunable, "max", 1), entry(lite, "default", 9),
        ])
        #expect(alternative(to: pricierTunable, effort: "max", in: second)
            == SuggestionLighter.Alternative(modelKey: lite.key, effort: nil))
    }

    @Test("the task setting decides which lighter option ranks best")
    func taskDecides() throws {
        let catalog = try catalog([
            entry(big, "high", 1),
            entry(big, "medium", 2, reasoning: 40), entry(small, "high", 40, reasoning: 2),
        ])
        #expect(alternative(to: big, effort: "high", in: catalog, task: 0)?.modelKey == big.key)
        #expect(alternative(to: big, effort: "high", in: catalog, task: 1)?.modelKey == small.key)
    }
}
