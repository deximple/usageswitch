import Foundation
import Testing
@testable import SwitcherCore

@Suite("Appearance setting")
struct AppAppearanceTests {
    @Test("legacy settings without an appearance field keep everything and mean system")
    func legacyMissing() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        try #"{"language":"ko","showEmails":true,"usageAlertsEnabled":true}"#
            .write(to: sb.env.settingsFile, atomically: true, encoding: .utf8)
        let settings = SwitcherSettings.load(env: sb.env)
        #expect(settings.effectiveAppearance == .system)
        #expect(settings.language == .ko)
        #expect(settings.showEmails == true)
        #expect(settings.usageAlertsEnabled == true)
    }

    @Test("an unknown appearance string decodes to system without resetting other settings")
    func unknown() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        try #"{"language":"ja","appearance":"neon","menuBarShowsName":false}"#
            .write(to: sb.env.settingsFile, atomically: true, encoding: .utf8)
        let settings = SwitcherSettings.load(env: sb.env)
        #expect(settings.effectiveAppearance == .system)
        #expect(settings.language == .ja)
        #expect(settings.menuBarShowsName == false)
    }

    @Test("light/dark/system round-trip; system is persisted as nil")
    func roundTrip() throws {
        var s = SwitcherSettings()
        s.appearance = "light"
        #expect(s.effectiveAppearance == .light)
        s.appearance = "dark"
        #expect(s.effectiveAppearance == .dark)
        s.appearance = nil
        #expect(s.effectiveAppearance == .system)
        let data = try JSONEncoder().encode(s)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"appearance\""))
        s.appearance = "light"
        let written = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(SwitcherSettings.self, from: written).effectiveAppearance == .light)
    }

    @Test("changing only appearance preserves the other settings fields")
    func updatePreserves() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) {
            $0.language = .es; $0.showEmails = true; $0.appearance = nil
        }
        try SwitcherSettings.update(env: sb.env, fs: sb.fs) { $0.appearance = "dark" }
        let loaded = SwitcherSettings.load(env: sb.env)
        #expect(loaded.effectiveAppearance == .dark)
        #expect(loaded.language == .es)
        #expect(loaded.showEmails == true)
    }

    @Test("a temporary launch override wins, unknown overrides are ignored")
    func resolve() {
        #expect(AppAppearance.resolve(override: "light", choice: .dark) == .light)
        #expect(AppAppearance.resolve(override: "dark", choice: .system) == .dark)
        #expect(AppAppearance.resolve(override: nil, choice: .light) == .light)
        #expect(AppAppearance.resolve(override: "sepia", choice: .dark) == .dark)
        #expect(AppAppearance.resolve(override: "", choice: .system) == .system)
    }
}
