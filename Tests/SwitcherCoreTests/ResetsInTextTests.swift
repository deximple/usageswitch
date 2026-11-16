import Foundation
import SwitcherCore
import Testing

@Suite("Resets-in text")
struct ResetsInTextTests {
    private let now = Date(timeIntervalSince1970: 1_794_584_700)

    @Test func aResetWithinTheMinuteNeverReadsResetsInNow() {
        #expect(UsageText.resetsIn(now.addingTimeInterval(30), now: now) == L10n.t(.usageResetsSoon))
        #expect(UsageText.resetsIn(now.addingTimeInterval(-5), now: now) == L10n.t(.usageResetsSoon))
    }

    @Test func aLaterResetCarriesTheCountdown() {
        let reset = now.addingTimeInterval(2 * 3600 + 5 * 60)
        #expect(UsageText.resetsIn(reset, now: now)
            == L10n.t(.usageResetsIn, UsageText.countdown(to: reset, from: now)))
    }

    @Test func aResetThatCannotBeCountedHasNoText() {
        #expect(UsageText.resetsIn(Date(timeIntervalSince1970: .infinity), now: now) == nil)
    }
}
