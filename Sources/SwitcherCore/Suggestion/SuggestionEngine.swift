import Foundation

public enum SuggestionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case saver, balanced, focus, urgent

    /// The next known five-hour Claude reset, or five hours from selection when none is known.
    public static func urgentExpiry(usages: [AccountUsage], now: Date) -> Date {
        let nextReset = usages.lazy
            .filter {
                $0.provider == .claude && $0.state == .ok
                    && (0...SuggestionEngine.maximumReadingAge).contains(now.timeIntervalSince($0.readAt))
            }
            .flatMap(\.windows)
            .filter { $0.durationMinutes == 300 }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
        return nextReset ?? now.addingTimeInterval(5 * 60 * 60)
    }

    public static func urgentHasExpired(until: Date?, now: Date) -> Bool {
        guard let until else { return true }
        return until <= now
    }

    public static func effectiveMode(_ mode: SuggestionMode, urgentUntil: Date?,
                                     now: Date) -> SuggestionMode {
        mode == .urgent && urgentHasExpired(until: urgentUntil, now: now) ? .balanced : mode
    }
}

public enum SituationCode: String, Codable, Equatable, Sendable {
    case windowHeadroom
    case remainingShare
    /// The longest limit resets soon with room to spare; what would lapse counts in its favour.
    case expiringHeadroom
}

public enum SuggestionNoneReason: Equatable, Sendable {
    case noCandidates
    case noCatalogMatch
    case excluded
    case invalidTask
    case invalidWarnThreshold
}

public enum SuggestionResult: Equatable, Sendable {
    case suggest(accountID: String, provider: UsageProvider, modelKey: String, effort: String?,
                 situation: SituationCode, limitingWindowKey: String)
    case neutral(accountID: String, provider: UsageProvider, modelKey: String, effort: String?,
                 situation: SituationCode, limitingWindowKey: String)
    case none(SuggestionNoneReason)
}

public enum SuggestionGuideFallback {
    public static func shouldShowLegacyProposal(for result: SuggestionResult) -> Bool {
        if case .none(.noCatalogMatch) = result { return true }
        return false
    }
}

/// Pure ranking over fresh usage readings and a pinned, validated catalog. It never
/// starts a tool, changes an account, or acts on the result.
public enum SuggestionEngine {
    public static let defaultWarnThreshold = 80.0
    public static let maximumReadingAge: TimeInterval = 600
    /// A limit is about to reset inside the last tenth of its length, and never more than a day out.
    public static let expiringShare = 0.1
    public static let expiringHorizon: TimeInterval = 86400
    /// Percent points that must still be unspent at the reset, at the limit's own average pace.
    public static let expiringLeftoverFloor = 10.0

    private struct Candidate {
        let usage: AccountUsage
        let modelKey: String
        let effort: String?
        let situation: SituationCode
        let limitingWindowKey: String
        let expiringWindowKey: String?
        let remaining: Double
        let score: Double
    }

    /// The limit that keeps one model's windows from carrying a candidate.
    private struct Block {
        let reason: SuggestionExclusion
        let windowKey: String
        let unblocksAt: Date?
    }

    public static func suggest(
        mode: SuggestionMode,
        task: Double,
        catalog: SuggestionCatalog,
        harnessMap: SuggestionHarnessMap = .standard,
        usages: [AccountUsage],
        pace: [String: UsagePace.Reading],
        now: Date,
        warnThreshold: Double = defaultWarnThreshold
    ) -> SuggestionResult {
        report(mode: mode, task: task, catalog: catalog, harnessMap: harnessMap, usages: usages,
               pace: pace, now: now, warnThreshold: warnThreshold).result
    }

    /// The pick plus every account it was weighed against and every account left out.
    public static func report(
        mode: SuggestionMode,
        task: Double,
        catalog: SuggestionCatalog,
        harnessMap: SuggestionHarnessMap = .standard,
        usages: [AccountUsage],
        pace: [String: UsagePace.Reading],
        now: Date,
        warnThreshold: Double = defaultWarnThreshold
    ) -> SuggestionReport {
        guard task.isFinite, (0...1).contains(task) else {
            return SuggestionReport(result: .none(.invalidTask))
        }
        guard warnThreshold.isFinite, (50...99).contains(warnThreshold) else {
            return SuggestionReport(result: .none(.invalidWarnThreshold))
        }

        var candidates: [Candidate] = []
        var blocks: [String: [Block]] = [:]
        var freshAccountMapsToCatalog = false
        for usage in usages {
            guard usage.state == .ok,
                  (0...maximumReadingAge).contains(now.timeIntervalSince(usage.readAt))
            else { continue }
            let mappedModels = harnessMap.candidateModels(for: usage.provider, catalog: catalog)
            freshAccountMapsToCatalog = freshAccountMapsToCatalog || !mappedModels.isEmpty
            for mapped in mappedModels {
                let entries = catalog.entries.filter {
                    $0.key == mapped.model.key
                        && permits($0, model: mapped.model, mode: mode)
                        && quality($0.rank, task: task) != nil
                }
                guard !entries.isEmpty else { continue }
                let windows = harnessMap.spentWindows(in: usage, for: mapped)
                guard !windows.isEmpty else { continue }
                let paceReadings = windows.map { window -> UsagePace.Reading in
                    pace[UsagePriority.key(usage, window)] ?? .unknown
                }
                if let block = block(windows, paceReadings: paceReadings, usage: usage,
                                     now: now, warnThreshold: warnThreshold) {
                    blocks[usage.id, default: []].append(block)
                    continue
                }
                // What would lapse unused on a limit about to reset counts on top of its
                // remaining share, so that limit binds less — or not at all.
                let lapsing = lapsingShares(in: windows, paceReadings: paceReadings, now: now)
                let shares = windows.enumerated().map { index, window in
                    min(1, (100 - window.usedPercent) / 100 + (lapsing[index] ?? 0))
                }
                guard let limiting = windows.indices.min(by: {
                    shares[$0] != shares[$1] ? shares[$0] < shares[$1]
                        : UsagePriority.key(usage, windows[$0]) < UsagePriority.key(usage, windows[$1])
                }) else { continue }
                let remaining = shares[limiting]

                let situation: SituationCode = !lapsing.isEmpty ? .expiringHeadroom
                    : paceReadings.contains(.unknown) ? .remainingShare : .windowHeadroom
                for entry in entries {
                    guard let quality = quality(entry.rank, task: task) else { continue }
                    candidates.append(Candidate(
                        usage: usage,
                        modelKey: mapped.model.key,
                        effort: mapped.model.efforts.isEmpty ? nil : entry.effort,
                        situation: situation,
                        limitingWindowKey: UsagePriority.key(usage, windows[limiting]),
                        expiringWindowKey: lapsing.keys.min().map { UsagePriority.key(usage, windows[$0]) },
                        remaining: remaining,
                        score: quality * remaining))
                }
            }
        }

        // Best candidate per account, in rank order.
        var seenAccounts = Set<String>()
        let ranked = candidates.sorted(by: isBetter).filter { seenAccounts.insert($0.usage.id).inserted }
        let options = ranked.map {
            SuggestionReport.Option(
                accountID: $0.usage.id, provider: $0.usage.provider, modelKey: $0.modelKey,
                effort: $0.effort, situation: $0.situation,
                limitingWindowKey: $0.limitingWindowKey, remainingShare: $0.remaining,
                expiringWindowKey: $0.expiringWindowKey)
        }
        // An account is left out only when none of its models carries a candidate.
        let excluded = usages.compactMap { usage -> SuggestionReport.Excluded? in
            guard !seenAccounts.contains(usage.id),
                  let block = blocks[usage.id]?.min(by: unblocksSooner) else { return nil }
            return SuggestionReport.Excluded(
                accountID: usage.id, provider: usage.provider, reason: block.reason,
                windowKey: block.windowKey, unblocksAt: block.unblocksAt)
        }

        guard let best = ranked.first else {
            let reason: SuggestionNoneReason = !freshAccountMapsToCatalog ? .noCatalogMatch
                : blocks.isEmpty ? .noCandidates : .excluded
            return SuggestionReport(result: .none(reason), excluded: excluded)
        }
        let result: SuggestionResult = ranked.count == 1 ? .neutral(
            accountID: best.usage.id, provider: best.usage.provider, modelKey: best.modelKey,
            effort: best.effort, situation: best.situation,
            limitingWindowKey: best.limitingWindowKey
        ) : .suggest(
            accountID: best.usage.id, provider: best.usage.provider, modelKey: best.modelKey,
            effort: best.effort, situation: best.situation,
            limitingWindowKey: best.limitingWindowKey
        )
        return SuggestionReport(result: result, options: options, excluded: excluded)
    }

    /// For the longest limits (every one of that length) that reset soon: the share each
    /// would still hold at the reset, keyed by window index — the smaller of what its own
    /// average pace and a measured pace leave. A limit that would hold less than
    /// `expiringLeftoverFloor` points is left alone.
    private static func lapsingShares(in windows: [UsageWindow], paceReadings: [UsagePace.Reading],
                                      now: Date) -> [Int: Double] {
        guard let longest = windows.compactMap(\.durationMinutes).max(), longest > 0 else { return [:] }
        let soon = min(TimeInterval(longest) * 60 * expiringShare, expiringHorizon)
        var shares: [Int: Double] = [:]
        for (index, window) in windows.enumerated() {
            guard window.durationMinutes == longest, let resetsAt = window.resetsAt,
                  resetsAt.timeIntervalSince(now) <= soon,
                  let projection = UsageForecast.projection(window, now: now) else { continue }
            var leftover = 100 - projection.projectedUsedAtReset
            if case .depleting(let emptyAt) = paceReadings[index] {
                // The measured slope spends (100 - used) over the time to `emptyAt`.
                let untilEmpty = emptyAt.timeIntervalSince(now)
                let spentShare = untilEmpty > 0 ? min(1, resetsAt.timeIntervalSince(now) / untilEmpty) : 1
                leftover = min(leftover, (100 - window.usedPercent) * (1 - spentShare))
            }
            if leftover >= expiringLeftoverFloor { shares[index] = leftover / 100 }
        }
        return shares
    }

    /// Why these windows can't carry a candidate, or nil when they can. An untrustworthy
    /// number says nothing more; otherwise the blocker named is the one that clears last.
    private static func block(_ windows: [UsageWindow], paceReadings: [UsagePace.Reading],
                              usage: AccountUsage, now: Date, warnThreshold: Double) -> Block? {
        if let invalid = windows.first(where: {
            !($0.usedPercent.isFinite && (0...100).contains($0.usedPercent))
                || ($0.resetsAt.map { $0 <= now } ?? false)
        }) {
            return Block(reason: .invalidWindow, windowKey: UsagePriority.key(usage, invalid),
                         unblocksAt: nil)
        }
        // Every limit in the way: at the warning level, or draining before its own reset.
        let blockers = zip(windows, paceReadings).compactMap {
            window, reading -> (window: UsageWindow, reason: SuggestionExclusion)? in
            if window.usedPercent >= warnThreshold { return (window, .overWarnThreshold) }
            if let runsOutAt = UsagePace.runsOutEarly(reading, window: window) {
                return (window, .runsOutEarly(at: runsOutAt))
            }
            return nil
        }
        // The account frees up when its last blocker resets; a blocker without a reset
        // time never says when.
        guard let last = blockers.min(by: { lhs, rhs in
            switch (lhs.window.resetsAt, rhs.window.resetsAt) {
            case (nil, .some): return true
            case (.some, nil): return false
            case (let left?, let right?) where left != right: return left > right
            default:
                return UsagePriority.key(usage, lhs.window) < UsagePriority.key(usage, rhs.window)
            }
        }) else { return nil }
        return Block(reason: last.reason, windowKey: UsagePriority.key(usage, last.window),
                     unblocksAt: last.window.resetsAt)
    }

    /// Orders an account's blocked models by when they free up; unknown times go last.
    private static func unblocksSooner(_ left: Block, _ right: Block) -> Bool {
        switch (left.unblocksAt, right.unblocksAt) {
        case (.some, nil): return true
        case (nil, .some): return false
        case (let lhs?, let rhs?) where lhs != rhs: return lhs < rhs
        default: return left.windowKey < right.windowKey
        }
    }

    private static func isBetter(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.usage.id != right.usage.id { return left.usage.id < right.usage.id }
        if left.modelKey != right.modelKey { return left.modelKey < right.modelKey }
        return (left.effort ?? "") < (right.effort ?? "")
    }

    /// model-tf ranks use 1 = best. Interpolate the requested task axis first, then
    /// invert the rank so higher quality contributes a larger score.
    static func quality(_ ranks: [String: Int], task: Double) -> Double? {
        let simple = ranks["simpleCoding"].map(Double.init)
        let reasoning = ranks["reasoning"].map(Double.init)
        let rank: Double
        if task == 0 {
            guard let simple else { return nil }
            rank = simple
        } else if task == 1 {
            guard let reasoning else { return nil }
            rank = reasoning
        } else {
            guard let simple, let reasoning else { return nil }
            rank = simple * (1 - task) + reasoning * task
        }
        guard rank.isFinite, rank > 0 else { return nil }
        return 1 / rank
    }

    private static func permits(_ entry: SuggestionCatalog.Entry,
                                model: SuggestionCatalog.Model,
                                mode: SuggestionMode) -> Bool {
        let tier = tierRank(entry.tier)
        let medium = effortAtMost(entry.effort, ceiling: "medium", model: model)
        let high = effortAtMost(entry.effort, ceiling: "high", model: model)
        let maximum = effortAtMost(entry.effort, ceiling: "max", model: model)
        switch mode {
        case .saver:
            return tier <= tierRank(.mid) && medium
        case .balanced:
            return (tier <= tierRank(.frontier) && medium)
                || (tier <= tierRank(.mid) && high)
        case .focus:
            return tier <= tierRank(.frontier) && high
        case .urgent:
            return tier <= tierRank(.frontier) && maximum
        }
    }

    private static func tierRank(_ tier: SuggestionCatalog.Tier) -> Int {
        switch tier {
        case .low: 0
        case .mid: 1
        case .frontier: 2
        }
    }

    private static func effortAtMost(_ effort: String, ceiling: String,
                                    model: SuggestionCatalog.Model) -> Bool {
        guard !model.efforts.isEmpty else { return true }
        guard let effortIndex = model.efforts.firstIndex(of: effort),
              let ceilingRank = effortRank(ceiling) else { return false }
        let lastAllowed = model.efforts.lastIndex {
            (effortRank($0) ?? Int.max) <= ceilingRank
        }
        return lastAllowed.map { effortIndex <= $0 } ?? false
    }

    private static func effortRank(_ effort: String) -> Int? {
        ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
            .firstIndex(of: effort)
    }
}
