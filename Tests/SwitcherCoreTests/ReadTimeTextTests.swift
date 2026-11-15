import Foundation
import SwitcherCore
import Testing

@Suite("Read time text")
struct ReadTimeTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-11-13 15:45 UTC.
    private let read = Date(timeIntervalSince1970: 1_794_584_700)

    @Test func theClockFollowsTheAppLanguageNotTheSystemLocale() {
        let now = read.addingTimeInterval(600)
        let korean = UsageText.readTime(read, now: now, language: .ko, calendar: calendar)
        let english = UsageText.readTime(read, now: now, language: .en, calendar: calendar)
        #expect(korean.contains("오후") && korean.contains("3:45"))
        #expect(english.contains("PM") && english.contains("3:45"))
    }

    @Test func aReadingFromTodayShowsNoDate() {
        let text = UsageText.readTime(read, now: read.addingTimeInterval(600), language: .en, calendar: calendar)
        #expect(!text.contains("Nov"))
    }

    @Test func aReadingFromAnEarlierDayCarriesItsDate() {
        // Without the date, yesterday's figure reads as today's.
        let nextDay = read.addingTimeInterval(86_400)
        let english = UsageText.readTime(read, now: nextDay, language: .en, calendar: calendar)
        let korean = UsageText.readTime(read, now: nextDay, language: .ko, calendar: calendar)
        #expect(english.contains("Nov 13") && english.contains("3:45"))
        #expect(korean.contains("11월 13일") && korean.contains("3:45"))
    }
}
