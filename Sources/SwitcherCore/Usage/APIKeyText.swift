import Foundation

/// How a stored API key is named on screen and to VoiceOver: only what the vault lists, never
/// key material.
public enum APIKeyText {
    /// "Anthropic · work · ••••1234". An entry whose label can't be read has no last four, so it
    /// is named by its vendor and the ID tail the vault put in `nickname`.
    public static func name(of entry: APIKeyEntry, language: AppLanguage = L10n.language) -> String {
        parts(of: entry, language: language, maskedTail: true).joined(separator: " · ")
    }

    /// The question asked before a key is deleted: the Keychain item can't be brought back.
    public static func deleteConfirmation(for entry: APIKeyEntry,
                                          language: AppLanguage = L10n.language) -> (title: String, detail: String) {
        (L10n.string(.apiKeyDeleteTitle, language: language, [name(of: entry, language: language)]),
         L10n.string(.apiKeyDeleteConfirm, language: language))
    }

    public static func revealLabel(for entry: APIKeyEntry, language: AppLanguage = L10n.language) -> String {
        L10n.string(.apiKeyRevealAx, language: language, [spokenName(of: entry, language: language)])
    }

    public static func hideLabel(for entry: APIKeyEntry, language: AppLanguage = L10n.language) -> String {
        L10n.string(.apiKeyHideAx, language: language, [spokenName(of: entry, language: language)])
    }

    public static func deleteLabel(for entry: APIKeyEntry, language: AppLanguage = L10n.language) -> String {
        L10n.string(.apiKeyDeleteAx, language: language, [spokenName(of: entry, language: language)])
    }

    /// Without the bullets: VoiceOver would read each one out.
    private static func spokenName(of entry: APIKeyEntry, language: AppLanguage) -> String {
        parts(of: entry, language: language, maskedTail: false).joined(separator: ", ")
    }

    private static func parts(of entry: APIKeyEntry, language: AppLanguage, maskedTail: Bool) -> [String] {
        let vendor: L10nKey = switch entry.vendor {
        case .anthropic: .apiVendorAnthropic
        case .openai: .apiVendorOpenAI
        case .google: .apiVendorGoogle
        case .xai: .apiVendorXAI
        }
        let tail = entry.last4.isEmpty ? [] : [maskedTail ? "••••\(entry.last4)" : entry.last4]
        let admin = entry.isAdmin ? [L10n.string(.apiKeyAdminTag, language: language)] : []
        return [L10n.string(vendor, language: language), entry.nickname] + tail + admin
    }
}
