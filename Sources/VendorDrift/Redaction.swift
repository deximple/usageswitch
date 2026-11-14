import Foundation

/// Last line of defense for anything this tool prints. The checks are written to never carry
/// account data into a finding; this still strips the shapes account data would have.
public enum Redaction {
    private static let patterns: [(String, String)] = [
        (#"/Users/[^/\s`]+"#, "/Users/<user>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<id>"),
        (#"\b(org|user|acct)[-_][A-Za-z0-9]{8,}"#, "<id>"),
        (#"\beyJ[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+)*"#, "<token>"),
        (#"\b(sk|xai|ya29|GOCSPX|gh[pousr]|xox[bp])[-._][A-Za-z0-9._-]{8,}"#, "<token>"),
        (#"\bBearer\s+\S+"#, "<token>"),
        (#"\b[0-9a-fA-F]{32,}\b"#, "<token>"),
    ]

    public static func scrub(_ text: String, home: URL) -> String {
        // The home folder as a whole path component run: not inside `/private/Users/x`, and
        // not the front of `/Users/x-other`. Those fall to the `/Users/<user>` pattern.
        let homePattern = #"(?<![A-Za-z0-9_./-])"#
            + NSRegularExpression.escapedPattern(for: home.standardizedFileURL.path) + #"(?![A-Za-z0-9_.-])"#
        let withoutHome = text.replacingOccurrences(of: homePattern, with: "~", options: .regularExpression)
        return patterns.reduce(withoutHome) { out, pattern in
            out.replacingOccurrences(of: pattern.0, with: pattern.1, options: .regularExpression)
        }
    }

    /// A path with the home folder shown as `~`.
    public static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path, root = home.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path
    }
}

/// The key names and JSON types of a value — never a value itself, and never a key nobody
/// has vetted: an unknown shape may well be a map keyed by an account or organization id.
enum JSONShape {
    /// `a.b: string` lines down to `depth` levels. A key outside `known` is shown as `*`.
    static func keys(of value: Any, depth: Int = 3, known: Set<String>) -> [String] {
        lines(of: value, prefix: "", depth: depth, known: known).sorted()
    }

    private static func lines(of value: Any, prefix: String, depth: Int, known: Set<String>) -> [String] {
        guard let object = value as? [String: Any], depth > 0 else { return [] }
        return Array(Set(object.flatMap { key, child -> [String] in
            let path = prefix + (known.contains(key) ? key : "*")
            return ["\(path): \(type(of: child))"]
                + lines(of: child, prefix: path + ".", depth: depth - 1, known: known)
        }))
    }

    private static func type(of value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case is String: return "string"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        case is [Any]: return "array"
        default: return "object"
        }
    }
}
