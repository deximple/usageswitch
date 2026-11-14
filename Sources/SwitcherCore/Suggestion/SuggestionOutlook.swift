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

    /// A draining account's most-used recent combination and a lighter one beside it.
    public struct Lighter: Equatable, Sendable {
        public let accountID: String
        public let modelKey: String
        public let effort: String?
        public let lighterModelKey: String
        public let lighterEffort: String?

        public init(accountID: String, modelKey: String, effort: String?,
                    lighterModelKey: String, lighterEffort: String?) {
            self.accountID = accountID
            self.modelKey = modelKey
            self.effort = effort
            self.lighterModelKey = lighterModelKey
            self.lighterEffort = lighterEffort
        }
    }

    /// An account the catalog can't rank that still has room on its tightest limit.
    public struct OtherTool: Equatable, Sendable {
        public let accountID: String
        public let windowKey: String
        public let remainingShare: Double

        public init(accountID: String, windowKey: String, remainingShare: Double) {
            self.accountID = accountID
            self.windowKey = windowKey
            self.remainingShare = remainingShare
        }
    }

    public static let maximumRunOuts = 3
    public static let maximumOtherTools = 2

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

    /// For each account on course to run out: what its logs say it mostly ran in the last
    /// day, and a lighter combination when the catalog has one. `hints` is keyed by account id.
    public static func lighterOptions(runOuts: [RunOut], hints: [String: SuggestionLogSummary.Hint],
                                      catalog: SuggestionCatalog, task: Double) -> [Lighter] {
        runOuts.compactMap { runOut in
            guard let hint = hints[runOut.accountID],
                  let lighter = SuggestionLighter.alternative(to: hint.model, effort: hint.effort,
                                                              catalog: catalog, task: task)
            else { return nil }
            return Lighter(accountID: runOut.accountID, modelKey: hint.model, effort: hint.effort,
                           lighterModelKey: lighter.modelKey, lighterEffort: lighter.effort)
        }
    }

    /// When the engine has no pick: fresh, readable accounts it can't rank (no catalog model,
    /// or no limit it can tie to one) whose plan-wide limits — every limit, for an account
    /// with only model-scoped ones — sit under the warning level and are not on course to
    /// run out before their reset. Roomiest first. No model or effort is claimed for them.
    public static func otherTools(report: SuggestionReport, usages: [AccountUsage],
                                  catalog: SuggestionCatalog,
                                  harnessMap: SuggestionHarnessMap = .standard,
                                  pace: [String: UsagePace.Reading], now: Date,
                                  warnThreshold: Double = SuggestionEngine.defaultWarnThreshold
    ) -> [OtherTool] {
        guard report.options.isEmpty, warnThreshold.isFinite, (50...99).contains(warnThreshold)
        else { return [] }
        let tools = usages.compactMap { usage -> OtherTool? in
            guard usage.state == .ok,
                  (0...SuggestionEngine.maximumReadingAge).contains(now.timeIntervalSince(usage.readAt)),
                  harnessMap.candidateModels(for: usage.provider, catalog: catalog).allSatisfy({
                      harnessMap.spentWindows(in: usage, for: $0).isEmpty
                  })
            else { return nil }
            let planWide = usage.windows.filter { $0.scope == nil }
            let windows = planWide.isEmpty ? usage.windows : planWide
            guard windows.allSatisfy({
                $0.usedPercent.isFinite && (0..<warnThreshold).contains($0.usedPercent)
                    && !$0.isStale(now: now)
                    && UsagePace.runsOutEarly(pace[UsagePriority.key(usage, $0)] ?? .unknown,
                                              window: $0) == nil
                    && UsageForecast.projection($0, now: now)?.runsOutAt == nil
            }), let tightest = windows.max(by: {
                $0.usedPercent != $1.usedPercent ? $0.usedPercent < $1.usedPercent
                    : UsagePriority.key(usage, $0) > UsagePriority.key(usage, $1)
            }) else { return nil }
            return OtherTool(accountID: usage.id, windowKey: UsagePriority.key(usage, tightest),
                             remainingShare: (100 - tightest.usedPercent) / 100)
        }
        return Array(tools.sorted {
            $0.remainingShare != $1.remainingShare ? $0.remainingShare > $1.remainingShare
                : $0.accountID < $1.accountID
        }.prefix(maximumOtherTools))
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
