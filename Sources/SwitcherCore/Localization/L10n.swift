import Foundation

/// String lookup for the five shipped languages. The current language is process-wide (app and CLI each
/// set it once from the saved settings); lookups fall back to English, then to the key itself.
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: AppLanguage = AppLanguage.system()

    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// Localized string for `key` in the current language, formatted with `args` (printf-style).
    public static func t(_ key: L10nKey, _ args: CVarArg...) -> String {
        string(key, language: language, args)
    }

    public static func string(_ key: L10nKey, language: AppLanguage, _ args: [CVarArg] = []) -> String {
        let format = table(for: language)[key] ?? Strings.en[key] ?? key.rawValue
        guard !args.isEmpty else { return format }
        // No locale: numbers are pids, seconds and sizes, never grouped ("4,321").
        return String(format: format, arguments: args)
    }

    public static func table(for language: AppLanguage) -> [L10nKey: String] {
        switch language {
        case .ko: return Strings.ko
        case .zhHans: return Strings.zhHans
        case .ja: return Strings.ja
        case .en: return Strings.en
        case .es: return Strings.es
        }
    }
}

/// Namespace for the per-language tables (one file per language).
public enum Strings {}
