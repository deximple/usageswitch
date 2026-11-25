import Foundation

/// The two kinds of budget the API tab offers.
public enum APIBudgetKind: String, CaseIterable, Sendable {
    case balance, quota
}

/// What the budget row accepts. An amount is US dollars written as people write them: "20",
/// "12.50", "12,50", "$20", "1,000.50". Anything else is refused with a note instead of being
/// ignored, and nothing past a real budget is kept (a huge value would overflow later sums).
public enum APIBudgetInput {
    /// The largest amount the row keeps.
    public static let maximumAmount = 100_000_000.0

    public static func amount(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$") { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }),
              let number = normalized(trimmed),
              number.filter({ $0 == "." }).count <= 1,
              let value = Double(number), value.isFinite, value >= 0, value <= maximumAmount
        else { return nil }
        // Kept to the cent, so the field shows back exactly what was saved.
        return (value * 100).rounded() / 100
    }

    /// One comma before one or two digits is a decimal comma ("12,50"); otherwise commas must group
    /// thousands ("1,000", "12,500", "1,000.50") — dollars have two decimals, never three. nil for any
    /// other use of a comma.
    private static func normalized(_ text: String) -> String? {
        guard text.contains(",") else { return text }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        if !text.contains("."), parts.count == 2, !parts[0].isEmpty, (1...2).contains(parts[1].count) {
            return parts[0] + "." + parts[1]
        }
        let halves = text.split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let groups = halves[0].split(separator: ",", omittingEmptySubsequences: false)
        guard let first = groups.first, (1...3).contains(first.count),
              groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return groups.joined() + (halves.count == 2 ? "." + halves[1] : "")
    }

    /// A day of the month, 1 to 31.
    public static func resetDay(_ text: String) -> Int? {
        guard let day = Int(text.trimmingCharacters(in: .whitespaces)), (1...31).contains(day) else { return nil }
        return day
    }

    /// A saved amount as the field shows it again: "20", "12.5" — never "20.0".
    public static func text(_ amount: Double) -> String {
        guard amount.isFinite else { return "" }
        var text = String(format: "%.2f", amount)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The kind a vendor's row starts on before anything is saved: one its spend figure can count.
    /// Anthropic's billing read is summed by calendar month, so only a monthly quota from day 1 is
    /// worked out against it; OpenAI counts local logs, which a prepaid balance works with.
    public static func defaultKind(for vendor: APIVendor) -> APIBudgetKind {
        vendor.budgetBasis == .actualSpend ? .quota : .balance
    }
}
