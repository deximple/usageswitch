import Foundation

/// Which windows just crossed the warning threshold. Pure state transitions — the app layer
/// decides how to deliver them. A key leaves the dedup set once the window drops back under
/// `threshold - hysteresis` or goes stale, so a refill arms the alert again. A read that fails
/// says nothing about the window, so it leaves that account's keys as they are.
public enum UsageAlerts {
    /// Five points below the threshold re-arms an alert, so a tiny refill doesn't re-fire it.
    public static let hysteresis = 5.0

    /// A stored mark counts for a window only when both resets land within this window —
    /// a different reset time is a different billing cycle and deserves a fresh warning.
    public static let sameCycleTolerance: TimeInterval = 600

    /// What a warned window looked like when the mark was taken.
    public struct Mark: Codable, Equatable, Sendable {
        public var resetsAt: Date?
        public init(resetsAt: Date? = nil) { self.resetsAt = resetsAt }
    }

    public struct Alert: Equatable, Sendable {
        /// The pinned-row key — also the notification identifier's seed.
        public let key: String
        public let usage: AccountUsage
        public let window: UsageWindow
        /// true when it just emptied (100%+), false when it crossed `threshold`.
        public let emptied: Bool
    }

    /// Returns the alerts to raise now and the marks to keep for the next refresh.
    public static func update(usages: [AccountUsage], threshold: Double, alerted: [String: Mark],
                              now: Date) -> (alerts: [Alert], alerted: [String: Mark]) {
        var next: [String: Mark] = [:]
        var alerts: [Alert] = []
        for usage in usages where usage.state != .ok {
            let prefix = usage.id + "/"
            for (key, mark) in alerted where key.hasPrefix(prefix) {
                // A mark whose reset already passed describes a dead cycle — drop it.
                if mark.resetsAt.map({ $0 <= now }) != true { next[key] = mark }
            }
        }
        for usage in usages where usage.state == .ok {
            for window in usage.windows where !window.isStale(now: now) {
                let key = UsagePriority.key(usage, window)
                let stored = alerted[key]
                let sameCycle = stored.map { mark in
                    mark.resetsAt == nil || window.resetsAt == nil
                        || abs(window.resetsAt!.timeIntervalSince(mark.resetsAt!)) <= sameCycleTolerance
                } ?? false
                if window.usedPercent >= threshold {
                    next[key] = Mark(resetsAt: window.resetsAt)
                    if !sameCycle {
                        alerts.append(Alert(key: key, usage: usage, window: window,
                                            emptied: window.usedPercent >= 100))
                    }
                } else if window.usedPercent >= threshold - hysteresis, sameCycle, let stored {
                    // Still close to the line: keep it spent until it clearly recovers.
                    next[key] = stored
                }
            }
        }
        return (alerts, next)
    }
}
