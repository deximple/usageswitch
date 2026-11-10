import Foundation

public enum APIVendor: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic, openai, google, xai

    public var id: String { rawValue }

    public var usageProvider: UsageProvider {
        switch self {
        case .anthropic: .claude
        case .openai: .codex
        case .google: .gemini
        case .xai: .grok
        }
    }

    public static func matching(_ provider: UsageProvider) -> APIVendor? {
        allCases.first { $0.usageProvider == provider }
    }

    /// Only OpenAI writes priced API-key usage to the local logs (audit B-07, D-5); other vendors'
    /// log entries are subscription traffic, so spend for them can't be estimated.
    public var hasLogReader: Bool { self == .openai }
}

public enum APIBudget: Codable, Equatable, Sendable {
    case balance(amountUSD: Double, asOf: Date, asOfDaySpentUSD: Double = 0)
    case quota(amountUSD: Double, resetDayOfMonth: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, amountUSD, asOf, asOfDaySpentUSD, resetDayOfMonth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let amount = try container.decode(Double.self, forKey: .amountUSD)
        switch try container.decode(String.self, forKey: .kind) {
        case "balance":
            self = .balance(amountUSD: amount, asOf: try container.decode(Date.self, forKey: .asOf),
                            asOfDaySpentUSD: try container.decodeIfPresent(
                                Double.self, forKey: .asOfDaySpentUSD) ?? 0)
        case "quota":
            self = .quota(amountUSD: amount,
                          resetDayOfMonth: try container.decode(Int.self, forKey: .resetDayOfMonth))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                    debugDescription: "Unknown API budget kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .balance(let amountUSD, let asOf, let asOfDaySpentUSD):
            try container.encode("balance", forKey: .kind)
            try container.encode(amountUSD, forKey: .amountUSD)
            try container.encode(asOf, forKey: .asOf)
            try container.encode(asOfDaySpentUSD, forKey: .asOfDaySpentUSD)
        case .quota(let amountUSD, let resetDayOfMonth):
            try container.encode("quota", forKey: .kind)
            try container.encode(amountUSD, forKey: .amountUSD)
            try container.encode(resetDayOfMonth, forKey: .resetDayOfMonth)
        }
    }

    public var amountUSD: Double {
        switch self {
        case .balance(let amount, _, _), .quota(let amount, _): amount
        }
    }
}

public enum APIKeyVaultAccessPolicy: String, Codable, CaseIterable, Sendable {
    case standard, strong
}

public struct APIKeyEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let vendor: APIVendor
    public let nickname: String
    public let last4: String
    public let createdAt: Date
    /// The stored label failed to decode; nickname carries the account ID tail and the entry
    /// stays deletable (audit B-06).
    public let isUnreadable: Bool

    public init(id: String, vendor: APIVendor, nickname: String, last4: String, createdAt: Date,
                isUnreadable: Bool = false) {
        self.id = id
        self.vendor = vendor
        self.nickname = nickname
        self.last4 = last4
        self.createdAt = createdAt
        self.isUnreadable = isUnreadable
    }
}

public protocol APIKeyVault: Sendable {
    func register(vendor: APIVendor, nickname: String, key: String) async throws -> APIKeyEntry
    func list() async throws -> [APIKeyEntry]
    func reveal(id: String) async throws -> String
    func delete(id: String) async throws
}

public struct APIKeyAccountKey: Hashable, Sendable {
    public let provider: UsageProvider
    public let accountKey: String

    public init(provider: UsageProvider, accountKey: String) {
        self.provider = provider
        self.accountKey = accountKey
    }
}

public struct APIDailySpend: Codable, Equatable, Sendable {
    public let day: String
    public let amountUSD: Double

    public init(day: String, amountUSD: Double) {
        self.day = day
        self.amountUSD = amountUSD
    }
}

public struct APIUsageEstimate: Equatable, Sendable {
    public let hasAPIKeyAccounts: Bool
    public let spendIsComplete: Bool
    public let spendLast7DaysUSD: Double?
    public let dailyRateUSD: Double?
    public let medianDailyRate14DaysUSD: Double?
    public let dailySpend: [APIDailySpend]
    /// No estimate yet because this vendor's logs are still being read (not because a price is unknown).
    public let isReadingLogs: Bool
    /// Only vendors with a log reader can estimate spend from local logs (audit B-07, D-5).
    public let isEstimable: Bool
    /// The first UTC day the stored usage is complete from, when known.
    public let coverageStartDay: String?

    public init(hasAPIKeyAccounts: Bool, spendIsComplete: Bool, spendLast7DaysUSD: Double?,
                dailyRateUSD: Double?, medianDailyRate14DaysUSD: Double?,
                dailySpend: [APIDailySpend], isReadingLogs: Bool = false,
                isEstimable: Bool = true, coverageStartDay: String? = nil) {
        self.isReadingLogs = isReadingLogs
        self.isEstimable = isEstimable
        self.coverageStartDay = coverageStartDay
        self.hasAPIKeyAccounts = hasAPIKeyAccounts
        self.spendIsComplete = spendIsComplete
        self.spendLast7DaysUSD = spendLast7DaysUSD
        self.dailyRateUSD = dailyRateUSD
        self.medianDailyRate14DaysUSD = medianDailyRate14DaysUSD
        self.dailySpend = dailySpend
    }
}

public enum APIUsageEstimator {
    /// - Parameters:
    ///   - incompleteAccounts: accounts whose logs still have unread bytes. A vendor with one of
    ///     them gets no spend figures: a partial sum would look like a complete one.
    ///   - coverageStartDay: the first day the stored usage is complete from, passed through for
    ///     `APIBudgetMath.remaining`.
    public static func estimate(records: [SuggestionLogUsage], apiKeyAccounts: Set<APIKeyAccountKey>,
                                catalog: SuggestionCatalog, now: Date,
                                incompleteAccounts: Set<APIKeyAccountKey> = [],
                                coverageStartDay: String? = nil) -> [APIVendor: APIUsageEstimate] {
        let today = SuggestionRetention.utcDay(now)
        let calendar = utcCalendar
        let startOfToday = calendar.startOfDay(for: now)
        let firstRecent = calendar.date(byAdding: .day, value: -13, to: startOfToday) ?? now
        let firstBudget = calendar.date(byAdding: .day, value: -34, to: startOfToday) ?? now
        let firstRecentDay = SuggestionRetention.utcDay(firstRecent)
        let firstBudgetDay = SuggestionRetention.utcDay(firstBudget)
        var result: [APIVendor: APIUsageEstimate] = [:]

        for vendor in APIVendor.allCases {
            let accounts = Set(apiKeyAccounts.filter { APIVendor.matching($0.provider) == vendor })
            let hasUnloggedAccounts = accounts.contains {
                $0.provider != .claude && $0.provider != .codex
            }
            let isReadingLogs = !accounts.isDisjoint(with: incompleteAccounts)
            var daily: [String: Double] = [:]
            var unknownBudgetPrice = hasUnloggedAccounts || isReadingLogs
            var unknownRecentPrice = hasUnloggedAccounts || isReadingLogs
            var unknownSevenDayPrice = hasUnloggedAccounts || isReadingLogs
            let firstSeven = SuggestionRetention.utcDay(
                calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? now)
            for record in records where record.day >= firstBudgetDay && record.day <= today
                && (record.provider == .claude || record.provider == .codex)
                && record.subscription != true
                && accounts.contains(APIKeyAccountKey(provider: record.provider, accountKey: record.accountRef)) {
                guard let cost = cost(of: record, catalog: catalog) else {
                    unknownBudgetPrice = true
                    if record.day >= firstRecentDay { unknownRecentPrice = true }
                    if record.day >= firstSeven { unknownSevenDayPrice = true }
                    continue
                }
                daily[record.day, default: 0] += cost
            }

            let days = (0..<14).compactMap { calendar.date(byAdding: .day, value: -$0, to: startOfToday) }
                .map(SuggestionRetention.utcDay)
            let values = days.map { daily[$0, default: 0] }
            let sevenDaySpend = days.prefix(7).reduce(0) { $0 + daily[$1, default: 0] }
            let sorted = values.sorted()
            let median = (sorted[6] + sorted[7]) / 2
            let sevenDayValue = unknownSevenDayPrice ? nil : sevenDaySpend
            // The rate divides by the days actually covered, not a flat 7: a fresh reader with
            // one day of records must not understate the daily spend by seven (audit B-07).
            let earliestDay = daily.keys.filter { $0 >= firstSeven }.min()
            let coveredDays = earliestDay
                .flatMap { dayFormatter.date(from: $0) }
                .flatMap { calendar.dateComponents([.day], from: $0, to: startOfToday).day }
                .map { min(7, max(1, $0 + 1)) } ?? 1
            result[vendor] = APIUsageEstimate(
                hasAPIKeyAccounts: !accounts.isEmpty,
                spendIsComplete: !unknownBudgetPrice,
                spendLast7DaysUSD: sevenDayValue,
                dailyRateUSD: sevenDayValue.map { $0 / Double(coveredDays) },
                medianDailyRate14DaysUSD: unknownRecentPrice ? nil : median,
                dailySpend: unknownBudgetPrice ? [] : daily.keys.sorted()
                    .map { APIDailySpend(day: $0, amountUSD: daily[$0] ?? 0) },
                isReadingLogs: isReadingLogs, isEstimable: vendor.hasLogReader,
                coverageStartDay: coverageStartDay)
        }
        return result
    }

    private static func cost(of record: SuggestionLogUsage, catalog: SuggestionCatalog) -> Double? {
        let model = catalog.models.first { $0.key == record.model || $0.model == record.model }
        let cachedCreation = record.cachedCreationTokens ?? 0
        let cached = record.cachedInputTokens
        let output = record.outputTokens
        guard record.inputTokens >= 0, cached >= 0, cachedCreation >= 0, output >= 0 else { return nil }
        let inputBase: Int64
        if record.provider == .codex {
            guard record.inputTokens >= cached else { return nil }
            inputBase = record.inputTokens - cached
        } else {
            inputBase = record.inputTokens
        }
        let (input, overflow) = inputBase.addingReportingOverflow(cachedCreation)
        guard !overflow else { return nil }
        if input == 0 && cached == 0 && output == 0 { return 0 }
        guard let model else { return nil }
        func price(_ code: String) -> Double? {
            model.values.first(where: { $0.code == code })?.number
        }
        let inputPrice = price("inputPricePerMTok")
        let cachedReadPrice = price("cachedReadPricePerMTok")
        let outputPrice = price("outputPricePerMTok")
        guard (input == 0 || inputPrice != nil),
              (cached == 0 || cachedReadPrice != nil),
              (output == 0 || outputPrice != nil) else { return nil }
        let inputCost: Double = Double(input) * (inputPrice ?? 0) / 1_000_000
        let cachedCost: Double = Double(cached) * (cachedReadPrice ?? 0) / 1_000_000
        let outputCost: Double = Double(output) * (outputPrice ?? 0) / 1_000_000
        let amount: Double = inputCost + cachedCost + outputCost
        return amount.isFinite && amount >= 0 ? amount : nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

public enum APIBudgetMath {
    public static func utcDay(_ date: Date) -> String {
        SuggestionRetention.utcDay(date)
    }

    /// - Parameter coverageStartDay: the first day `spending` is complete from. A budget that
    ///   started before it cannot be worked out, so the answer is nil.
    public static func remaining(_ budget: APIBudget, spending: [APIDailySpend], now: Date,
                                 coverageStartDay: String? = nil) -> Double? {
        let amount = budget.amountUSD
        guard amount.isFinite, amount >= 0,
              spending.allSatisfy({ $0.amountUSD.isFinite && $0.amountUSD >= 0 }) else { return nil }
        let firstDay: String
        let baselineDay: String?
        let baselineAmount: Double
        switch budget {
        case .balance(_, let asOf, let asOfDaySpentUSD):
            guard asOf <= now, asOfDaySpentUSD.isFinite, asOfDaySpentUSD >= 0 else { return nil }
            firstDay = SuggestionRetention.utcDay(asOf)
            let earliest = SuggestionRetention.utcDay(now.addingTimeInterval(-34 * 86_400))
            guard firstDay >= earliest else { return nil }
            baselineDay = firstDay
            baselineAmount = asOfDaySpentUSD
        case .quota(_, let resetDay):
            guard let start = monthlyCycleStart(resetDayOfMonth: resetDay, now: now) else { return nil }
            firstDay = SuggestionRetention.utcDay(start)
            baselineDay = nil
            baselineAmount = 0
        }
        if let coverageStartDay, coverageStartDay > firstDay { return nil }
        let today = SuggestionRetention.utcDay(now)
        let used = spending.filter { $0.day >= firstDay && $0.day <= today }
            .reduce(0.0) { total, daily in
                let amount = daily.day == baselineDay
                    ? max(0, daily.amountUSD - baselineAmount)
                    : daily.amountUSD
                return total + amount
            }
        guard used.isFinite else { return nil }
        return max(0, amount - used)
    }

    public static func monthlyCycleStart(resetDayOfMonth: Int, now: Date) -> Date? {
        guard (1...31).contains(resetDayOfMonth) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: components),
              let currentStart = date(day: resetDayOfMonth, inMonthContaining: monthStart, calendar: calendar)
        else { return nil }
        if now >= currentStart { return currentStart }
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthStart) else { return nil }
        return date(day: resetDayOfMonth, inMonthContaining: previousMonth, calendar: calendar)
    }

    public static func daysLeft(remainingUSD: Double, dailyRateUSD: Double?) -> Int? {
        guard remainingUSD.isFinite, remainingUSD >= 0,
              let dailyRateUSD, dailyRateUSD.isFinite, dailyRateUSD > 0 else { return nil }
        return Int(ceil(remainingUSD / dailyRateUSD))
    }

    public static func showUsageListBalance(usedPercent: Double, remainingUSD: Double?) -> Bool {
        usedPercent.isFinite && usedPercent >= 95
            && remainingUSD.map { $0.isFinite && $0 > 0 } == true
    }

    public static func showSubscriptionRoom(dailyRateUSD: Double?, medianDailyRateUSD: Double?,
                                            subscriptionWindows: [UsageWindow]) -> Bool {
        guard let dailyRateUSD, let medianDailyRateUSD,
              dailyRateUSD.isFinite, medianDailyRateUSD.isFinite,
              dailyRateUSD > medianDailyRateUSD, !subscriptionWindows.isEmpty else { return false }
        return subscriptionWindows.allSatisfy { $0.usedPercent.isFinite && $0.usedPercent < 50 }
    }

    private static func date(day: Int, inMonthContaining month: Date, calendar: Calendar) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return nil }
        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = min(day, range.count)
        return calendar.date(from: components)
    }
}
