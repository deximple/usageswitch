import Foundation

/// Hand-maintained attribution from a usage provider to model-facts keys. A shared
/// unscoped window applies to every candidate; scoped windows require an exact
/// normalized model ID or an explicitly allowlisted family.
public struct SuggestionHarnessMap: Sendable {
    public enum ScopeMapping: Equatable, Sendable {
        case exactModelID
        case exactModelIDAndFamilies(Set<String>)
        case commonOnly
        case unknown
    }

    public struct CandidateModel: Equatable, Sendable {
        public let model: SuggestionCatalog.Model
        public let scopeMapping: ScopeMapping
    }

    private enum Selector: Sendable {
        case vendors(Set<String>)
        case sourceMentions(String)
        case twoBundle
    }

    private struct Mapping: Sendable {
        let selector: Selector
        let scopeMapping: ScopeMapping
        let familyModels: [String: Set<String>]
    }

    private static let mappings: [String: Mapping] = [
        // The pinned model-tf snapshot names Anthropic's maker id "claude".
        // `weekly/Fable` is only verified for this documented model key.
        "claude": Mapping(selector: .vendors(["anthropic", "claude"]),
                          scopeMapping: .exactModelID,
                          familyModels: ["fable": ["claude/claude-fable-5-1"]]),
        "codex": Mapping(selector: .vendors(["openai"]), scopeMapping: .commonOnly,
                         familyModels: [:]),
        "grok": Mapping(selector: .vendors(["xai"]), scopeMapping: .commonOnly,
                        familyModels: [:]),
        "gemini": Mapping(selector: .vendors(["google"]), scopeMapping: .exactModelID,
                          familyModels: [:]),
        // Kept by raw provider key for the separate Antigravity provider integration.
        "antigravity": Mapping(selector: .vendors(["google"]),
                               scopeMapping: .exactModelID, familyModels: [:]),
        // OpenCode Go reports shared account windows; its model facts identify eligible models.
        "opencode": Mapping(selector: .sourceMentions("opencode"),
                            scopeMapping: .commonOnly, familyModels: [:]),
        // Cursor and Devin have two-bundle behavior; their percentage-to-model mapping is
        // intentionally unknown until behavior hints exist, so neither is scored.
        "cursor": Mapping(selector: .twoBundle, scopeMapping: .unknown, familyModels: [:]),
        "devin": Mapping(selector: .twoBundle, scopeMapping: .unknown, familyModels: [:]),
    ]

    public init() {}

    public static let standard = SuggestionHarnessMap()

    public func candidateModels(for provider: UsageProvider,
                                catalog: SuggestionCatalog) -> [CandidateModel] {
        candidateModels(forProviderKey: provider.rawValue, catalog: catalog)
    }

    /// Raw keys allow the map to include a provider whose usage adapter is maintained
    /// on a separate branch and is not yet present in this build's `UsageProvider`.
    public func candidateModels(forProviderKey providerKey: String,
                                catalog: SuggestionCatalog) -> [CandidateModel] {
        guard let mapping = Self.mappings[providerKey] else { return [] }
        let models: [SuggestionCatalog.Model]
        switch mapping.selector {
        case .vendors(let vendorIDs):
            models = catalog.models.filter { vendorIDs.contains($0.vendorId) }
        case .sourceMentions(let source):
            models = catalog.models.filter { model in
                model.values.contains { $0.source.localizedCaseInsensitiveContains(source) }
            }
        case .twoBundle:
            models = []
        }
        return models.sorted { $0.key < $1.key }.map { model in
            let families = Set(mapping.familyModels.compactMap { family, keys in
                keys.contains(model.key) ? family : nil
            })
            let scopeMapping = families.isEmpty ? mapping.scopeMapping : .exactModelIDAndFamilies(families)
            return CandidateModel(model: model, scopeMapping: scopeMapping)
        }
    }

    public func spentWindows(in usage: AccountUsage,
                             for candidate: CandidateModel) -> [UsageWindow] {
        usage.windows.filter { window in
            guard let scope = window.scope else { return true }
            switch candidate.scopeMapping {
            case .exactModelID:
                return Self.scopeMatchesModelID(scope, model: candidate.model)
            case .exactModelIDAndFamilies(let families):
                return Self.scopeMatchesModelID(scope, model: candidate.model)
                    || Self.scopeMatchesFamily(scope, families: families)
            case .commonOnly, .unknown:
                return false
            }
        }
    }

    private static func scopeMatchesModelID(_ scope: String, model: SuggestionCatalog.Model) -> Bool {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let modelID = normalizedModelID(model.model)
        let scopedID = normalizedModelID(trimmed.hasPrefix("models/")
            ? String(trimmed.dropFirst("models/".count)) : trimmed)
        return !scopedID.isEmpty && scopedID == modelID
    }

    private static func normalizedModelID(_ value: String) -> String {
        value.lowercased().filter { $0 != "-" && $0 != "_" && $0 != "." }
    }

    private static func scopeMatchesFamily(_ scope: String, families: Set<String>) -> Bool {
        guard let family = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").last?.lowercased() else { return false }
        return families.contains(family)
    }
}
