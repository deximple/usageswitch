import Foundation

/// What each bar showed at the last reading, so a level that got worse eases only once the
/// remaining share has clearly recovered (`UsageBarPalette.recovery`). Memory only: a restart
/// judges every bar afresh, and so does a new cycle or a changed warning setting.
public enum UsageBarMemory {
    public struct Mark: Equatable, Sendable {
        public let role: UsageBarPalette.Role
        /// The warning setting the level was judged against.
        public let warnAt: Double
        public let resetsAt: Date?

        public init(role: UsageBarPalette.Role, warnAt: Double, resetsAt: Date?) {
            self.role = role
            self.warnAt = warnAt
            self.resetsAt = resetsAt
        }
    }

    /// The level `window` showed last, when that still says something: the same warning setting
    /// and the same cycle (`UsageAlerts.sameCycleTolerance`, as the alerts count it).
    public static func previous(for window: UsageWindow, key: String, warnAt: Double,
                                in marks: [String: Mark]) -> UsageBarPalette.Role? {
        guard let mark = marks[key], mark.warnAt == warnAt else { return nil }
        if let before = mark.resetsAt, let after = window.resetsAt,
           abs(after.timeIntervalSince(before)) > UsageAlerts.sameCycleTolerance {
            return nil
        }
        return mark.role
    }

    /// The marks after a reading: one per window that shows a current number, nothing else. A
    /// stale or failed reading drops its mark, and so does an account that is no longer listed.
    public static func update(_ marks: [String: Mark], usages: [AccountUsage], warnAt: Double,
                              now: Date) -> [String: Mark] {
        var next: [String: Mark] = [:]
        for usage in usages {
            for window in usage.windows
            where UsagePresentations.windowDisplay(usage, window, now: now) == .current {
                let key = UsagePriority.key(usage, window)
                let role = UsageBarPalette.role(
                    usedPercent: window.usedPercent, warnAt: warnAt, stale: false,
                    previous: previous(for: window, key: key, warnAt: warnAt, in: marks))
                next[key] = Mark(role: role, warnAt: warnAt, resetsAt: window.resetsAt)
            }
        }
        return next
    }
}
