import Foundation

/// What the current readings say about the hours and days ahead: which limits are on course
/// to empty before they reset, and what the pick's long limit allows per day. Readings only —
/// the same fresh, readable accounts the engine admits; nothing is stored and nothing acts.
public enum SuggestionOutlook {
    public enum Basis: Equatable, Sendable {
        /// Two readings a few minutes apart (`UsagePace`).
        case recentPace
        /// The window's own average so far (`UsageForecast`).
        case windowAverage
    }

    /// One limit projected to empty before its reset.
    public struct RunOut: Equatable, Sendable {
        public let accountID: String
        public let windowKey: String
        public let at: Date
        public let basis: Basis

        public init(accountID: String, windowKey: String, at: Date, basis: Basis) {
            self.accountID = accountID
            self.windowKey = windowKey
            self.at = at
            self.basis = basis
        }
    }

    /// A long limit spread evenly over the days to its reset.
    public struct Budget: Equatable, Sendable {
        public let accountID: String
        public let windowKey: String
        public let percentPerDay: Double

        public init(accountID: String, windowKey: String, percentPerDay: Double) {
            self.accountID = accountID
            self.windowKey = windowKey
            self.percentPerDay = percentPerDay
        }
    }

    public static let maximumRunOuts = 3

    /// Each account's soonest projected run-out, soonest first. A measured pace is used before
    /// the window's average. Limits already at the warning level are left to the attention
    /// list, and a spent limit is out, not running out.
    public static func runOuts(usages: [AccountUsage], pace: [String: UsagePace.Reading],
                               now: Date,
                               warnThreshold: Double = SuggestionEngine.defaultWarnThreshold
    ) -> [RunOut] {
        // The same bounds the engine holds the warning level to; anything else forecasts nothing.
        guard warnThreshold.isFinite, (50...99).contains(warnThreshold) else { return [] }
        let perAccount = usages.compactMap { usage -> RunOut? in
            guard usage.state == .ok,
                  (0...SuggestionEngine.maximumReadingAge).contains(now.timeIntervalSince(usage.readAt))
            else { return nil }
            return usage.windows.compactMap { window -> RunOut? in
                guard window.usedPercent.isFinite, (0..<warnThreshold).contains(window.usedPercent),
                      !window.isStale(now: now) else { return nil }
                let key = UsagePriority.key(usage, window)
                if let at = UsagePace.runsOutEarly(pace[key] ?? .unknown, window: window) {
                    return RunOut(accountID: usage.id, windowKey: key, at: at, basis: .recentPace)
                }
                guard let at = UsageForecast.projection(window, now: now)?.runsOutAt else { return nil }
                return RunOut(accountID: usage.id, windowKey: key, at: at, basis: .windowAverage)
            }
            .filter { $0.at.timeIntervalSince(now) >= 60 }
            .min { $0.at != $1.at ? $0.at < $1.at : $0.windowKey < $1.windowKey }
        }
        return Array(perAccount
            .sorted { $0.at != $1.at ? $0.at < $1.at : $0.accountID < $1.accountID }
            .prefix(maximumRunOuts))
    }

    /// The pick's limiting window as a daily allowance — weekly and monthly limits only.
    public static func budget(for option: SuggestionReport.Option?, usages: [AccountUsage],
                              now: Date) -> Budget? {
        guard let option, let usage = usages.first(where: { $0.id == option.accountID }),
              let window = usage.windows.first(where: {
                  UsagePriority.key(usage, $0) == option.limitingWindowKey
              }),
              window.kind == .weekly || window.kind == .monthly,
              let perDay = UsageForecast.dailyBudget(window, now: now) else { return nil }
        return Budget(accountID: usage.id, windowKey: option.limitingWindowKey, percentPerDay: perDay)
    }
}
