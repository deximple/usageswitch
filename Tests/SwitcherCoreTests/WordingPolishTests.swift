import Foundation
import Testing
@testable import SwitcherCore

/// The 2.5.0 audit's wording items (H-14, H-15, H-18, H-22, H-24) and the catalog date, held per
/// language through the tables, without touching the process-wide `L10n.language`.
@Suite("Wording polish")
struct WordingPolishTests {
    private static func table(_ language: AppLanguage) -> [(L10nKey, String)] {
        L10nKey.allCases.compactMap { key in L10n.table(for: language)[key].map { (key, $0) } }
    }

    // MARK: - H-14 a refusal is told by its reason, not under a header that doesn't fit it

    @Test("an unreadable process table refuses the switch with its reason alone")
    func processTableRefusalHasNoSwapHeader() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.tableUnreadable = true }
        let error = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
        #expect(error?.description == L10n.t(.reasonProcessListUnreadable))
        #expect(error?.code == "swap_failed")   // the CLI's code stays
    }

    @Test("setting the switch record aside while Claude runs is refused with its reason alone")
    func setAsideRefusalHasNoSwapHeader() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        try rig.sandbox.write("{bad json", to: rig.env.journalFile)
        rig.world.update { $0.tableUnreadable = true }
        let error = switcherError { _ = try rig.switcher.setAsidePendingJournal() }
        #expect(error?.description == L10n.t(.reasonSetAsideWhileRunning))
    }

    @Test("a LaunchAgent that couldn't be paused is not a file operation")
    func relauncherRefusalHasNoFileHeader() {
        let reason = L10n.t(.reasonRelauncherUnverified, "com.example.agent.plist")
        let error = SwitcherError.relauncherBlocked(reason)
        #expect(error.description == reason)
        #expect(error.code == "io")
        // The Korean reason no longer calls the agent a file.
        #expect(!L10n.string(.reasonRelauncherUnverified, language: .ko, ["x"]).contains("파일"))
    }

    // MARK: - H-15 "resets in" inside a sentence is lower case

    @Test(arguments: [AppLanguage.en, .es])
    func resetClauseIsLowerCaseMidSentence(language: AppLanguage) throws {
        for key in [L10nKey.usageResetsInClause, .usageResetsSoonClause] {
            let text = L10n.string(key, language: language, ["2d"])
            let first = try #require(text.first)
            #expect(first.isLowercase, "\(language.rawValue) \(key.rawValue): \(text)")
        }
    }

    // MARK: - H-18 Korean particles attach to Latin words the same way everywhere

    /// "Claude 를" next to "Claude를": the particle is written straight after the word.
    @Test func koreanParticlesAttachToLatinWords() {
        let particle = #"[A-Za-z0-9)%@'’"”] (을|를|이|가|은|는|에서|에게|에|의|와|과|로|으로|도|만|나|이나)(?=[\s.,·)]|$)"#
        let regex = try! NSRegularExpression(pattern: particle)
        let spaced = Self.table(.ko).filter { _, text in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        #expect(spaced.isEmpty, "\(spaced.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "\n"))")
    }

    // MARK: - H-22 no translation is kept for a key nothing shows

    @Test func everyKeyIsUsedBySomeSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var sources = ""
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift"
            && !file.lastPathComponent.hasPrefix("Strings+") && file.lastPathComponent != "L10nKey.swift" {
            sources += try String(contentsOf: file, encoding: .utf8)
        }
        let unused = L10nKey.allCases.filter { key in
            sources.range(of: #"\.\#(String(describing: key))\b"#, options: .regularExpression) == nil
        }
        #expect(unused.isEmpty, "\(unused)")
    }

    // MARK: - H-24 Japanese and Chinese punctuation is full width next to their own script

    @Test(arguments: [AppLanguage.ja, .zhHans])
    func fullWidthPunctuationAfterCJK(language: AppLanguage) {
        // A half-width colon or bracket touching a CJK character, as in "サーバー: " or "(任意)".
        let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}]: |[\p{Han}\p{Hiragana}\p{Katakana}]\(|\)[\p{Han}\p{Hiragana}\p{Katakana}]|\([\p{Han}\p{Hiragana}\p{Katakana}]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let halfWidth = Self.table(language).filter { _, text in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        #expect(halfWidth.isEmpty, "\(halfWidth.map { "\($0.0.rawValue): \($0.1)" }.joined(separator: "\n"))")
    }

    /// macOS writes フォルダ and サーバ without the long-vowel mark; so does the rest of the table.
    @Test func japaneseUsesOneSpellingPerLoanword() {
        let texts = Self.table(.ja).map(\.1)
        #expect(!texts.contains { $0.contains("フォルダー") })
        #expect(!texts.contains { $0.contains("サーバー") })
    }

    @Test func chineseUsesOneDash() {
        #expect(!Self.table(.zhHans).contains { $0.1.contains("——") })
    }

    // MARK: - the model catalog's date

    @Test("the catalog date reads in the app's language")
    func catalogDate() {
        #expect(UsageText.catalogDate("2026-11-07", language: .en) == "Nov 7, 2026")
        #expect(UsageText.catalogDate("2026-11-07", language: .ko)?.contains("2026") == true)
        #expect(UsageText.catalogDate("2026-11-07", language: .ko)?.contains("11") == true)
        #expect(UsageText.catalogDate("not a date", language: .en) == nil)
        // The bundled catalog has one.
        let catalog = try? SuggestionCatalog.bundled()
        #expect(catalog.flatMap { UsageText.catalogDate($0.factsDate, language: .en) } != nil)
    }
}
