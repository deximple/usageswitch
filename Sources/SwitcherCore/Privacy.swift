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

    /// Latin-script local part not preceded by a mask bullet (so already masked text is left alone), then a
    /// domain. Latin only, so neighbouring CJK or Hangul text is never swallowed into the address.
    private static let emailPattern = try? NSRegularExpression(
        pattern: #"(?<![•\p{Latin}0-9._%+-])[\p{Latin}0-9._%+-]+@[\p{Latin}0-9-]+(?:\.[\p{Latin}0-9-]+)+"#)

    /// Masks every email address inside free text (labels, error messages, banners, confirmation texts);
    /// an "@" that isn't part of an address ("Work @ Acme") is left alone.
    public static func maskEmails(in text: String) -> String {
        guard let emailPattern, text.contains("@") else { return text }
        var out = text
        let matches = emailPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: maskEmail(String(out[range])))
        }
        return out
    }
}
