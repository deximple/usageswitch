import Foundation

/// Languages the app ships with. `zh-Hans` covers Chinese; other Chinese variants fall back to it.
public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case ko
    case zhHans = "zh-Hans"
    case ja
    case en
    case es

    public var id: String { rawValue }

    /// Name shown in the language menu, always in the language itself.
    public var nativeName: String {
        switch self {
        case .ko: return "한국어"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .en: return "English"
        case .es: return "Español"
        }
    }

    /// Maps a BCP-47 identifier such as "ko-KR", "zh-Hans-CN", "es-419" to a supported language.
    public static func matching(_ identifier: String) -> AppLanguage? {
        let lower = identifier.lowercased()
        if lower.hasPrefix("zh") { return .zhHans }
        let base = String(lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        return AppLanguage(rawValue: base)
    }

    /// First supported language in the user's preferred list, else English.
    public static func system(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        preferred.lazy.compactMap(matching).first ?? .en
    }
}

/// User settings kept in the switcher store (shared by the app and the CLI). Missing values mean the defaults,
/// so older files keep working.
public struct SwitcherSettings: Codable, Equatable, Sendable {
    /// nil = follow the system language.
    public var language: AppLanguage?
    /// Show the active account's name next to the menu bar icon (default on).
    public var menuBarShowsName: Bool?
    /// Show emails unmasked everywhere in the app (default off: masked until clicked).
    public var showEmails: Bool?
    /// Priority-view window keys the user pinned (default none).
    public var usagePins: [String]?
    /// Show the most constrained usage window in the menu bar (default on).
    public var menuBarShowsUsage: Bool?
    /// Allow reading Cursor's sign-in for its usage (default off: no Keychain read, no request).
    public var cursorUsageEnabled: Bool?

    public init(language: AppLanguage? = nil, menuBarShowsName: Bool? = nil, showEmails: Bool? = nil,
                usagePins: [String]? = nil, menuBarShowsUsage: Bool? = nil, cursorUsageEnabled: Bool? = nil) {
        self.language = language
        self.menuBarShowsName = menuBarShowsName
        self.showEmails = showEmails
        self.usagePins = usagePins
        self.menuBarShowsUsage = menuBarShowsUsage
        self.cursorUsageEnabled = cursorUsageEnabled
    }

    /// The saved settings; the defaults when there are none or the file can't be read.
    public static func load(env: SwitcherEnvironment) -> SwitcherSettings {
        LockedStoreFile.load(env.settingsFile, as: SwitcherSettings.self, empty: SwitcherSettings()) ?? SwitcherSettings()
    }

    /// Changes some settings and keeps the others (read-modify-write under a lock, shared with the CLI). An unreadable
    /// settings file is set aside (`settings.json.unreadable-<time>`) and the settings start over, so saving never
    /// gets stuck on it.
    public static func update(env: SwitcherEnvironment, fs: SafeFS, _ change: (inout SwitcherSettings) throws -> Void) throws {
        try LockedStoreFile.update(env.settingsFile, lock: env.settingsLockFile, env: env, fs: fs, empty: SwitcherSettings(),
                                   isEmpty: { _ in false }, setAsideUnreadable: true, change)
    }

    /// The language to use: the saved choice, else the system language.
    public var effectiveLanguage: AppLanguage { language ?? AppLanguage.system() }
    public var effectiveMenuBarShowsName: Bool { menuBarShowsName ?? true }
    public var effectiveShowEmails: Bool { showEmails ?? false }
    public var effectiveUsagePins: [String] { usagePins ?? [] }
    public var effectiveMenuBarShowsUsage: Bool { menuBarShowsUsage ?? true }
    public var effectiveCursorUsageEnabled: Bool { cursorUsageEnabled ?? false }
}
