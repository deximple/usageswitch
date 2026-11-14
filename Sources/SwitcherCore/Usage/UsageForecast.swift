import Foundation

/// What one reading says about a window's reset, from the window's own average pace:
/// used share ÷ time already behind it. Needs no earlier sample, so it works on the first
/// read after a launch — but it is an average, never a measured slope, and is worded so.
public enum UsageForecast {
    public struct Projection: Equatable, Sendable {
        /// Share of the window's length already behind it, 0…1.
        public let elapsedFraction: Double
        /// Used percent at the reset if the average pace continued; can pass 100.
        public let projectedUsedAtReset: Double
        /// When the average pace empties the window, if that comes before the reset.
        public let runsOutAt: Date?
    }

    /// Below this share of the window's length the average is too young to project from.
    public static let minimumElapsedFraction = 0.15

    /// Nil unless the window can be placed in time: a real percent, a known positive length,
    /// a reset still ahead and no farther away than the window is long.
    public static func projection(_ window: UsageWindow, now: Date) -> Projection? {
        guard let (length, timeLeft) = placement(window, now: now) else { return nil }
        let elapsedFraction = (length - timeLeft) / length
        guard elapsedFraction >= minimumElapsedFraction else { return nil }
        let projectedUsed = window.usedPercent / elapsedFraction
        let runsOutAt: Date?
        if window.usedPercent < 100, projectedUsed > 100 {
            // remaining ÷ (used ÷ elapsed)
            let seconds = (100 - window.usedPercent) * (length - timeLeft) / window.usedPercent
            runsOutAt = now.addingTimeInterval(seconds)
        } else {
            runsOutAt = nil
        }
        return Projection(elapsedFraction: elapsedFraction, projectedUsedAtReset: projectedUsed,
                          runsOutAt: runsOutAt)
    }

    /// Percent points a day that last exactly to the reset. Nil inside the last day (a day's
    /// allowance says nothing there), for a spent window, or when the reset is unknown.
    public static func dailyBudget(_ window: UsageWindow, now: Date) -> Double? {
        guard window.usedPercent.isFinite, (0..<100).contains(window.usedPercent),
              let resetsAt = window.resetsAt else { return nil }
        let days = resetsAt.timeIntervalSince(now) / 86400
        guard days.isFinite, days >= 1 else { return nil }
        return (100 - window.usedPercent) / days
    }

    /// The window's length and the time left on it, in seconds.
    private static func placement(_ window: UsageWindow, now: Date)
        -> (length: TimeInterval, timeLeft: TimeInterval)? {
        guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
              let minutes = window.durationMinutes, minutes > 0,
              let resetsAt = window.resetsAt else { return nil }
        let length = TimeInterval(minutes) * 60
        let timeLeft = resetsAt.timeIntervalSince(now)
        guard timeLeft > 0, timeLeft <= length else { return nil }
        return (length, timeLeft)
    }
}
