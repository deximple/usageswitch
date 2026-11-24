import Foundation

/// When a usage re-read is due. Pure and tested here so the 30 s tick can't loop:
/// a stale number (reset already past when it was read) must not trigger a re-read by itself,
/// or a failed read would spawn the vendor tools forever.
public enum UsageRefreshPolicy {
    public static let stallLimit: TimeInterval = 600
    public static let maxAbandonedRefreshes = 2

    public static func shouldRestartStalledRefresh(startedAt: Date?, now: Date,
                                                    abandoned: Int) -> Bool {
        isRefreshStalled(startedAt: startedAt, now: now)
            && abandoned < maxAbandonedRefreshes
    }

    /// Refresh when the saved Claude registry changes, or when status arrives after an
    /// earlier usage read started without it.
    public static func shouldRefreshAfterClaudeStatusChange(
        oldAccountIds: Set<String>?,
        newAccountIds: Set<String>,
        refreshedWithoutClaudeStatus: Bool
    ) -> Bool {
        guard let oldAccountIds else {
            return refreshedWithoutClaudeStatus
        }
        return oldAccountIds != newAccountIds
    }

    public static func isRefreshStalled(startedAt: Date?, now: Date,
                                        limit: TimeInterval = stallLimit) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= limit
    }

    /// Due when the interval elapsed, or when some window's reset happened *since the last read
    /// began* — `lastReadStartedAt < resetsAt <= now`. A window already stale at read time
    /// (resetsAt ≤ lastReadStartedAt, e.g. a Claude weekly reset inside its last day) is not a
    /// reason to read again. nil `lastReadStartedAt` counts as never having read.
    /// A collector's cached reading is due the same way, when its cache ran out since then.
    public static func isDue(now: Date, nextRefresh: Date, lastReadStartedAt: Date?,
                             usages: [AccountUsage]) -> Bool {
        if now >= nextRefresh { return true }
        let readStarted = lastReadStartedAt ?? .distantPast
        return usages.contains { usage in
            if let cachedUntil = cachedUntil(usage), readStarted < cachedUntil, cachedUntil <= now {
                return true
            }
            return usage.windows.contains { window in
                window.resetsAt.map { readStarted < $0 && $0 <= now } ?? false
            }
        }
    }

    /// When a current reading's collector stops handing it back and reads anew; nil for a
    /// collector that reads on every refresh. Antigravity keeps its `/usage` screen for nine
    /// minutes, so two five-minute intervals would carry the same reading past
    /// `UsagePresentations.verifiedAgeLimit` before the third replaced it.
    private static func cachedUntil(_ usage: AccountUsage) -> Date? {
        guard usage.provider == .antigravity, usage.state == .ok else { return nil }
        return usage.readAt.addingTimeInterval(AntigravityUsageScreenCache.minimumInterval)
    }
}

/// Short re-reads after the Mac wakes. The first read after waking often starts before the
/// network is back, and its failure would otherwise stay on screen for a whole refresh interval.
/// Bounded on purpose: a few waits per wake and only in the minutes after it, so a read that keeps
/// failing goes back to the regular interval instead of running the vendor tools over and over.
public struct UsageWakeRecovery: Equatable, Sendable {
    /// The wait before each re-read after one wake, in order.
    public static let retryDelays: [TimeInterval] = [30, 60, 120]
    /// How long after waking a read still counts as that wake's.
    public static let window: TimeInterval = 600

    private let wokeAt: Date?
    private let retriesUsed: Int
    /// Rows that showed a current reading when the Mac woke.
    private let readableBeforeWaking: Set<String>

    public init() {
        self.init(wokeAt: nil, retriesUsed: 0, readableBeforeWaking: [])
    }

    private init(wokeAt: Date?, retriesUsed: Int, readableBeforeWaking: Set<String>) {
        self.wokeAt = wokeAt
        self.retriesUsed = retriesUsed
        self.readableBeforeWaking = readableBeforeWaking
    }

    /// The Mac woke at `now` with `usages` on screen: the re-reads are available again.
    public func waking(at now: Date, usages: [AccountUsage]) -> UsageWakeRecovery {
        UsageWakeRecovery(wokeAt: now, retriesUsed: 0,
                          readableBeforeWaking: Set(usages.filter { $0.state == .ok }.map(\.id)))
    }

    /// When the next read starts, and the recovery to carry on with. `scheduled` is when it would
    /// start anyway; `usages` are the rows the last read left. Asked when a read ends, and when the
    /// Mac wakes with no read running — a read can end with its failure a moment before the wake is
    /// noticed. A re-read is used up only when it really moves the next read forward.
    public func nextRead(scheduled: Date, usages: [AccountUsage],
                         now: Date) -> (at: Date, recovery: UsageWakeRecovery) {
        guard let wokeAt, (0...Self.window).contains(now.timeIntervalSince(wokeAt)),
              retriesUsed < Self.retryDelays.count,
              usages.contains(where: wantsReread) else { return (scheduled, self) }
        let retryAt = now.addingTimeInterval(Self.retryDelays[retriesUsed])
        guard retryAt < scheduled else { return (scheduled, self) }
        return (retryAt, UsageWakeRecovery(wokeAt: wokeAt, retriesUsed: retriesUsed + 1,
                                           readableBeforeWaking: readableBeforeWaking))
    }

    /// Whether a row looks like the network wasn't back yet: a read that got no answer, or a row
    /// that had numbers when the Mac woke and came back without them (a vendor CLI offline can end
    /// as "not reporting" or "unavailable" rather than as a failure). A failure the vendor answered
    /// with — rate limit, rejected sign-in, another account — is never a reason to ask again early,
    /// and neither is a connection the user just turned off.
    private func wantsReread(_ usage: AccountUsage) -> Bool {
        switch usage.state {
        case .ok, .unavailable(.connectionRequired): return false
        case .failed(let problem): return problem == .network || problem == .timeout || problem == .refused
        case .unavailable, .notReporting: return readableBeforeWaking.contains(usage.id)
        }
    }
}
