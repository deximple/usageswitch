import Foundation

/// Why a fresh, readable account carries no candidate right now.
public enum SuggestionExclusion: Equatable, Sendable {
    /// A limit the candidate would spend is at or past the warning level.
    case overWarnThreshold
    /// At the measured pace a limit runs out before its own reset.
    case runsOutEarly(at: Date)
    /// A limit's number can't be trusted: out of range, or its reset has already passed.
    case invalidWindow
}

/// The engine's pick together with what it was weighed against — the Guide's "why".
/// Like the pick itself it is a reading only; nothing acts on it.
public struct SuggestionReport: Equatable, Sendable {
    /// One account's best candidate.
    public struct Option: Equatable, Sendable {
        public let accountID: String
        public let provider: UsageProvider
        public let modelKey: String
        public let effort: String?
        public let situation: SituationCode
        public let limitingWindowKey: String
        /// The share (0…1) the ranking used: the limiting window's remaining share, plus —
        /// for a limit about to reset — the part that would lapse unused.
        public let remainingShare: Double
        /// The long limit that resets soon with room to spare (the first, when several do).
        public let expiringWindowKey: String?

        public init(accountID: String, provider: UsageProvider, modelKey: String, effort: String?,
                    situation: SituationCode, limitingWindowKey: String, remainingShare: Double,
                    expiringWindowKey: String? = nil) {
            self.accountID = accountID
            self.provider = provider
            self.modelKey = modelKey
            self.effort = effort
            self.situation = situation
            self.limitingWindowKey = limitingWindowKey
            self.remainingShare = remainingShare
            self.expiringWindowKey = expiringWindowKey
        }
    }

    /// An account that mapped to the catalog but has no candidate, and the limit in its way.
    public struct Excluded: Equatable, Sendable {
        public let accountID: String
        public let provider: UsageProvider
        public let reason: SuggestionExclusion
        public let windowKey: String
        /// When the blocking limit resets; nil when the reading doesn't say.
        public let unblocksAt: Date?

        public init(accountID: String, provider: UsageProvider, reason: SuggestionExclusion,
                    windowKey: String, unblocksAt: Date?) {
            self.accountID = accountID
            self.provider = provider
            self.reason = reason
            self.windowKey = windowKey
            self.unblocksAt = unblocksAt
        }
    }

    public let result: SuggestionResult
    /// Each account's best candidate, best first; the first one is `result`'s pick.
    public let options: [Option]
    /// Accounts with no candidate, in the order the readings were given.
    public let excluded: [Excluded]

    public init(result: SuggestionResult, options: [Option] = [], excluded: [Excluded] = []) {
        self.result = result
        self.options = options
        self.excluded = excluded
    }

    /// The left-out account whose blocking limit resets first; nil when none says when.
    public var earliestUnblock: Excluded? {
        excluded.filter { $0.unblocksAt != nil }.min {
            $0.unblocksAt! != $1.unblocksAt! ? $0.unblocksAt! < $1.unblocksAt!
                : $0.accountID < $1.accountID
        }
    }
}
