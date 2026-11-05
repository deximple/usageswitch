import Foundation

/// Which windows just crossed the warning threshold. Pure state transitions — the app layer
/// decides how to deliver them. Memory-only dedup: a key leaves the set once the window drops
/// back under `threshold - hysteresis` or goes stale, so a refill arms the alert again.
public enum UsageAlerts {
    /// Five points below the threshold re-arms an alert, so a tiny refill doesn't re-fire it.
    public static let hysteresis = 5.0

    public struct Alert: Equatable, Sendable {
        /// The pinned-row key — also the notification identifier's seed.
        public let key: String
        public let usage: AccountUsage
        public let window: UsageWindow
        /// true when it just emptied (100%+), false when it crossed `threshold`.
        public let emptied: Bool
    }

    /// Returns the alerts to raise now and the dedup set to keep for the next refresh.
    public static func update(usages: [AccountUsage], threshold: Double, alerted: Set<String>,
                              now: Date) -> (alerts: [Alert], alerted: Set<String>) {
        var next = Set<String>()
        var alerts: [Alert] = []
        for usage in usages where usage.state == .ok {
            for window in usage.windows where !window.isStale(now: now) {
                let key = UsagePriority.key(usage, window)
                if window.usedPercent >= threshold {
                    next.insert(key)
                    if !alerted.contains(key) {
                        alerts.append(Alert(key: key, usage: usage, window: window,
                                            emptied: window.usedPercent >= 100))
                    }
                } else if window.usedPercent >= threshold - hysteresis, alerted.contains(key) {
                    // Still close to the line: keep it spent until it clearly recovers.
                    next.insert(key)
                }
            }
        }
        return (alerts, next)
    }
}
