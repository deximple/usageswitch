import Foundation

/// The next-account candidate on the Usage tab's Guide view. Readings only — the app never
/// switches, opens or signs anything in on its own.
///
/// An account is comparable only when every *common* window it reports (scope == nil) is a
/// same-structure, same-length window the other candidates also report. Two accounts are only
/// ranked when their common-window structure signatures match exactly; different structures
/// are never compared.
public enum UsageGuidance {
    /// One suggested account, or the single neutral reading when only one account qualifies.
    public struct Proposal: Equatable, Sendable {
        /// `AccountUsage.id` of the candidate.
        public let usageID: String
        public let provider: UsageProvider
        /// The common window with the least remaining share — the one that binds first.
        public let window: UsageWindow
        /// Every common window the comparison used, sorted by duration then kind.
        public let windows: [UsageWindow]
        /// How many comparable accounts the candidate was ranked against (1 = neutral reading).
        public let comparedCount: Int
        /// The compared accounts report different plan names — percentages can't be read as
        /// equal amounts of work.
        public let plansDiffer: Bool

        /// A real comparison happened; with one account this is a neutral reading, not advice.
        public var isRecommendation: Bool { comparedCount > 1 }
    }

    /// A reading older than this never feeds a suggestion (and a future readAt is rejected too).
    public static let maximumAge: TimeInterval = 600

    /// The window-structure signature: sorted "kind:durationMinutes" of every common window.
    private static func signature(_ windows: [UsageWindow]) -> String {
        windows.map { "\($0.kind.rawValue):\($0.durationMinutes!)" }.sorted().joined(separator: "+")
    }

    /// Windows a comparison may use: common (unscoped), valid numbers, below the warn bar,
    /// a reset that hasn't passed (nil allowed), a known positive duration and a real kind —
    /// with no duplicate kind+duration inside the same account.
    private static func commonWindows(_ usage: AccountUsage, now: Date, warnAt: Double) -> [UsageWindow]? {
        let common = usage.windows.filter { $0.scope == nil }
        guard !common.isEmpty else { return nil }
        var seen = Set<String>()
        for window in common {
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  window.usedPercent < warnAt,
                  let duration = window.durationMinutes, duration > 0, window.kind != .other
            else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            guard seen.insert("\(window.kind.rawValue):\(duration)").inserted else { return nil }
        }
        return common
    }

    /// At most one proposal: the best remaining share inside the largest comparable group.
    /// `warnAt` outside 50…99 or non-finite fails closed — no suggestion over a bad threshold.
    public static func proposals(_ usages: [AccountUsage], now: Date,
                                 warnAt: Double = 80) -> [Proposal] {
        guard warnAt.isFinite, (50...99).contains(warnAt) else { return [] }

        let eligible = usages.compactMap { usage -> (usage: AccountUsage, windows: [UsageWindow], signature: String)? in
            guard usage.provider == .codex, usage.authentication == .subscription,
                  usage.state == .ok,
                  (0...maximumAge).contains(now.timeIntervalSince(usage.readAt)),
                  let common = commonWindows(usage, now: now, warnAt: warnAt)
            else { return nil }
            return (usage, common, signature(common))
        }
        guard !eligible.isEmpty else { return [] }

        if eligible.count == 1 {
            return [makeProposal(group: eligible.map(\.usage), pick: eligible[0].usage,
                                 comparedCount: 1)]
        }

        var groups: [String: [(usage: AccountUsage, windows: [UsageWindow])]] = [:]
        for entry in eligible { groups[entry.signature, default: []].append((entry.usage, entry.windows)) }
        // Largest comparable group wins; ties break on the lexically smallest signature.
        guard let group = groups.filter({ $0.value.count >= 2 })
            .sorted(by: { $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count : $0.key < $1.key })
            .first?.value
        else { return [] }

        let ranked = group.sorted { score($0.usage) != score($1.usage)
            ? score($0.usage) > score($1.usage) : $0.usage.id < $1.usage.id }
        return [makeProposal(group: ranked.map(\.usage), pick: ranked[0].usage,
                             comparedCount: ranked.count)]
    }

    /// Conservative comparison value: the smallest remaining share across common windows.
    private static func score(_ usage: AccountUsage) -> Double {
        usage.windows.filter { $0.scope == nil }.map { 100 - $0.usedPercent }.min() ?? 0
    }

    private static func makeProposal(group: [AccountUsage], pick: AccountUsage,
                                     comparedCount: Int) -> Proposal {
        let sorted = pick.windows.filter { $0.scope == nil }
            .sorted { $0.durationMinutes! != $1.durationMinutes!
                ? $0.durationMinutes! < $1.durationMinutes!
                : $0.kind.rawValue < $1.kind.rawValue }
        let limiting = sorted.min {
            (100 - $0.usedPercent) != (100 - $1.usedPercent)
                ? (100 - $0.usedPercent) < (100 - $1.usedPercent)
                : $0.durationMinutes! < $1.durationMinutes!
        } ?? sorted[0]
        return Proposal(usageID: pick.id, provider: pick.provider, window: limiting,
                        windows: sorted, comparedCount: comparedCount,
                        plansDiffer: Set(group.map { $0.plan }).count > 1)
    }
}
