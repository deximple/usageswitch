import Foundation

/// Emails are masked wherever they may be on screen (the app, its menu bar title, warnings) unless revealed.
public enum Privacy {
    /// `alex.kim.2026@example.com` → `al••••••026@example.com`; short local parts are fully masked.
    public static func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = email[..<at]
        guard local.count > 5 else { return String(repeating: "•", count: local.count) + email[at...] }
        return local.prefix(2) + String(repeating: "•", count: local.count - 5) + local.suffix(3) + email[at...]
    }

    /// Unicode-script local part not preceded by a mask bullet (so already masked text is left alone), then a
    /// domain.
    private static let emailPattern = try? NSRegularExpression(
        pattern: #"(?<![•\p{L}\p{M}\p{N}._%+-])[•\p{L}\p{M}\p{N}._%+-]+@[\p{L}\p{M}\p{N}-]+(?:\.[\p{L}\p{M}\p{N}-]+)+"#)

    /// Masks every email address inside free text (labels, error messages, banners, confirmation texts);
    /// an "@" that isn't part of an address ("Work @ Acme") is left alone.
    public static func maskEmails(in text: String) -> String {
        guard let emailPattern, text.contains("@") else { return text }
        // Composed first, so a decomposed accent can't split an address and leave letters outside the mask.
        var out = text.precomposedStringWithCanonicalMapping
        let matches = emailPattern.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let found = String(out[range])
            guard let at = found.firstIndex(of: "@"), !isMaskShape(found[..<at]) else { continue }
            out.replaceSubrange(range, with: maskedShape(found))
        }
        return out
    }

    /// The local part `maskEmail` leaves: all bullets, or two letters, bullets and three letters.
    static func isMaskShape(_ local: Substring) -> Bool {
        guard local.contains("•") else { return false }
        if local.allSatisfy({ $0 == "•" }) { return true }
        guard local.count > 5 else { return false }
        let middle = local.dropFirst(2).dropLast(3)
        return !local.prefix(2).contains("•") && !local.suffix(3).contains("•") && middle.allSatisfy { $0 == "•" }
    }

    /// `maskEmail`, fully bulleted when bullets already in the address would leave something that isn't a mask.
    private static func maskedShape(_ email: String) -> String {
        let masked = maskEmail(email)
        guard let at = masked.firstIndex(of: "@"), !isMaskShape(masked[..<at]) else { return masked }
        return String(repeating: "•", count: masked[..<at].count) + masked[at...]
    }
}
