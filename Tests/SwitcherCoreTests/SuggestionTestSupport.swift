import Foundation
@testable import SwitcherCore

/// Small catalog and usage builders shared by the Guide suites.
enum SuggestionTestSupport {
    struct Model {
        let vendor: String
        let model: String
        let name: String
        let efforts: [String]
        /// Output price per million tokens; nil leaves the model without a price fact.
        var outputPrice: Double? = nil

        var key: String { "\(vendor)/\(model)" }
    }

    struct Entry {
        let modelKey: String
        let effort: String
        let tier: String
        let simple: Int
        let reasoning: Int
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func catalog(models: [Model], entries: [Entry]) throws -> SuggestionCatalog {
        let facts = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "date": "2027-01-01",
            "models": models.map { model in
                let values: [[String: Any]] = model.outputPrice.map { price in
                    [["id": "\(model.key)/outputPricePerMTok", "code": "outputPricePerMTok",
                      "number": price, "source": "https://prices.example.invalid/models",
                      "checkedAt": "2027-01-01"]]
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

    /// One OpenAI model at medium effort — every Codex account maps to it.
    static func singleModelCatalog() throws -> SuggestionCatalog {
        let model = Model(vendor: "openai", model: "solo", name: "Solo", efforts: ["medium"])
        return try catalog(models: [model], entries: [
            Entry(modelKey: model.key, effort: "medium", tier: "mid", simple: 2, reasoning: 2),
        ])
    }

    static func window(_ minutes: Int?, used: Double, resetsIn: TimeInterval?,
                       scope: String? = nil) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    static func usage(_ ref: String, provider: UsageProvider = .codex, state: UsageState = .ok,
                      readAgo: TimeInterval = 0, label: String? = nil,
                      windows: [UsageWindow]) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider, accountRef: ref,
                     label: label ?? ref, plan: nil, windows: windows, state: state,
                     readAt: now.addingTimeInterval(-readAgo), toolVersion: nil)
    }
}
