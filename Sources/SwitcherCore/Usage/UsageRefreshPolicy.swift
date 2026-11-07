import Foundation

/// When a usage re-read is due. Pure and tested here so the 30 s tick can't loop:
/// a stale number (reset already past when it was read) must not trigger a re-read by itself,
/// or a failed read would spawn the vendor tools forever.
public enum UsageRefreshPolicy {
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

    /// Due when the interval elapsed, or when some window's reset happened *since the last read
    /// began* — `lastReadStartedAt < resetsAt <= now`. A window already stale at read time
    /// (resetsAt ≤ lastReadStartedAt, e.g. a Claude weekly reset inside its last day) is not a
    /// reason to read again. nil `lastReadStartedAt` counts as never having read.
    public static func isDue(now: Date, nextRefresh: Date, lastReadStartedAt: Date?,
                             usages: [AccountUsage]) -> Bool {
        if now >= nextRefresh { return true }
        let readStarted = lastReadStartedAt ?? .distantPast
        return usages.contains { usage in
            usage.windows.contains { window in
                window.resetsAt.map { readStarted < $0 && $0 <= now } ?? false
            }
        }
    }
}
