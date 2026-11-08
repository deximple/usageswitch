import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion settings")
struct SuggestionSettingsTests {
    @Test("settings written before Suggestion S3 decode with the defaults")
    func backwardCompatibleDecode() throws {
        let data = Data(#"{"language":"ko"}"#.utf8)
        let settings = try JSONDecoder().decode(SwitcherSettings.self, from: data)
        #expect(settings.language == .ko)
        #expect(settings.suggestionMode == nil)
        #expect(settings.effectiveSuggestionMode == .balanced)
        #expect(settings.suggestionTask == nil)
        #expect(settings.effectiveSuggestionTask == 0.5)
        #expect(settings.suggestionQuietSignal == nil)
        #expect(settings.effectiveSuggestionQuietSignal)
        #expect(settings.suggestionUrgentUntil == nil)
    }

    @Test("urgent expires at the next five-hour Claude reset or after five hours")
    func urgentAutoRevert() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 60 * 60)
        let known = AccountUsage(
            id: "claude:current", provider: .claude, accountRef: "current",
            label: "Claude", plan: nil,
            windows: [UsageWindow(durationMinutes: 300, usedPercent: 20, resetsAt: reset)],
            state: .ok, readAt: now, toolVersion: nil)
        let unknown = AccountUsage(
            id: "claude:old", provider: .claude, accountRef: "old",
            label: "Claude", plan: nil,
            windows: [UsageWindow(durationMinutes: 10080, usedPercent: 20, resetsAt: reset)],
            state: .ok, readAt: now, toolVersion: nil)

        let knownExpiry = SuggestionMode.urgentExpiry(usages: [known, unknown], now: now)
        #expect(knownExpiry == reset)
        #expect(!SuggestionMode.urgentHasExpired(until: knownExpiry, now: now))
        #expect(SuggestionMode.urgentHasExpired(until: knownExpiry, now: reset))
        #expect(SuggestionMode.effectiveMode(.urgent, urgentUntil: knownExpiry, now: now) == .urgent)
        #expect(SuggestionMode.effectiveMode(.urgent, urgentUntil: knownExpiry, now: reset) == .balanced)

        let fallback = SuggestionMode.urgentExpiry(usages: [unknown], now: now)
        #expect(fallback == now.addingTimeInterval(5 * 60 * 60))
        #expect(SuggestionMode.urgentHasExpired(until: nil, now: now))
    }
}
