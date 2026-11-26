import Foundation

/// Buckets every reported window into the Priority view's three sections.
public enum UsagePriority {
    /// One window of one account, for one Priority row.
    public struct Row: Equatable, Sendable {
        /// `"<usage.id>/<kind>/<scope ?? "")"` — what a pin holds on to.
        public let key: String
        public let usage: AccountUsage
        public let window: UsageWindow
    }

    public struct Sections: Equatable, Sendable {
        public var pinned: [Row]
        public var runningOut: [Row]
        public var usedUp: [Row]

        public init(pinned: [Row], runningOut: [Row], usedUp: [Row]) {
            self.pinned = pinned; self.runningOut = runningOut; self.usedUp = usedUp
        }
    }

    public static func key(_ usage: AccountUsage, _ window: UsageWindow) -> String {
        "\(usage.id)/\(window.kind.rawValue)/\(window.scope ?? "")"
    }

    /// Pinned windows appear under Pinned only, stale or not. The rest go by the whole percent the
    /// row shows, like its bar: a row that reads 0% with the reset still ahead is Used Up, one at
    /// the `runningOutAt` warning line or past it is Running Out. A stale window (reset passed)
    /// claims nothing — its number no longer says where the window stands.
    public static func sections(_ usages: [AccountUsage], pins: Set<String>, now: Date,
                                runningOutAt: Double = 80) -> Sections {
        var pinned: [Row] = []
        var runningOut: [Row] = []
        var usedUp: [Row] = []
        for usage in usages {
            for window in usage.windows {
                let row = Row(key: key(usage, window), usage: usage, window: window)
                if pins.contains(row.key) {
                    pinned.append(row)
                } else if UsageBarPalette.isUsedUp(usedPercent: window.usedPercent) {
                    if let resetsAt = window.resetsAt, resetsAt > now { usedUp.append(row) }
                } else if UsageBarPalette.isAtWarningLine(usedPercent: window.usedPercent, warnAt: runningOutAt),
                          !window.isStale(now: now) {
                    runningOut.append(row)
                }
            }
        }
        let byUse = { (a: Row, b: Row) in a.window.usedPercent > b.window.usedPercent }
        return Sections(pinned: pinned.sorted(by: byUse), runningOut: runningOut.sorted(by: byUse),
                        usedUp: usedUp.sorted(by: byUse))
    }
}
