import Foundation

/// Every user-visible line the Guide derives from a suggestion report, in one place so the
/// view only draws. Lines describe readings; none of them is an instruction the app acts on.
public enum SuggestionText {
    /// What the Guide says about one report.
    public struct Explanation: Equatable, Sendable {
        /// The pick; nil when there is none.
        public let headline: String?
        /// How the pick's limiting window stands.
        public let situation: String?
        /// Every weighed account in rank order, the pick first.
        public let compared: [String]
        /// Accounts with no candidate, each with the limit in its way.
        public let leftOut: [String]
        /// Why there is no pick; empty when there is one, or when another view explains it.
        public let empty: [String]
    }

    /// The comparison and the left-out list stop here — the Guide stays a short read.
    public static let maximumLines = 4

    public static func explanation(for report: SuggestionReport, usages: [AccountUsage],
                                   catalog: SuggestionCatalog, now: Date,
                                   label: (AccountUsage) -> String,
                                   recentEffort: (AccountUsage) -> String? = { _ in nil }
    ) -> Explanation {
        let usageByID = Dictionary(usages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let modelNames = Dictionary(catalog.models.map { ($0.key, $0.name) },
                                    uniquingKeysWith: { first, _ in first })

        func account(_ usage: AccountUsage) -> String {
            "\(UsageText.providerName(usage.provider)) · \(label(usage))"
        }
        func window(_ usage: AccountUsage, _ key: String) -> UsageWindow? {
            usage.windows.first { UsagePriority.key(usage, $0) == key }
        }
        func model(_ option: SuggestionReport.Option) -> String? {
            guard let name = modelNames[option.modelKey] else { return nil }
            return option.effort == nil ? name : "\(name) · \(effortName(option.effort))"
        }

        let compared = report.options.prefix(maximumLines).compactMap { option -> String? in
            guard let usage = usageByID[option.accountID], let model = model(option),
                  let window = window(usage, option.limitingWindowKey) else { return nil }
            return L10n.t(.suggestionBasisOption, account(usage), model, UsageText.name(of: window),
                          UsageText.percentLeft(window.usedPercent) ?? 0)
                + resetSuffix(window.resetsAt, now: now)
        }
        let leftOut = report.excluded.prefix(maximumLines).compactMap { excluded -> String? in
            guard let usage = usageByID[excluded.accountID],
                  let window = window(usage, excluded.windowKey) else { return nil }
            let name = UsageText.name(of: window)
            switch excluded.reason {
            case .overWarnThreshold:
                return L10n.t(.suggestionLeftOutWarn, account(usage), name,
                              UsageText.percentLeft(window.usedPercent) ?? 0)
                    + resetSuffix(excluded.unblocksAt, now: now)
            case .runsOutEarly:
                return L10n.t(.suggestionLeftOutPace, account(usage), name)
            case .invalidWindow:
                return L10n.t(.suggestionLeftOutStale, account(usage), name)
            }
        }

        var headline: String?
        var situation: String?
        if let pick = report.options.first, let usage = usageByID[pick.accountID],
           let model = model(pick), let window = window(usage, pick.limitingWindowKey) {
            let parts = "\(account(usage)) · \(model)"
            if case .neutral = report.result {
                headline = L10n.t(.suggestionHeadlineNeutral, parts)
            } else {
                headline = L10n.t(.suggestionHeadline, parts)
            }
            let left = UsageText.percentLeft(window.usedPercent) ?? 0
            let base: String
            switch pick.situation {
            case .windowHeadroom:
                base = L10n.t(.suggestionSituationHeadroom, UsageText.name(of: window), left)
            case .remainingShare:
                base = L10n.t(.suggestionSituationRemaining, UsageText.name(of: window), left)
            }
            situation = base + (recentEffort(usage).map {
                L10n.t(.suggestionRecentEffort, effortName($0))
            } ?? "")
        }

        return Explanation(headline: headline, situation: situation, compared: compared,
                           leftOut: leftOut,
                           empty: emptyLines(report, usageByID: usageByID, account: account,
                                             window: window, now: now))
    }

    public static func effortName(_ effort: String?) -> String {
        switch effort {
        case "none": L10n.t(.suggestionEffortNone)
        case "minimal": L10n.t(.suggestionEffortMinimal)
        case "low": L10n.t(.suggestionEffortLow)
        case "medium": L10n.t(.suggestionEffortMedium)
        case "high": L10n.t(.suggestionEffortHigh)
        case "xhigh": L10n.t(.suggestionEffortXHigh)
        case "max": L10n.t(.suggestionEffortMax)
        default: L10n.t(.suggestionEffortUnspecified)
        }
    }

    /// Why nothing is picked. An unmapped provider (`noCatalogMatch`) and invalid inputs say
    /// nothing here — the Guide's plain account comparison covers the first.
    private static func emptyLines(_ report: SuggestionReport, usageByID: [String: AccountUsage],
                                   account: (AccountUsage) -> String,
                                   window: (AccountUsage, String) -> UsageWindow?,
                                   now: Date) -> [String] {
        switch report.result {
        case .none(.excluded):
            guard let first = report.earliestUnblock, let unblocksAt = first.unblocksAt,
                  unblocksAt.timeIntervalSince(now) >= 60,
                  let usage = usageByID[first.accountID],
                  let blocking = window(usage, first.windowKey) else {
                return [L10n.t(.suggestionNoneExcluded)]
            }
            return [L10n.t(.suggestionNoneExcluded),
                    L10n.t(.suggestionFreesFirst, account(usage), UsageText.name(of: blocking),
                           UsageText.countdown(to: unblocksAt, from: now))]
        case .none(.noCandidates):
            return [L10n.t(.suggestionNoneNoFit)]
        default:
            return []
        }
    }

    /// " · resets in 2d 4h"; nothing for an unknown reset or one under a minute away.
    private static func resetSuffix(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt.timeIntervalSince(now) >= 60 else { return "" }
        return " · " + L10n.t(.usageResetsIn, UsageText.countdown(to: resetsAt, from: now))
    }
}
