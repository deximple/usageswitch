import Foundation
import Testing

@testable import SwitcherCore

@Suite("Compact quota countdown")
struct UsageCompactTextTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("days show d + nonzero h, hours show h + nonzero m, else m")
    func formats() {
        #expect(
            UsageText.compactCountdown(to: epoch + 2 * 86400 + 3 * 3600, from: epoch) == "2d 3h")
        #expect(UsageText.compactCountdown(to: epoch + 1 * 3600 + 12 * 60, from: epoch) == "1h 12m")
        #expect(UsageText.compactCountdown(to: epoch + 5 * 60, from: epoch) == "5m")
        #expect(UsageText.compactCountdown(to: epoch + 1 * 86400, from: epoch) == "1d")
        #expect(UsageText.compactCountdown(to: epoch + 1 * 3600, from: epoch) == "1h")
    }

    @Test("compact units use literal d/h/m")
    func localeInvariant() {
        // compact format uses no localized tokens — same output in every language
        #expect(UsageText.compactCountdown(to: epoch + 86400 + 3600, from: epoch) == "1d 1h")
    }

    @Test("past and sub-minute reads mean now")
    func now() {
        #expect(UsageText.compactCountdown(to: epoch - 60, from: epoch) == L10n.t(.usageNow))
        #expect(UsageText.compactCountdown(to: epoch + 30, from: epoch) == L10n.t(.usageNow))
    }

    @Test("non-finite or Int-overflowing intervals yield a dash, never a trap")
    func guards() {
        #expect(
            UsageText.compactCountdown(
                to: Date(timeIntervalSinceReferenceDate: .infinity),
                from: Date(timeIntervalSinceReferenceDate: 0)) == "—")
        #expect(
            UsageText.compactCountdown(
                to: Date(timeIntervalSinceReferenceDate: .nan),
                from: Date(timeIntervalSinceReferenceDate: 0)) == "—")
        #expect(
            UsageText.compactCountdown(
                to: Date(timeIntervalSinceReferenceDate: Double(Int.max).nextDown),
                from: Date(timeIntervalSinceReferenceDate: 0)) == "—")
    }
}

@Suite("Countdown overflow guards")
struct UsageCountdownGuardTests {
    private func d(_ s: Double) -> Date { Date(timeIntervalSinceReferenceDate: s) }
    @Test("wide countdown boundary and guard values")
    func wide() {
        #expect(UsageText.countdown(to: d(59), from: d(0)) == L10n.t(.usageNow))
        #expect(UsageText.countdown(to: d(60), from: d(0)) == L10n.t(.usageDurM, 1))
        #expect(UsageText.countdown(to: d(3599), from: d(0)) == L10n.t(.usageDurM, 59))
        #expect(UsageText.countdown(to: d(3600), from: d(0)) == L10n.t(.usageDurH, 1))
        #expect(UsageText.countdown(to: d(86399), from: d(0)) == L10n.t(.usageDurHM, 23, 59))
        #expect(UsageText.countdown(to: d(86400), from: d(0)) == L10n.t(.usageDurD, 1))
        #expect(UsageText.countdown(to: d(.infinity), from: d(0)) == "—")
        #expect(UsageText.countdown(to: d(.nan), from: d(0)) == "—")
        #expect(UsageText.countdown(to: d(.greatestFiniteMagnitude), from: d(0)) == "—")
        #expect(UsageText.countdown(to: d(Double(Int.max)), from: d(0)) == "—")
        #expect(UsageText.countdown(to: d(Double(Int.max).nextDown), from: d(0)) == "—")
        // >Int32-day span is finite but unrepresentable in the localized format
        #expect(UsageText.countdown(to: d(86400.0 * (Double(Int32.max) + 2)), from: d(0)) == "—")
        #expect(
            UsageText.countdown(to: d(-.greatestFiniteMagnitude), from: d(0))
                == L10n.t(.usageNow))
    }
}
