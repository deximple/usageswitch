import Foundation

/// Which windows just crossed the warning threshold. Pure state transitions — the app layer
/// decides how to deliver them. Every line here is read off the whole percent the row shows
/// (`UsageBarPalette.isAtWarningLine`), so an alert fires on the reading that turns the bar. A key
/// leaves the dedup set once the window drops back under `threshold - hysteresis` or goes stale,
/// so a refill arms the alert again. A read that fails says nothing about the window, so it
/// leaves that account's keys as they are.
public enum UsageAlerts {
    /// Five points below the threshold re-arms an alert, so a tiny refill doesn't re-fire it:
    /// under a 20% warning line the row has to read 26% or more.
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
        /// true when the row reads 0% (used up), false when it only crossed `threshold`.
        public let emptied: Bool
    }

    /// Returns the alerts to raise now and the marks to keep for the next refresh.
    /// `unreadPrefix` names accounts this round did not read at all (their ids start with it): a row
    /// missing for that reason is not an account that went away, so its marks stay.
    public static func update(usages: [AccountUsage], threshold: Double, alerted: [String: Mark],
                              now: Date, unreadPrefix: String? = nil)
        -> (alerts: [Alert], alerted: [String: Mark]) {
        var next: [String: Mark] = [:]
        var alerts: [Alert] = []
        if let unreadPrefix {
            // Only for accounts that really are missing: one read this round is judged by its reading.
            let read = usages.map { $0.id + "/" }
            for (key, mark) in alerted where key.hasPrefix(unreadPrefix) && !read.contains(where: key.hasPrefix) {
                if mark.resetsAt.map({ $0 <= now }) != true { next[key] = mark }
            }
        }
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
                if UsageBarPalette.isAtWarningLine(usedPercent: window.usedPercent, warnAt: threshold) {
                    next[key] = Mark(resetsAt: window.resetsAt)
                    if !sameCycle {
                        alerts.append(Alert(key: key, usage: usage, window: window,
                                            emptied: UsageBarPalette.isUsedUp(usedPercent: window.usedPercent)))
                    }
                } else if UsageBarPalette.isAtWarningLine(usedPercent: window.usedPercent,
                                                          warnAt: threshold - hysteresis),
                          sameCycle, let stored {
                    // Still close to the line: keep it spent until it clearly recovers.
                    next[key] = stored
                }
            }
        }
        return (alerts, next)
    }
}
