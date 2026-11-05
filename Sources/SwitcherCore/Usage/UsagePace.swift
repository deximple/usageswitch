import Foundation

/// How fast a window is draining, from the app's previous reading of the same window.
/// Memory-only: two samples a few minutes apart are enough for an "out before reset" flag,
/// and after a restart the first read simply reports `unknown`.
public enum UsagePace {
    /// A previous (readAt, usedPercent) of one window, plus what ties it to that login and period.
    /// Two samples only prove a slope when the login, reset and window length all match —
    /// otherwise the numbers could come from a different account or a different cycle.
    public struct Sample: Equatable, Sendable {
        public let at: Date
        public let usedPercent: Double
        /// Opaque login fingerprint of the reading (`AccountUsage.identityKey`).
        public let identityKey: String?
        public let resetsAt: Date?
        public let durationMinutes: Int?

        public init(at: Date, usedPercent: Double, identityKey: String? = nil,
                    resetsAt: Date? = nil, durationMinutes: Int? = nil) {
            self.at = at
            self.usedPercent = usedPercent
            self.identityKey = identityKey
            self.resetsAt = resetsAt
            self.durationMinutes = durationMinutes
        }
    }

    public enum Reading: Equatable, Sendable {
        /// No prior sample, or not enough time between reads to say anything.
        case unknown
        /// Use did not go up — nothing is draining right now.
        case steady
        /// Use is climbing; projected exhaustion at this date.
        case depleting(at: Date)
    }

    /// Samples farther apart than this aren't treated as one continuous observation.
    public static let maximumSampleGap: TimeInterval = 600

    /// Compares a fresh window with its previous sample of the same window. A sample is admitted
    /// only when identity, reset and window length all match, both percents are 0…100 finite, and
    /// the gap is 60…maximumSampleGap seconds; anything else is `.unknown`.
    public static func reading(_ window: UsageWindow, previous: Sample?, now: Date,
                               identityKey: String? = nil) -> Reading {
        guard let previous else { return .unknown }
        guard let identityKey, !identityKey.isEmpty,
              let resetsAt = window.resetsAt, resetsAt == previous.resetsAt, resetsAt > now,
              window.durationMinutes == previous.durationMinutes,
              identityKey == previous.identityKey,
              window.usedPercent.isFinite, previous.usedPercent.isFinite,
              (0...100).contains(window.usedPercent), (0...100).contains(previous.usedPercent)
        else { return .unknown }
        let dt = now.timeIntervalSince(previous.at)
        guard dt >= 60, dt <= maximumSampleGap else { return .unknown }
        let climb = window.usedPercent - previous.usedPercent
        guard climb > 0 else { return .steady }
        let hoursToEmpty = (100 - window.usedPercent) / (climb / (dt / 3600))
        return .depleting(at: now.addingTimeInterval(hoursToEmpty * 3600))
    }

    /// The projected exhaustion moment when it matters: before the window's own reset, or for a
    /// window with no reset at all. A depletion later than the reset is on track.
    public static func runsOutEarly(_ reading: Reading, window: UsageWindow) -> Date? {
        guard case .depleting(let at) = reading else { return nil }
        guard let resetsAt = window.resetsAt else { return at }
        return at < resetsAt ? at : nil
    }
}
