import Foundation

/// Small strict JSON/scalar helpers shared by the usage adapters. Everything here
/// is fail-closed: wrong types, non-finite numbers, and out-of-range values are nil.
enum UsageJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func string(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
    /// Bounded identifier: ASCII letters/digits and ._:/- only — no spaces, @,
    /// control or bidi characters. For model/project/scope-style fields.
    static func plainID(_ v: Any?, max: Int = 128) -> String? {
        guard let s = string(v), s.count <= max, s.unicodeScalars.allSatisfy({ c in
            let v = c.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) ||
                   (v >= 0x61 && v <= 0x7A) ||
                   c == "." || c == "_" || c == ":" || c == "/" || c == "-"
        }) else { return nil }
        return s
    }
    /// Bounded printable token text: ASCII printable, no control characters —
    /// base64/JWT punctuation allowed. For credential values, never identifiers.
    static func token(_ v: Any?, max: Int = 4096) -> String? {
        guard let s = string(v), s.count <= max, s.unicodeScalars.allSatisfy({ c in
            c.value >= 0x20 && c.value < 0x7F
        }) else { return nil }
        return s
    }
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue; return d.isFinite ? d : nil
        }
        if let s = v as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }
    static func percent(_ v: Any?, in range: ClosedRange<Double> = 0...100) -> Double? {
        guard let d = double(v), range.contains(d) else { return nil }
        return d
    }
    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func isoDate(_ v: Any?) -> Date? {
        guard let s = string(v) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    /// Quota-reset bound: integral Unix seconds 0...4102444800 (year 2100).
    static let quotaResetBound: ClosedRange<TimeInterval> = 0...4_102_444_800
    /// A valid quota reset timestamp — bounded, unlike auth expiries which may legitimately be far out.
    static func resetDate(_ v: Any?) -> Date? {
        guard let d = double(v), quotaResetBound.contains(d),
              d == d.rounded() else { return nil }
        return Date(timeIntervalSince1970: d)
    }
    static func resetDateISO(_ v: Any?) -> Date? {
        guard let date = isoDate(v),
              quotaResetBound.contains(date.timeIntervalSince1970) else { return nil }
        return date
    }
    /// Auth expiry may legitimately be much later than the quota bound.
    static func expiryDate(_ v: Any?) -> Date? { isoDate(v) }

    /// A JWT's `exp` claim as a Date — only when the token has three dot-separated
    /// segments and its middle segment base64url-decodes to a JSON object with a
    /// numeric `exp`. Any other shape decodes to nil; the token is never logged.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let payload = object(data),
              let exp = double(payload["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
