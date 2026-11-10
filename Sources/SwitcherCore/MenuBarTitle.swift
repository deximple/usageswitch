/// The short account name next to the menu bar icon.
public enum MenuBarTitle {
    public static let limit = 14

    public static func preferredUsageWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        let unscoped = windows.filter { $0.scope == nil }
        return unscoped.isEmpty ? windows : unscoped
    }

    public static func selectWindow(
        accounts: [[(key: String, window: UsageWindow)]],
        pins: Set<String>
    ) -> UsageWindow? {
        var pinned: UsageWindow?
        var best: UsageWindow?
        for account in accounts {
            for (key, window) in account where pins.contains(key) {
                if (pinned?.usedPercent ?? -1) < window.usedPercent { pinned = window }
            }
            for window in preferredUsageWindows(account.map(\.window)) {
                if (best?.usedPercent ?? -1) < window.usedPercent { best = window }
            }
        }
        return pinned ?? best
    }

    /// nil when the name is turned off. Emails are masked (the bar is visible when sharing screens) unless the user
    /// chose to always show them; long names end in "…".
    public static func make(label: String?, showsName: Bool, showEmails: Bool) -> String? {
        guard showsName, let label else { return nil }
        let shown = showEmails ? label : Privacy.maskEmails(in: label)
        return shown.count > limit ? String(shown.prefix(limit - 1)) + "…" : shown
    }

    /// The most constrained window's short title, e.g. "Weekly 25% left". `usedPercent` keeps its
    /// JSON/collector meaning (share consumed); what the bar shows is the REMAINING share.
    public static func usage(windowName: String, usedPercent: Double) -> String {
        UsageText.percentLeft(usedPercent)
            .map { "\(windowName) \($0 == 0 ? L10n.t(.usageUsedUp) : L10n.t(.usageLeft, $0))" } ?? "\(windowName) —"
    }
}
