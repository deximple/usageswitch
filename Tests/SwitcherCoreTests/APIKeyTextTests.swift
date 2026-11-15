import Foundation
import Testing
@testable import SwitcherCore

@Suite("API key naming and the delete confirmation")
struct APIKeyTextTests {
    private func entry(_ vendor: APIVendor = .anthropic, nickname: String = "work", last4: String = "1234",
                       unreadable: Bool = false, admin: Bool = false) -> APIKeyEntry {
        APIKeyEntry(id: "\(vendor.rawValue):\(UUID().uuidString)", vendor: vendor, nickname: nickname,
                    last4: last4, createdAt: Date(timeIntervalSince1970: 0),
                    isUnreadable: unreadable, isAdmin: admin)
    }

    @Test func aKeyIsNamedByVendorNicknameAndLastFour() {
        #expect(APIKeyText.name(of: entry(), language: .en) == "Anthropic · work · ••••1234")
        #expect(APIKeyText.name(of: entry(.openai, nickname: "ci", last4: "abcd"), language: .ko)
                == "OpenAI · ci · ••••abcd")
    }

    @Test func anAdminKeyCarriesItsTag() {
        #expect(APIKeyText.name(of: entry(admin: true), language: .en) == "Anthropic · work · ••••1234 · admin")
    }

    /// An unreadable entry has no last four: only the vendor and the ID tail the vault put in `nickname`.
    @Test func anUnreadableKeyShowsOnlyWhatIsKnown() {
        let unreadable = entry(.openai, nickname: "3F2A", last4: "", unreadable: true)
        #expect(APIKeyText.name(of: unreadable, language: .en) == "OpenAI · 3F2A")
        #expect(!APIKeyText.name(of: unreadable, language: .en).contains("•"))
        // a readable entry that somehow has no last four is treated the same way
        #expect(APIKeyText.name(of: entry(last4: ""), language: .en) == "Anthropic · work")
    }

    @Test(arguments: AppLanguage.allCases)
    func theDeleteConfirmationNamesTheKey(language: AppLanguage) {
        for key in [entry(), entry(.xai, nickname: "3F2A", last4: "", unreadable: true), entry(admin: true)] {
            let confirmation = APIKeyText.deleteConfirmation(for: key, language: language)
            #expect(confirmation.title.contains(APIKeyText.name(of: key, language: language)),
                    "\(language.rawValue): \(confirmation.title)")
            #expect(!confirmation.detail.isEmpty)
            #expect(!confirmation.title.contains("%@") && !confirmation.detail.contains("%@"))
        }
    }

    /// VoiceOver reads the row's buttons one by one: each label names its own key, without the bullets.
    @Test(arguments: AppLanguage.allCases)
    func buttonLabelsTellTheKeysApart(language: AppLanguage) {
        let first = entry(nickname: "work", last4: "1234")
        let second = entry(nickname: "work", last4: "9876")
        let labels: [(APIKeyEntry, AppLanguage) -> String] = [
            APIKeyText.revealLabel, APIKeyText.hideLabel, APIKeyText.deleteLabel,
        ]
        for label in labels {
            #expect(label(first, language) != label(second, language))
            #expect(label(first, language).contains("Anthropic"))
            #expect(label(first, language).contains("work"))
            #expect(label(first, language).contains("1234"))
            #expect(!label(first, language).contains("•"))
        }
        #expect(Set(labels.map { $0(first, language) }).count == labels.count)
        let unreadable = entry(.google, nickname: "3F2A", last4: "", unreadable: true)
        #expect(APIKeyText.deleteLabel(for: unreadable, language: language).contains("3F2A"))
    }
}
