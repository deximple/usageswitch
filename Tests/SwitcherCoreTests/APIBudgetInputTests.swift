import Foundation
import Testing
@testable import SwitcherCore

/// The budget row's input (2.5.0 audit D2-U-07): what counts as an amount and a reset day, how a
/// saved amount reads back, and which kind a vendor starts on.
@Suite("API budget input")
struct APIBudgetInputTests {
    @Test(arguments: [
        ("20", 20.0), ("12.50", 12.5), ("12,50", 12.5), ("12,5", 12.5), (" 30 ", 30.0),
        ("$20", 20.0), ("$ 20", 20.0), ("1,000", 1000.0), ("1,000.50", 1000.5), ("0", 0.0),
        // Three digits after a comma group thousands: dollars have two decimals.
        ("12,500", 12500.0), (".5", 0.5), ("5.", 5.0), ("100000000", 100_000_000.0),
        // Kept to the cent, so what the field shows back is what was saved.
        ("12.346", 12.35),
    ])
    func acceptedAmounts(text: String, value: Double) {
        #expect(APIBudgetInput.amount(text) == value, "\(text)")
    }

    /// Nothing that would be saved silently wrong, or crash a later sum: empty, negative, not a
    /// number, written as an exponent, or beyond any real budget.
    @Test(arguments: ["", " ", "-5", "abc", "12a", "1e300", "inf", "nan", "1,2,3", "1.2.3", "100000001"])
    func refusedAmounts(text: String) {
        #expect(APIBudgetInput.amount(text) == nil, "\(text)")
    }

    @Test func resetDays() {
        #expect(APIBudgetInput.resetDay("1") == 1)
        #expect(APIBudgetInput.resetDay(" 31 ") == 31)
        for bad in ["0", "32", "", "1.5", "-1", "x"] {
            #expect(APIBudgetInput.resetDay(bad) == nil, "\(bad)")
        }
    }

    @Test("a saved amount reads back as it was typed, not as 20.0")
    func savedAmountText() {
        #expect(APIBudgetInput.text(20) == "20")
        #expect(APIBudgetInput.text(12.5) == "12.5")
        #expect(APIBudgetInput.text(12.25) == "12.25")
        #expect(APIBudgetInput.amount(APIBudgetInput.text(1234.5)) == 1234.5)
    }

    /// Anthropic's billing read is summed by calendar month, so only a monthly quota from day 1 is
    /// counted against it: that is where its row starts. OpenAI counts the local logs, where a
    /// prepaid balance works.
    @Test func eachVendorStartsOnAKindItCanCount() {
        #expect(APIBudgetInput.defaultKind(for: .anthropic) == .quota)
        #expect(APIBudgetInput.defaultKind(for: .openai) == .balance)
    }
}
