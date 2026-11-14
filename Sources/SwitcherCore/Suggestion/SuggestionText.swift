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
            if pick.situation == .expiringHeadroom,
               let expiring = pick.expiringWindowKey.flatMap({ self.window(usage, $0) }),
               let resetsAt = expiring.resetsAt {
                base = L10n.t(.suggestionSituationExpiring, UsageText.name(of: expiring),
                              UsageText.percentLeft(expiring.usedPercent) ?? 0,
                              UsageText.countdown(to: resetsAt, from: now))
            } else if pick.situation == .windowHeadroom {
                base = L10n.t(.suggestionSituationHeadroom, UsageText.name(of: window), left)
            } else {
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

    /// One forecast line and where its evidence comes from, so the view can tell a measured
    /// pace from an average.
    public struct OutlookLine: Equatable, Sendable {
        public let text: String
        public let basis: SuggestionOutlook.Basis
    }

    /// "Codex · Work — Weekly may run out in 1d 12h at its average pace so far · resets in 3d 12h".
    public static func outlookLines(_ runOuts: [SuggestionOutlook.RunOut], usages: [AccountUsage],
                                    now: Date, label: (AccountUsage) -> String) -> [OutlookLine] {
        runOuts.compactMap { runOut in
            guard let usage = usages.first(where: { $0.id == runOut.accountID }),
                  let window = window(usage, runOut.windowKey) else { return nil }
            let key: L10nKey = runOut.basis == .recentPace ? .suggestionOutlookRecent
                                                           : .suggestionOutlookAverage
            let account = "\(UsageText.providerName(usage.provider)) · \(label(usage))"
            return OutlookLine(
                text: L10n.t(key, account, UsageText.name(of: window),
                             UsageText.countdown(to: runOut.at, from: now))
                    + resetSuffix(window.resetsAt, now: now),
                basis: runOut.basis)
        }
    }

    /// "Codex · Work — mostly GPT-6 Astra · High lately · lighter option: GPT-6.1 Sol · High".
    public static func lighterLines(_ options: [SuggestionOutlook.Lighter], usages: [AccountUsage],
                                    catalog: SuggestionCatalog,
                                    label: (AccountUsage) -> String) -> [String] {
        let names = Dictionary(catalog.models.map { ($0.key, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        func combination(_ key: String, _ effort: String?) -> String? {
            guard let name = names[key] else { return nil }
            return effort == nil ? name : "\(name) · \(effortName(effort))"
        }
        return options.compactMap { option in
            guard let usage = usages.first(where: { $0.id == option.accountID }),
                  let current = combination(option.modelKey, option.effort),
                  let lighter = combination(option.lighterModelKey, option.lighterEffort)
            else { return nil }
            return L10n.t(.suggestionLighter,
                          "\(UsageText.providerName(usage.provider)) · \(label(usage))",
                          current, lighter)
        }
    }

    /// "Not ranked, but has room: Cursor · Cursor sign-in — Monthly 70% left · resets in 12d".
    public static func otherToolLines(_ tools: [SuggestionOutlook.OtherTool], usages: [AccountUsage],
                                      now: Date, label: (AccountUsage) -> String) -> [String] {
        tools.compactMap { tool in
            guard let usage = usages.first(where: { $0.id == tool.accountID }),
                  let window = window(usage, tool.windowKey) else { return nil }
            return L10n.t(.suggestionOtherTool,
                          "\(UsageText.providerName(usage.provider)) · \(label(usage))",
                          UsageText.name(of: window), UsageText.percentLeft(window.usedPercent) ?? 0)
                + resetSuffix(window.resetsAt, now: now)
        }
    }

    /// "About 15% a day lasts to the reset" — rounded down, and silent under a point a day.
    public static func budgetLine(_ budget: SuggestionOutlook.Budget?) -> String? {
        guard let budget, budget.percentPerDay.isFinite, budget.percentPerDay >= 1 else { return nil }
        return L10n.t(.suggestionBudget, Int(budget.percentPerDay.rounded(.down)))
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

    private static func window(_ usage: AccountUsage, _ key: String) -> UsageWindow? {
        usage.windows.first { UsagePriority.key(usage, $0) == key }
    }

    /// " · resets in 2d 4h"; nothing for an unknown reset or one under a minute away.
    private static func resetSuffix(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt.timeIntervalSince(now) >= 60 else { return "" }
        return " · " + L10n.t(.usageResetsIn, UsageText.countdown(to: resetsAt, from: now))
    }
}
