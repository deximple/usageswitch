import Foundation

/// A lighter combination than the one in use, from the same maker: a cheaper model at no
/// higher effort (or with no effort setting), or the same model at a lower effort.
/// "Lighter" is a direction, not an amount — a subscription's limits are not billed by the
/// token prices compared here.
public enum SuggestionLighter {
    public struct Alternative: Equatable, Sendable {
        public let modelKey: String
        public let effort: String?

        public init(modelKey: String, effort: String?) {
            self.modelKey = modelKey
            self.effort = effort
        }
    }

    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// The best-ranked lighter entry for the task, or nil when the catalog has none (or
    /// doesn't know the model in use).
    public static func alternative(to modelKey: String, effort: String?,
                                   catalog: SuggestionCatalog, task: Double) -> Alternative? {
        guard task.isFinite, (0...1).contains(task),
              let current = catalog.models.first(where: { $0.key == modelKey }) else { return nil }
        let currentPrice = outputPrice(current)
        // With no effort on record, the maker's default for that model stands in.
        let currentEffort = (effort ?? defaultEffort(current)).flatMap(effortOrder.firstIndex(of:))
        let models = Dictionary(catalog.models.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        let lighter = catalog.entries.compactMap { entry -> (alternative: Alternative, quality: Double)? in
            guard let model = models[entry.key], model.vendorId == current.vendorId,
                  let quality = SuggestionEngine.quality(entry.rank, task: task) else { return nil }
            let entryEffort = effortOrder.firstIndex(of: entry.effort)
            if model.key == current.key {
                guard let currentEffort, let entryEffort, entryEffort < currentEffort else { return nil }
            } else {
                guard let currentPrice, let price = outputPrice(model), price < currentPrice
                else { return nil }
                // An entry with an effort setting must not ask for more than the effort in
                // use — and when that is unknown, it can't be called lighter at all.
                if let entryEffort {
                    guard let currentEffort, entryEffort <= currentEffort else { return nil }
                }
            }
            return (Alternative(modelKey: model.key,
                                effort: model.efforts.isEmpty ? nil : entry.effort), quality)
        }
        return lighter.min {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.alternative.modelKey != $1.alternative.modelKey {
                return $0.alternative.modelKey < $1.alternative.modelKey
            }
            return ($0.alternative.effort ?? "") < ($1.alternative.effort ?? "")
        }?.alternative
    }

    private static func defaultEffort(_ model: SuggestionCatalog.Model) -> String? {
        model.values.first { $0.code == "defaultEffort" }?.text
    }

    /// The model's own output price fact; a qualified variant (a long-context tier, say) is
    /// used only when the plain one is missing.
    private static func outputPrice(_ model: SuggestionCatalog.Model) -> Double? {
        let prices = model.values.filter { $0.code == "outputPricePerMTok" }
        return (prices.first { $0.id == "\(model.key)/outputPricePerMTok" } ?? prices.first)?.number
    }
}
