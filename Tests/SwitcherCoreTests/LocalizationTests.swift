import Foundation
import Testing
@testable import SwitcherCore

@Suite("Localization")
struct LocalizationTests {
    /// Placeholders as (argument position, conversion), so `%@ … %d` and `%1$@ … %2$d` compare equal.
    static func placeholders(_ format: String) -> [String] {
        let regex = /%(?:(\d+)\$)?([@dDiuxXfgs%])/
        var next = 1
        var out: [String] = []
        for match in format.matches(of: regex) {
            let conversion = String(match.output.2)
            guard conversion != "%" else { continue }
            let position = match.output.1.flatMap { Int($0) } ?? next
            next = position + 1
            out.append("\(position):\(conversion)")
        }
        return out.sorted()
    }

    @Test(arguments: AppLanguage.allCases)
    func everyKeyIsTranslatedWithTheSamePlaceholders(language: AppLanguage) {
        let table = L10n.table(for: language)
        for key in L10nKey.allCases {
            guard let text = table[key] else { Issue.record("\(language.rawValue): missing \(key.rawValue)"); continue }
            #expect(!text.isEmpty, "\(language.rawValue): empty \(key.rawValue)")
            let english = Strings.en[key] ?? ""
            #expect(Self.placeholders(text) == Self.placeholders(english), "\(language.rawValue): \(key.rawValue)")
        }
        #expect(table.count == L10nKey.allCases.count)
    }

    @Test(arguments: AppLanguage.allCases)
    func formattingInsertsEveryArgument(language: AppLanguage) {
        let text = L10n.string(.uiResultSwitched, language: language, ["fake.21@example.com", 24])
        #expect(text.contains("fake.21@example.com") && text.contains("24"))
        // Numbers are pids and seconds: never grouped ("4,321").
        #expect(L10n.string(.reasonNotLaunchdChild, language: language, [4321]).contains("4321"))
        #expect(L10n.string(.errInsufficientDisk, language: language, [1, 8]).contains("8"))
    }

    @Test func keysAreUniqueAndDotted() {
        let raw = L10nKey.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        #expect(raw.allSatisfy { $0.contains(".") })
    }

    @Test(arguments: [
        ("ko-KR", AppLanguage.ko), ("ko", .ko), ("zh-Hans-CN", .zhHans), ("zh-Hant-TW", .zhHans), ("zh", .zhHans),
        ("ja_JP", .ja), ("en-GB", .en), ("es-419", .es), ("ES", .es),
    ])
    func matchingMapsRegionalIdentifiers(identifier: String, expected: AppLanguage) {
        #expect(AppLanguage.matching(identifier) == expected)
    }

    @Test func unsupportedLanguagesFallBack() {
        #expect(AppLanguage.matching("fr-FR") == nil)
        #expect(AppLanguage.matching("") == nil)
        #expect(AppLanguage.system(preferred: ["fr-FR", "ja-JP", "en-US"]) == .ja)
        #expect(AppLanguage.system(preferred: ["fr-FR", "de"]) == .en)
        #expect(AppLanguage.system(preferred: []) == .en)
    }

    @Test func nativeNamesAreDistinct() {
        #expect(Set(AppLanguage.allCases.map(\.nativeName)).count == AppLanguage.allCases.count)
    }

    @Test func settingsChangeOneValueAndKeepTheRest() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let defaults = SwitcherSettings.load(env: sb.env)
        #expect(defaults == SwitcherSettings())
        #expect(defaults.effectiveMenuBarShowsName && !defaults.effectiveShowEmails)

        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.language = .ja }
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.showEmails = true }
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.menuBarShowsName = false }
        let saved = SwitcherSettings.load(env: sb.env)
        #expect(saved.language == .ja && saved.effectiveLanguage == .ja)
        #expect(saved.effectiveShowEmails && !saved.effectiveMenuBarShowsName)
        #expect(posixPermissions(sb.env.settingsFile) == 0o600)
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.language = nil }   // back to the system language
        #expect(SwitcherSettings.load(env: sb.env) == SwitcherSettings(language: nil, menuBarShowsName: false, showEmails: true))
    }

    @Test func olderAndBrokenSettingsFiles() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        // A file from before the new settings: its language is kept and the new values use their defaults.
        try sb.write("{\"language\":\"ko\"}", to: sb.env.settingsFile)
        let older = SwitcherSettings.load(env: sb.env)
        #expect(older.language == .ko && older.effectiveMenuBarShowsName && !older.effectiveShowEmails)
        // An unknown language makes the file unreadable: defaults are used and the file is never overwritten.
        try sb.write("{\"language\":\"fr\"}", to: sb.env.settingsFile)
        #expect(SwitcherSettings.load(env: sb.env) == SwitcherSettings())
        try sb.write("{not json", to: sb.env.settingsFile)
        #expect(SwitcherSettings.load(env: sb.env) == SwitcherSettings())
        // Saving still works: the unreadable file is kept next to the new one, never silently lost.
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.showEmails = true }
        #expect(SwitcherSettings.load(env: sb.env) == SwitcherSettings(showEmails: true))
        let names = try FileManager.default.contentsOfDirectory(atPath: sb.env.storeDir.path)
        let aside = try #require(names.first { $0.hasPrefix("settings.json.unreadable-") })
        #expect(fileData(sb.env.storeDir.appendingPathComponent(aside)) == Data("{not json".utf8))
    }

    @Test func menuBarTitleFollowsBothSettings() {
        #expect(MenuBarTitle.make(label: "Work", showsName: true, showEmails: false) == "Work")
        #expect(MenuBarTitle.make(label: "Work", showsName: false, showEmails: false) == nil)
        #expect(MenuBarTitle.make(label: nil, showsName: true, showEmails: false) == nil)
        // Masked unless emails are always shown; long names are cut to 14 characters with "…".
        #expect(MenuBarTitle.make(label: "work@example.com", showsName: true, showEmails: false) == "••••@example.…")
        #expect(MenuBarTitle.make(label: "work@example.com", showsName: true, showEmails: true) == "work@example.…")
        #expect(MenuBarTitle.make(label: "Personal (x@y.io)", showsName: true, showEmails: false)?.contains("x@") == false)
    }

    @Test func liveStoreIsNamedAfterTheProductNotTheHostBundle() {
        #expect(SwitcherEnvironment.live().storeDir.lastPathComponent == ProductInfo.defaultBundleID)
        #expect(SwitcherEnvironment.live().legacyStoreDir.lastPathComponent == ProductInfo.legacyBundleID)
        #expect(SwitcherEnvironment.live().hasSeparateLegacyStore)
    }
}
