import Foundation

/// Pure consumer of the frozen `model-facts.json`/`model-tiers.json` pair. Validates
/// the captured data and exposes it as immutable values — no scoring, no network, no
/// I/O beyond the two in-memory inputs, and no mapping to providers or accounts.
public struct SuggestionCatalog: Equatable, Sendable {
    public enum LoadError: Error, Equatable, Sendable {
        case oversized
        case unsupportedVersion
        case invalidFacts
        case factsDateMismatch
        case invalidEvaluations
    }

    public enum Tier: String, Decodable, Equatable, Sendable {
        case frontier, mid, low
    }

    public struct Evidence: Equatable, Sendable {
        public enum Kind: String, Decodable, Equatable, Sendable {
            case benchmark, vendor, community
        }

        public let kind: Kind
        public let source: String
        public let checkedAt: String
        public let note: String?
    }

    public struct Value: Equatable, Sendable {
        public let id: String
        public let code: String
        public let number: Double?
        public let text: String?
        public let source: String
        public let checkedAt: String
    }

    public struct Model: Equatable, Sendable {
        public let vendorId: String
        public let model: String
        public let name: String
        public let efforts: [String]
        public let values: [Value]

        public var key: String { "\(vendorId)/\(model)" }
    }

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let effort: String
        public let tier: Tier
        public let rank: [String: Int]
        public let evidence: [Evidence]
    }

    public let factsDate: String
    public let tiersDate: String
    public let axes: [String]
    public let models: [Model]
    public let entries: [Entry]

    private static let sizeLimit = 1_048_576
    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    private static let knownCodes: Set<String> = [
        "contextTokens", "codexContextTokens", "maxOutputTokens", "inputKinds",
        "inputPricePerMTok", "outputPricePerMTok", "cachedReadPricePerMTok",
        "monthlyLimitUSD", "defaultEffort", "comparativeLatency",
    ]

    public static func bundled() throws(LoadError) -> SuggestionCatalog {
        try SuggestionCatalog(facts: Data(ModelTFSnapshot.facts.utf8),
                              tiers: Data(ModelTFSnapshot.tiers.utf8))
    }

    public init(facts: Data, tiers: Data) throws(LoadError) {
        guard facts.count <= Self.sizeLimit, tiers.count <= Self.sizeLimit else {
            throw .oversized
        }
        let fj: FactsJSON = try Self.decode(from: facts, as: .invalidFacts)
        guard fj.version == 1 else { throw .unsupportedVersion }
        guard Self.isDate(fj.date) else { throw .invalidFacts }
        let tj: TiersJSON = try Self.decode(from: tiers, as: .invalidEvaluations)
        guard tj.version == 1 else { throw .unsupportedVersion }
        guard Self.isDate(tj.date) else { throw .invalidEvaluations }
        guard tj.factsDate == fj.date else { throw .factsDateMismatch }

        self.models = try Self.validatedModels(fj.models)
        self.axes = try Self.validatedAxes(tj.axis)
        self.entries = try Self.validatedEntries(tj.entries, models: self.models,
                                                 axes: Set(self.axes))
        self.factsDate = fj.date
        self.tiersDate = tj.date
    }

    // MARK: - Decoding (structural only; unknown keys ignored by Decodable)

    private struct FactsJSON: Decodable {
        struct ModelJSON: Decodable {
            struct ValueJSON: Decodable {
                let id: String
                let code: String
                let number: Double?
                let text: String?
                let source: String
                let checkedAt: String
            }
            let vendorId: String
            let model: String
            let name: String
            let efforts: [String]
            let values: [ValueJSON]
        }
        let version: Int
        let date: String
        let models: [ModelJSON]
    }

    private struct TiersJSON: Decodable {
        struct EntryJSON: Decodable {
            struct EvidenceJSON: Decodable {
                let kind: Evidence.Kind
                let source: String
                let checkedAt: String
                let note: String?
            }
            let key: String
            let effort: String
            let tier: Tier
            let rank: [String: Int]
            let evidence: [EvidenceJSON]
        }
        let version: Int
        let date: String
        let factsDate: String
        let axis: [String]
        let entries: [EntryJSON]
    }

    private static func decode<T: Decodable>(from data: Data,
                                             as failure: LoadError) throws(LoadError) -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw failure }
    }

    // MARK: - Semantic validation

    private static func validatedModels(_ raw: [FactsJSON.ModelJSON]) throws(LoadError) -> [Model] {
        var keys = Set<String>()
        var factIds = Set<String>()
        var models: [Model] = []
        for m in raw {
            guard Self.matches(m.vendorId, pattern: /[a-z0-9][a-z0-9-]*/),
                  Self.matches(m.model, pattern: /[a-z0-9][a-z0-9._-]*/),
                  !m.name.isEmpty else { throw .invalidFacts }
            let key = "\(m.vendorId)/\(m.model)"
            guard keys.insert(key).inserted else { throw .invalidFacts }
            var ranks = [Int]()
            for effort in m.efforts {
                guard let rank = Self.effortOrder.firstIndex(of: effort) else {
                    throw .invalidFacts
                }
                ranks.append(rank)
            }
            guard ranks == ranks.sorted(), Set(m.efforts).count == m.efforts.count else {
                throw .invalidFacts
            }
            var values: [Value] = []
            for v in m.values {
                // Unknown codes are ignored before any semantic check.
                guard Self.knownCodes.contains(v.code) else { continue }
                let prefix = "\(key)/\(v.code)"
                let owned = v.id == prefix
                    || (v.id.hasPrefix(prefix + "/")
                        && Self.isToken(v.id.dropFirst(prefix.count + 1)))
                guard owned else { throw .invalidFacts }
                guard factIds.insert(v.id).inserted else { throw .invalidFacts }
                guard v.number.map(\.isFinite) ?? true,
                      v.text.map({ Self.isToken(Substring($0)) }) ?? true,
                      v.number != nil || v.text != nil else { throw .invalidFacts }
                guard Self.isHTTPSSource(v.source), Self.isDate(v.checkedAt) else {
                    throw .invalidFacts
                }
                values.append(Value(id: v.id, code: v.code, number: v.number,
                                    text: v.text, source: v.source,
                                    checkedAt: v.checkedAt))
            }
            models.append(Model(vendorId: m.vendorId, model: m.model, name: m.name,
                                efforts: m.efforts, values: values))
        }
        return models
    }

    private static func validatedAxes(_ raw: [String]) throws(LoadError) -> [String] {
        guard !raw.isEmpty, raw.allSatisfy({ Self.isToken(Substring($0)) }),
              Set(raw).count == raw.count else { throw .invalidEvaluations }
        return raw
    }

    private static func validatedEntries(_ raw: [TiersJSON.EntryJSON],
                                         models: [Model],
                                         axes: Set<String>) throws(LoadError) -> [Entry] {
        let byKey = Dictionary(uniqueKeysWithValues: models.map { ($0.key, $0) })
        var seen = Set<String>()
        var entries: [Entry] = []
        for e in raw {
            guard let model = byKey[e.key] else { continue }
            let effortOK = model.efforts.isEmpty
                ? e.effort == "default"
                : model.efforts.contains(e.effort)
            guard effortOK else { throw .invalidEvaluations }
            guard seen.insert("\(e.key)\u{0}\(e.effort)").inserted else {
                throw .invalidEvaluations
            }
            guard !e.rank.isEmpty,
                  e.rank.keys.allSatisfy({ axes.contains($0) }),
                  e.rank.values.allSatisfy({ $0 > 0 }) else { throw .invalidEvaluations }
            var evidence: [Evidence] = []
            for ev in e.evidence {
                guard Self.isHTTPSSource(ev.source), Self.isDate(ev.checkedAt) else {
                    throw .invalidEvaluations
                }
                evidence.append(Evidence(kind: ev.kind, source: ev.source,
                                         checkedAt: ev.checkedAt, note: ev.note))
            }
            guard evidence.contains(where: { $0.kind == .benchmark || $0.kind == .vendor })
            else { throw .invalidEvaluations }
            entries.append(Entry(key: e.key, effort: e.effort, tier: e.tier,
                                 rank: e.rank, evidence: evidence))
        }
        return entries
    }

    // MARK: - Primitives

    /// Nonempty and free of whitespace — used for text values, id qualifiers and axes.
    private static func isToken(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { !$0.isWhitespace }
    }

    /// Full-string regex match — no partial or trailing-newline acceptance.
    private static func matches(_ s: String, pattern: Regex<Substring>) -> Bool {
        s.wholeMatch(of: pattern) != nil
    }

    /// Proleptic Gregorian YYYY-MM-DD: four ASCII year digits, year 1...9999, real
    /// month/day including leap-year rules. No leniency, no surrounding characters.
    private static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9_999).contains(year), (1...12).contains(month) else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }

    /// HTTPS URL with a nonempty host, no embedded credentials, and no literal
    /// whitespace/control characters in the raw string.
    private static func isHTTPSSource(_ s: String) -> Bool {
        guard s.allSatisfy({ !$0.isWhitespace }),
              s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: s),
              url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}
