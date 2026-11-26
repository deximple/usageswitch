import Foundation

/// The short account name next to the menu bar icon.
public enum MenuBarTitle {
    public static let limit = 14

    public static func preferredUsageWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        let unscoped = windows.filter { $0.scope == nil }
        return unscoped.isEmpty ? windows : unscoped
    }

    /// A window counts as used up when its displayed remaining share is 0 — the same
    /// rounding the rows use, so 99.6% used doesn't keep the bar stuck on a fake live value.
    private static func isExhausted(_ window: UsageWindow) -> Bool {
        UsageBarPalette.isUsedUp(usedPercent: window.usedPercent)
    }

    /// Picks the window for the bar. The window the user chose for the bar wins whenever it is
    /// among `accounts` (fresh readings only), used up or not — they asked for that one. A choice
    /// that isn't among them selects nothing: another account's limit in the same place would read
    /// as the chosen one. With no choice:
    /// a live pinned window first; an exhausted pin still outranks unpinned windows but only once
    /// every pin is used up; then the most-used live window (the least left that isn't 0); "used up"
    /// only when nothing live remains. An account whose common (unscoped) window is exhausted is
    /// blocked — its other windows would claim headroom the account doesn't have, so they can't be
    /// selected. A scoped window that's exhausted doesn't block the account; other models keep working.
    public static func selectWindow(
        accounts: [[(key: String, window: UsageWindow)]],
        pins: Set<String>,
        chosen: String? = nil
    ) -> UsageWindow? {
        if let chosen, !chosen.isEmpty {
            return accounts.lazy.flatMap({ $0 }).first(where: { $0.key == chosen })?.window
        }
        var livePinned: UsageWindow?
        var exhaustedPinned: UsageWindow?
        var live: UsageWindow?
        var exhausted: UsageWindow?
        for account in accounts {
            let blocked = account.contains { $0.window.scope == nil && isExhausted($0.window) }
            for (key, window) in account where pins.contains(key) {
                if isExhausted(window) {
                    if (exhaustedPinned?.usedPercent ?? -1) < window.usedPercent {
                        exhaustedPinned = window
                    }
                } else if !blocked, (livePinned?.usedPercent ?? -1) < window.usedPercent {
                    livePinned = window
                }
            }
            for window in preferredUsageWindows(account.map(\.window)) {
                if isExhausted(window) {
                    if (exhausted?.usedPercent ?? -1) < window.usedPercent { exhausted = window }
                } else if !blocked, (live?.usedPercent ?? -1) < window.usedPercent {
                    live = window
                }
            }
        }
        return livePinned ?? exhaustedPinned ?? live ?? exhausted
    }

    /// The windows that may feed the bar, one list per account in `usages` order (an account with
    /// nothing to offer keeps its place with an empty list). Only a reading that is ok and no older
    /// than `UsagePresentations.verifiedAgeLimit` counts, and of it only the windows whose reset is
    /// still ahead and whose number is real — a stale or failed read is never shown as current.
    public static func candidates(_ usages: [AccountUsage],
                                  now: Date) -> [[(key: String, window: UsageWindow)]] {
        usages.map { usage -> [(key: String, window: UsageWindow)] in
            guard usage.state == .ok,
                  (0...UsagePresentations.verifiedAgeLimit).contains(now.timeIntervalSince(usage.readAt))
            else { return [] }
            return usage.windows.filter { !$0.isStale(now: now) && $0.usedPercent.isFinite }
                .map { window in (key: UsagePriority.key(usage, window), window: window) }
        }
    }

    /// The bar's usage title for these readings: the window `selectWindow` picks among
    /// `candidates`, nil when there is none or its number can't be shown as a share left.
    public static func usageTitle(usages: [AccountUsage], pins: Set<String>, chosen: String?,
                                  now: Date) -> String? {
        guard let window = selectWindow(accounts: candidates(usages, now: now), pins: pins, chosen: chosen),
              UsageText.percentLeft(window.usedPercent) != nil else { return nil }
        return usage(windowName: UsageText.name(of: window, scoped: false), usedPercent: window.usedPercent)
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
