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
        /// Where a rising streak started; while use keeps climbing the anchor stays put (audit
        /// B-08), so a single +1 tick is not a slope. Defaults to this sample.
        public let anchorAt: Date
        public let anchorPercent: Double

        public init(at: Date, usedPercent: Double, identityKey: String? = nil,
                    resetsAt: Date? = nil, durationMinutes: Int? = nil,
                    anchorAt: Date? = nil, anchorPercent: Double? = nil) {
            self.at = at
            self.usedPercent = usedPercent
            self.identityKey = identityKey
            self.resetsAt = resetsAt
            self.durationMinutes = durationMinutes
            self.anchorAt = anchorAt ?? at
            self.anchorPercent = anchorPercent ?? usedPercent
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
    /// A rising streak's anchor is dropped after this long (audit B-08).
    public static let maximumAnchorAge: TimeInterval = 3600

    /// Compares a fresh window with its previous sample of the same window. A sample is admitted
    /// only when identity, reset and window length all match, both percents are 0…100 finite, and
    /// the gap is 60…maximumSampleGap seconds; anything else is `.unknown`.
    private static func admits(_ window: UsageWindow, previous: Sample, now: Date,
                               identityKey: String?) -> Bool {
        guard let identityKey, !identityKey.isEmpty,
              let resetsAt = window.resetsAt, resetsAt == previous.resetsAt, resetsAt > now,
              window.durationMinutes == previous.durationMinutes,
              identityKey == previous.identityKey,
              window.usedPercent.isFinite, previous.usedPercent.isFinite,
              (0...100).contains(window.usedPercent), (0...100).contains(previous.usedPercent)
        else { return false }
        let dt = now.timeIntervalSince(previous.at)
        return dt >= 60 && dt <= maximumSampleGap
    }

    /// The anchor the next sample should carry: kept while use climbs (≤ maximumAnchorAge),
    /// moved to the current sample when flat, falling, or out of the continuous window.
    public static func anchor(for window: UsageWindow, previous: Sample?, now: Date,
                              identityKey: String? = nil) -> (at: Date, percent: Double)? {
        guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return nil }
        if let previous, admits(window, previous: previous, now: now, identityKey: identityKey),
           window.usedPercent > previous.usedPercent,
           now.timeIntervalSince(previous.anchorAt) <= maximumAnchorAge {
            return (previous.anchorAt, previous.anchorPercent)
        }
        return (now, window.usedPercent)
    }

    public static func reading(_ window: UsageWindow, previous: Sample?, now: Date,
                               identityKey: String? = nil) -> Reading {
        guard let previous, admits(window, previous: previous, now: now, identityKey: identityKey)
        else { return .unknown }
        let dt = now.timeIntervalSince(previous.at)
        let climb = window.usedPercent - previous.usedPercent
        guard climb > 0 else { return .steady }
        if climb >= 5 {
            // A steep single step projects at once — a fast drain must not wait for the anchor.
            let hoursToEmpty = (100 - window.usedPercent) / (climb / (dt / 3600))
            return .depleting(at: now.addingTimeInterval(hoursToEmpty * 3600))
        }
        // Otherwise project only on anchored evidence: ≥ 2 points over ≥ 10 minutes (audit B-08).
        let anchorDt = now.timeIntervalSince(previous.anchorAt)
        let anchorClimb = window.usedPercent - previous.anchorPercent
        guard anchorDt >= 600, anchorClimb >= 2 else { return .unknown }
        let hoursToEmpty = (100 - window.usedPercent) / (anchorClimb / (anchorDt / 3600))
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
