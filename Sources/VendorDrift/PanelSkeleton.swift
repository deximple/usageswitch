import Foundation

/// The shape of the `claude -p /usage` panel with every value taken out, so a report can show
/// what the vendor printed without showing usage numbers, dates, the time zone or any name.
/// Only `Current …` lines are shown at all: the rest of the panel names skills, plugins and
/// MCP servers.
public enum PanelSkeleton {
    public struct Shape: Equatable, Sendable {
        /// The redacted `Current …` lines, in order.
        public let windowLines: [String]
        /// Whether a line outside the `Current …` ones still talks about a usage percentage.
        public let mentionsUsedOutsideWindows: Bool
    }

    private static let knownScopes: Set<String> = ["all models", "Sonnet only"]
    private static let months: Set<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// The only words a redacted line may carry; any other word becomes `…`.
    private static let vocabulary: Set<String> = ["Current", "week", "session", "used", "resets", "at",
                                                  "am", "pm", "all", "models", "Sonnet", "only", "Zone"]
    private static let parenthesized = try! NSRegularExpression(pattern: #"\(([^)]*)\)"#)
    /// A run of letters or a run of digits, in any script.
    private static let word = try! NSRegularExpression(pattern: #"([\p{L}\p{M}]+|\p{N}+)"#)
    private static let zone = #"^([A-Za-z_]+(/[A-Za-z0-9_+-]+)+|UTC|GMT)$"#

    public static func shape(of text: String) -> Shape {
        var windows: [String] = []
        var mentionsUsedElsewhere = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line: String = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Current ") {
                windows.append(redacted(line))
            } else if line.contains("% used") {
                mentionsUsedElsewhere = true
            }
        }
        return Shape(windowLines: windows, mentionsUsedOutsideWindows: mentionsUsedElsewhere)
    }

    /// `Current week (Fable): 12% used · resets Nov 6 at 12:59pm (Asia/Seoul)` becomes
    /// `Current week (…): N% used · resets Mon N at N:Npm (Zone)`. Numbers, dates, zones and
    /// every word outside the panel's fixed vocabulary are replaced, so an unknown future line
    /// shows its shape and nothing else.
    static func redacted(_ line: String) -> String {
        let scoped: String = replacing(parenthesized, in: line) { (inside: String) -> String in
            if knownScopes.contains(inside) { return "(\(inside))" }
            let isZone: Bool = inside.range(of: zone, options: .regularExpression) != nil
            return isZone ? "(Zone)" : "(…)"
        }
        return replacing(word, in: scoped) { (token: String) -> String in
            if token.first?.isNumber == true { return "N" }
            if months.contains(token) { return "Mon" }
            return vocabulary.contains(token) ? token : "…"
        }
    }

    /// Replaces each match with `transform(firstGroup)`. Matches are applied back to front, so
    /// the offsets of the ones still to do stay valid.
    private static func replacing(_ expression: NSRegularExpression, in text: String,
                                  _ transform: (String) -> String) -> String {
        let all = NSRange(text.startIndex..., in: text)
        let matches: [NSTextCheckingResult] = expression.matches(in: text, range: all)
        var out: String = text
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: out), let group = Range(match.range(at: 1), in: text)
            else { continue }
            let replacement: String = transform(String(text[group]))
            out.replaceSubrange(whole, with: replacement)
        }
        return out
    }
}
