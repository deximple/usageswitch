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
}

public enum SuggestionNoneReason: Equatable, Sendable {
    case noCandidates
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

/// Pure ranking over fresh usage readings and a pinned, validated catalog. It never
/// starts a tool, changes an account, or acts on the result.
public enum SuggestionEngine {
    public static let defaultWarnThreshold = 80.0
    public static let maximumReadingAge: TimeInterval = 600

    private struct Candidate {
        let usage: AccountUsage
        let modelKey: String
        let effort: String?
        let situation: SituationCode
        let limitingWindowKey: String
        let score: Double
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
        guard task.isFinite, (0...1).contains(task) else { return .none(.invalidTask) }
        guard warnThreshold.isFinite, (50...99).contains(warnThreshold) else {
            return .none(.invalidWarnThreshold)
        }

        var candidates: [Candidate] = []
        for usage in usages {
            guard usage.state == .ok,
                  (0...maximumReadingAge).contains(now.timeIntervalSince(usage.readAt))
            else { continue }
            for mapped in harnessMap.candidateModels(for: usage.provider, catalog: catalog) {
                let windows = harnessMap.spentWindows(in: usage, for: mapped)
                guard !windows.isEmpty,
                      windows.allSatisfy({
                          $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                              && ($0.resetsAt.map { $0 > now } ?? true)
                              && $0.usedPercent < warnThreshold
                      })
                else { continue }

                let paceReadings = windows.map { window -> UsagePace.Reading in
                    pace[UsagePriority.key(usage, window)] ?? .unknown
                }
                guard !zip(windows, paceReadings).contains(where: {
                    UsagePace.runsOutEarly($0.1, window: $0.0) != nil
                }) else { continue }
                guard let remaining = windows.map({ (100 - $0.usedPercent) / 100 }).min(),
                      let limiting = windows.enumerated().min(by: {
                          let left = (100 - $0.element.usedPercent)
                          let right = (100 - $1.element.usedPercent)
                          return left != right ? left < right
                              : UsagePriority.key(usage, $0.element) < UsagePriority.key(usage, $1.element)
                      })
                else { continue }

                let situation: SituationCode = paceReadings.contains(.unknown)
                    ? .remainingShare : .windowHeadroom
                for entry in catalog.entries where entry.key == mapped.model.key {
                    guard permits(entry, model: mapped.model, mode: mode),
                          let quality = quality(entry.rank, task: task)
                    else { continue }
                    candidates.append(Candidate(
                        usage: usage,
                        modelKey: mapped.model.key,
                        effort: mapped.model.efforts.isEmpty ? nil : entry.effort,
                        situation: situation,
                        limitingWindowKey: UsagePriority.key(usage, limiting.element),
                        score: quality * remaining))
                }
            }
        }

        guard let best = candidates.sorted(by: isBetter).first else { return .none(.noCandidates) }
        let result: SuggestionResult = candidates.count == 1 ? .neutral(
            accountID: best.usage.id, provider: best.usage.provider, modelKey: best.modelKey,
            effort: best.effort, situation: best.situation,
            limitingWindowKey: best.limitingWindowKey
        ) : .suggest(
            accountID: best.usage.id, provider: best.usage.provider, modelKey: best.modelKey,
            effort: best.effort, situation: best.situation,
            limitingWindowKey: best.limitingWindowKey
        )
        return result
    }

    private static func isBetter(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.score != right.score { return left.score > right.score }
        if left.usage.id != right.usage.id { return left.usage.id < right.usage.id }
        if left.modelKey != right.modelKey { return left.modelKey < right.modelKey }
        return (left.effort ?? "") < (right.effort ?? "")
    }

    /// model-tf ranks use 1 = best. Interpolate the requested task axis first, then
    /// invert the rank so higher quality contributes a larger score.
    private static func quality(_ ranks: [String: Int], task: Double) -> Double? {
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
