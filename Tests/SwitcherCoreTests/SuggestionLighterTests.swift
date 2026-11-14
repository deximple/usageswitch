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

    @Test("with no effort on record only a cheaper model counts")
    func unknownEffort() throws {
        let catalog = try catalog([
            entry(big, "low", 30), entry(small, "max", 2), entry(small, "low", 20),
        ])
        #expect(alternative(to: big, effort: nil, in: catalog)
            == SuggestionLighter.Alternative(modelKey: small.key, effort: "max"))
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
