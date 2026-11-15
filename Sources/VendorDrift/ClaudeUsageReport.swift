import Foundation

/// The key names of the structured report `claude -p /usage` sends beside its panel text:
/// `usage_report` on the stream's assistant line, as CLI 2.1.325 sends it. The app reads none
/// of it. The names are kept so that a field the vendor adds there — the limit resets an
/// account holds, which the panel doesn't print — is noticed.
enum ClaudeUsageReport {
    private static let root = "usage_report"
    private static let rateLimits = "\(root).rate_limits"

    /// Position → the keys known there; `[]` stands for each item of a list. Only these
    /// positions are compared: what lies under any other key is never looked at.
    static let known: [String: Set<String>] = [
        root: ["session", "rate_limits"],
        rateLimits: ["limits", "extra_usage"],
        "\(rateLimits).limits[]": ["kind", "group", "percent", "resets_at", "scope", "severity", "is_active"],
        "\(rateLimits).limits[].scope": ["model", "surface"],
        "\(rateLimits).limits[].scope.model": ["display_name"],
        "\(rateLimits).limits[].scope.surface": ["display_name"],
        "\(rateLimits).extra_usage": ["is_enabled", "monthly_limit", "used_credits", "utilization", "currency"],
    ]

    /// What a key holding limit resets would likely have in its name.
    private static let resetWords = ["reset", "grant", "credit"]

    /// A new key is named only when it reads as a field name. Anything else may be an id used
    /// as a map key, and is shown as `*`.
    private static let fieldName = #"^[A-Za-z_]{1,40}$"#

    /// A key the known shape doesn't have.
    struct Added: Hashable {
        /// `position.name`.
        let path: String
        let namesAReset: Bool
    }

    struct Difference {
        /// Those named like a limit reset first.
        let added: [Added]
        /// Whether there was a `rate_limits` object to compare.
        let sawRateLimits: Bool
    }

    /// nil when no line of the stream carries a `usage_report` object. A known key that is
    /// absent is not a difference: several are optional, and an account without the limit or
    /// the extra usage they describe doesn't get them.
    static func difference(in lines: [String]) -> Difference? {
        guard let report = report(in: lines) else { return nil }
        var seen: [String: Set<String>] = [:]
        collect(report, at: root, into: &seen)
        typealias Position = (key: String, value: Set<String>)
        let added: [Added] = seen.flatMap { (position: Position) -> [Added] in
            let expected: Set<String> = known[position.key] ?? []
            let new: Set<String> = position.value.subtracting(expected)
            return new.map { (key: String) -> Added in newKey(key, at: position.key) }
        }
        // Several hidden names at one position are one line.
        let unique: Set<Added> = Set(added)
        let ordered: [Added] = unique.sorted { (first: Added, second: Added) -> Bool in
            guard first.namesAReset == second.namesAReset else { return first.namesAReset }
            return first.path < second.path
        }
        return Difference(added: ordered, sawRateLimits: seen[rateLimits] != nil)
    }

    private static func report(in lines: [String]) -> [String: Any]? {
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let report = object[root] as? [String: Any]
            else { continue }
            return report
        }
        return nil
    }

    /// The keys seen at each known position `value` reaches. Only known keys are followed.
    private static func collect(_ value: Any, at position: String, into seen: inout [String: Set<String>]) {
        if let items = value as? [Any] {
            for item in items { collect(item, at: "\(position)[]", into: &seen) }
            return
        }
        guard let object = value as? [String: Any], let expected = known[position] else { return }
        seen[position, default: []].formUnion(object.keys)
        for key in expected {
            guard let child = object[key] else { continue }
            collect(child, at: "\(position).\(key)", into: &seen)
        }
    }

    private static func newKey(_ key: String, at position: String) -> Added {
        let isFieldName: Bool = key.range(of: fieldName, options: .regularExpression) != nil
        let name: String = isFieldName ? key : "*"
        let lowered: String = key.lowercased()
        let namesAReset: Bool = resetWords.contains { (word: String) -> Bool in lowered.contains(word) }
        return Added(path: "\(position).\(name)", namesAReset: namesAReset)
    }
}
