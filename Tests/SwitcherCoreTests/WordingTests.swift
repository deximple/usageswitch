import Foundation
import Testing
@testable import SwitcherCore

/// The composed wording the audit's WordingRepro printed — asserted per language,
/// without touching the process-wide `L10n.language` (audit P3).
@Suite("Guide and footer wording")
struct WordingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var window: UsageWindow {
        UsageWindow(durationMinutes: 300, usedPercent: 20,
                    resetsAt: now.addingTimeInterval(7200))
    }

    @Test("headroom names the window, the share left, and the pace verdict")
    func headroom() {
        let name = UsageText.name(of: window)
        for language in AppLanguage.allCases {
            let line = L10n.string(.suggestionSituationHeadroom, language: language,
                                   [name, UsageText.percentLeft(window.usedPercent) ?? 0])
            #expect(!line.contains("% left remaining"))
            #expect(!line.contains("% 남음 남음"))
            #expect(!line.contains("(%@"))
            #expect(line.contains(name))
            #expect(line.contains("80"))   // 20% used → 80 left
        }
    }

    @Test("remaining line names the window and the share left")
    func remainingLine() {
        let name = UsageText.name(of: window)
        for language in AppLanguage.allCases {
            let line = L10n.string(.suggestionSituationRemaining, language: language,
                                   [name, UsageText.percentLeft(window.usedPercent) ?? 0])
            #expect(!line.contains("(%@") && line.contains(name) && line.contains("80"))
        }
    }

    @Test("the suggestion headline takes one pre-joined pick")
    func suggestionHeadline() {
        for language in AppLanguage.allCases {
            let line = L10n.string(.suggestionHeadline, language: language,
                                   ["Personal · Opus · High"])
            #expect(line.contains("Personal · Opus · High"))
            #expect(!line.contains("(%@"))
        }
    }

    @Test("the refreshing-soon string exists in every language")
    func refreshingSoon() {
        for language in AppLanguage.allCases {
            #expect(!L10n.string(.usageRefreshingSoon, language: language).isEmpty)
        }
    }

    @Test("one day reads singular in en and es")
    func apiDaySingular() {
        #expect(L10n.string(.apiDayLeft, language: .en, [1]) == "≈1 day left at this rate")
        #expect(L10n.string(.apiDayLeft, language: .es, [1]) == "≈1 día restante a este ritmo")
    }

    @Test("99.5%+ used is the used-up state, not '0% left'")
    func usedUp() {
        let spent = UsageWindow(durationMinutes: 300, usedPercent: 99.6,
                                resetsAt: now.addingTimeInterval(3600))
        #expect(UsageText.percentLeft(spent.usedPercent) == 0)
        #expect(UsageText.left(spent) == L10n.string(.usageUsedUp,
                                                   language: L10n.language))
        let kept = UsageWindow(durationMinutes: 300, usedPercent: 55,
                               resetsAt: now.addingTimeInterval(3600))
        #expect(UsageText.left(kept)
                == L10n.string(.usageLeft, language: L10n.language, [45]))
    }
}
