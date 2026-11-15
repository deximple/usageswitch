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
