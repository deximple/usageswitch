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
    /// Saved appearance choice: nil or unknown values mean system.
    public var appearance: String?
    /// Percent used at which a window counts as Running Out (and alerts fire; default 80).
    public var usageWarnPercent: Int?
    /// Post a notification when a window crosses the warn percent (default on).
    public var usageAlertsEnabled: Bool?
    /// Granted consent for the four new consent-required providers, stored as
    /// provider rawValues. Missing/unknown entries never grant anything; Cursor's
    /// consent stays solely in `cursorUsageEnabled`.
    public var usageConnections: [String]?
    /// Explicit per-saved-account grants for reading usage from official Claude CLI profiles.
    public var claudeUsageProfiles: [ClaudeProfileBinding]?
    /// Suggestion mode, absent in older settings files and defaulting to balanced.
    public var suggestionMode: SuggestionMode?
    /// Task preference from simple coding (0) to reasoning (1).
    public var suggestionTask: Double?
    /// Show the Guide-title dot when a candidate is available (default on).
    public var suggestionQuietSignal: Bool?
    /// Expiry for a confirmed urgent mode selection.
    public var suggestionUrgentUntil: Date?
    public var apiBudgetAnthropic: APIBudget?
    public var apiBudgetOpenAI: APIBudget?
    public var apiBudgetGoogle: APIBudget?
    public var apiBudgetXAI: APIBudget?
    public var apiKeyVaultAccessPolicy: APIKeyVaultAccessPolicy?

    public init(language: AppLanguage? = nil, menuBarShowsName: Bool? = nil, showEmails: Bool? = nil,
                usagePins: [String]? = nil, menuBarShowsUsage: Bool? = nil, cursorUsageEnabled: Bool? = nil, appearance: String? = nil,
                usageWarnPercent: Int? = nil, usageAlertsEnabled: Bool? = nil,
                usageConnections: [String]? = nil, claudeUsageProfiles: [ClaudeProfileBinding]? = nil,
                suggestionMode: SuggestionMode? = nil, suggestionTask: Double? = nil,
                suggestionQuietSignal: Bool? = nil, suggestionUrgentUntil: Date? = nil,
                apiBudgetAnthropic: APIBudget? = nil, apiBudgetOpenAI: APIBudget? = nil,
                apiBudgetGoogle: APIBudget? = nil, apiBudgetXAI: APIBudget? = nil,
                apiKeyVaultAccessPolicy: APIKeyVaultAccessPolicy? = nil) {
        self.language = language
        self.menuBarShowsName = menuBarShowsName
        self.showEmails = showEmails
        self.usagePins = usagePins
        self.menuBarShowsUsage = menuBarShowsUsage
        self.cursorUsageEnabled = cursorUsageEnabled
        self.appearance = appearance
        self.usageWarnPercent = usageWarnPercent
        self.usageAlertsEnabled = usageAlertsEnabled
        self.usageConnections = usageConnections
        self.claudeUsageProfiles = claudeUsageProfiles
        self.suggestionMode = suggestionMode
        self.suggestionTask = suggestionTask
        self.suggestionQuietSignal = suggestionQuietSignal
        self.suggestionUrgentUntil = suggestionUrgentUntil
        self.apiBudgetAnthropic = apiBudgetAnthropic
        self.apiBudgetOpenAI = apiBudgetOpenAI
        self.apiBudgetGoogle = apiBudgetGoogle
        self.apiBudgetXAI = apiBudgetXAI
        self.apiKeyVaultAccessPolicy = apiKeyVaultAccessPolicy
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
    /// Extra opt-in stored alongside `gemini` in `usageConnections` — granted only
    /// via the Gemini dialog that discloses the in-memory token refresh.
    public var geminiTokenRefreshAllowed: Bool {
        (usageConnections ?? []).contains("gemini.tokenRefresh")
    }

    /// The persisted `usageConnections` value for a consent set. Gemini's refresh
    /// opt-in rides along as a non-provider extra entry, so unrelated provider
    /// toggles must round-trip it through here or they silently drop it. A provider's
    /// disclosure marker is written with it.
    public static func usageConnectionsValue(providers: Set<UsageProvider>,
                                             geminiTokenRefresh: Bool) -> [String]? {
        var values = providers.map(\.rawValue) + providers.compactMap(\.disclosureMarker)
        if geminiTokenRefresh, providers.contains(.gemini) {
            values.append("gemini.tokenRefresh")
        }
        return values.isEmpty ? nil : values.sorted()
    }
    public var effectiveUsagePins: [String] {
        var seen = Set<String>()
        return (usagePins ?? []).compactMap { key in
            var k = key
            // Legacy Cursor scope names predate the dashboard pool rename.
            if k.hasPrefix("\(CursorUsageCollector.rowID)/") {
                if k.hasSuffix("/Auto") {
                    k = String(k.dropLast(4)) + CursorUsageParser.cursorModelsScope
                } else if k.hasSuffix("/API") {
                    k = String(k.dropLast(3)) + CursorUsageParser.otherModelsScope
                }
            }
            return seen.insert(k).inserted ? k : nil
        }
    }
    public var effectiveMenuBarShowsUsage: Bool { menuBarShowsUsage ?? true }
    public var effectiveCursorUsageEnabled: Bool { cursorUsageEnabled ?? false }
    /// Appearance stored as a raw string so unknown values decode to system without a migration.
    public var effectiveAppearance: AppAppearance { AppAppearance(rawValue: appearance ?? "") ?? .system }
    /// Kept to the sane range the settings menu offers; a hand-edited value outside it falls back.
    public var effectiveUsageWarnPercent: Int {
        guard let usageWarnPercent, (50...99).contains(usageWarnPercent) else { return 80 }
        return usageWarnPercent
    }
    public var effectiveUsageAlertsEnabled: Bool { usageAlertsEnabled ?? true }
    public var effectiveSuggestionMode: SuggestionMode { suggestionMode ?? .balanced }
    public var effectiveSuggestionTask: Double {
        guard let suggestionTask, suggestionTask.isFinite, (0...1).contains(suggestionTask) else {
            return 0.5
        }
        return suggestionTask
    }
    public var effectiveSuggestionQuietSignal: Bool { suggestionQuietSignal ?? true }
    public var effectiveAPIKeyVaultAccessPolicy: APIKeyVaultAccessPolicy {
        apiKeyVaultAccessPolicy ?? .standard
    }

    public func apiBudget(for vendor: APIVendor) -> APIBudget? {
        switch vendor {
        case .anthropic: apiBudgetAnthropic
        case .openai: apiBudgetOpenAI
        case .google: apiBudgetGoogle
        case .xai: apiBudgetXAI
        }
    }

    /// Invalid duplicate bindings never become grants. The settings writer also
    /// enforces these constraints when creating a binding.
    public var effectiveClaudeUsageProfiles: [ClaudeProfileBinding] {
        var accountIds = Set<String>()
        var profilePaths = Set<String>()
        return (claudeUsageProfiles ?? []).filter {
            guard !accountIds.contains($0.accountId), !profilePaths.contains($0.profilePath) else { return false }
            accountIds.insert($0.accountId)
            profilePaths.insert($0.profilePath)
            return true
        }
    }
}

public struct ClaudeProfileBinding: Codable, Equatable, Hashable, Sendable {
    public let accountId: String
    public let accountUuid: String
    public let orgUuid: String
    /// Canonical realpath of a user-selected Claude CLI profile directory.
    public let profilePath: String

    public init(accountId: String, accountUuid: String, orgUuid: String, profilePath: String) {
        self.accountId = accountId
        self.accountUuid = accountUuid
        self.orgUuid = orgUuid
        self.profilePath = profilePath
    }
}
