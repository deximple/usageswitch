import Foundation

/// Hand-maintained attribution from a usage provider to model-facts keys. A shared
/// unscoped window applies to every candidate; scoped windows are used only when
/// their scope names that model or its family.
public struct SuggestionHarnessMap: Sendable {
    public enum ScopeMapping: Equatable, Sendable {
        case modelNameOrFamily
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
    }

    private static let mappings: [String: Mapping] = [
        // The pinned model-tf snapshot names Anthropic's maker id "claude".
        "claude": Mapping(selector: .vendors(["anthropic", "claude"]),
                          scopeMapping: .modelNameOrFamily),
        "codex": Mapping(selector: .vendors(["openai"]), scopeMapping: .commonOnly),
        "grok": Mapping(selector: .vendors(["xai"]), scopeMapping: .commonOnly),
        "gemini": Mapping(selector: .vendors(["google"]), scopeMapping: .modelNameOrFamily),
        // Kept by raw provider key for the separate Antigravity provider integration.
        "antigravity": Mapping(selector: .vendors(["google"]),
                               scopeMapping: .modelNameOrFamily),
        // OpenCode Go reports shared account windows; its model facts identify eligible models.
        "opencode": Mapping(selector: .sourceMentions("opencode"),
                            scopeMapping: .commonOnly),
        // Cursor and Devin have two-bundle behavior; their percentage-to-model mapping is
        // intentionally unknown until behavior hints exist, so neither is scored.
        "cursor": Mapping(selector: .twoBundle, scopeMapping: .unknown),
        "devin": Mapping(selector: .twoBundle, scopeMapping: .unknown),
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
        return models.sorted { $0.key < $1.key }.map {
            CandidateModel(model: $0, scopeMapping: mapping.scopeMapping)
        }
    }

    public func spentWindows(in usage: AccountUsage,
                             for candidate: CandidateModel) -> [UsageWindow] {
        usage.windows.filter { window in
            guard let scope = window.scope else { return true }
            guard candidate.scopeMapping == .modelNameOrFamily else { return false }
            return Self.scope(scope, matches: candidate.model)
        }
    }

    private static func scope(_ scope: String, matches model: SuggestionCatalog.Model) -> Bool {
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return false }
        let identities = [model.name, model.model, model.key]
        if identities.contains(where: {
            scope.localizedCaseInsensitiveContains($0)
                || $0.localizedCaseInsensitiveContains(scope)
        }) {
            return true
        }

        // Family words such as "Fable" in "weekly/Fable" are model-specific; maker names
        // and version numbers are not, so they cannot make every model share that scope.
        let makers: Set<String> = [
            "alibaba", "anthropic", "claude", "deepseek", "gemini", "google", "grok",
            "meta", "minimax", "moonshotai", "openai", "opencode", "stepfun", "tencent",
            "xai", "xiaomi", "zhipuai", "gpt",
        ]
        let words = (model.name + " " + model.model)
            .split { !$0.isLetter }
            .map { String($0).lowercased() }
            .filter { $0.count >= 3 && !$0.contains(where: \.isNumber) && !makers.contains($0) }
        return words.contains { scope.localizedCaseInsensitiveContains($0) }
    }
}
