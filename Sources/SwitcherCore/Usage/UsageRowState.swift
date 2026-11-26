import Foundation

/// The Guide's attention lines: what needs a look before any suggestion, keyed by stable
/// account/window ids so two identical lines never collide in a list. An expected non-report
/// stays neutral; only real failures and aged or thresholded readings warn. Each line names the
/// provider, so a Claude "Personal" and a Codex "Personal" stay apart.
///
/// A limit is listed while its bar is below ample (`UsageBarPalette.role`): the same whole
/// percent, and — through `held` — the same level a bar keeps until the remaining share has
/// clearly recovered. A bar never shows a warning the list is silent about.
public enum UsageAttention {
    public struct Line: Equatable, Sendable {
        public let id: String
        public let text: String
        public let warn: Bool
    }

    /// `held` is the level each bar showed at the last reading (`UsageBarMemory.previous`);
    /// without it every limit is judged afresh.
    public static func lines(_ usages: [AccountUsage], label: (AccountUsage) -> String,
                             warnAt: Double, now: Date,
                             held: (AccountUsage, UsageWindow) -> UsageBarPalette.Role? = { _, _ in nil }
    ) -> [Line] {
        var items: [Line] = []
        for usage in usages {
            let name = "\(UsageText.providerName(usage.provider)) · \(label(usage))"
            switch usage.state {
            case .failed, .unavailable:
                // connectionRequired is a per-row note, never a global one. A permanent reason like
                // notEligible (a retired plan) can't be fixed, so it stays on the row and never warns.
                if case .unavailable(.connectionRequired) = usage.state { continue }
                if case .unavailable(.notEligible) = usage.state { continue }
                if let reason = UsageText.reason(for: usage) {
                    items.append(Line(id: "\(usage.id)/state", text: "\(name) — \(reason)", warn: true))
                }
            case .notReporting:
                if let reason = UsageText.reason(for: usage) {
                    items.append(Line(id: "\(usage.id)/state", text: "\(name) — \(reason)", warn: false))
                }
            case .ok:
                if !fresh(usage, now: now) {
                    items.append(Line(id: "\(usage.id)/aged",
                                      text: "\(name) — \(UsageText.updatedAgo(readAt: usage.readAt, now: now))",
                                      warn: true))
                }
            }
            guard usage.state == .ok, fresh(usage, now: now) else { continue }
            for window in usage.windows where window.scope == nil {
                if window.isStale(now: now) {
                    items.append(Line(id: UsagePriority.key(usage, window),
                                      text: "\(name) — \(L10n.t(.usageRefreshNeeded))", warn: true))
                } else if let left = UsageText.percentLeft(window.usedPercent),
                          UsageBarPalette.role(usedPercent: window.usedPercent, warnAt: warnAt, stale: false,
                                               previous: held(usage, window)).isAtWarning {
                    items.append(Line(id: UsagePriority.key(usage, window),
                                      text: L10n.t(.usageAttnWindow, name, UsageText.name(of: window), left),
                                      warn: true))
                }
            }
        }
        return items
    }

    /// A fresh reading's timestamp sits inside the admitted window; older samples and future
    /// timestamps are both stale.
    private static func fresh(_ usage: AccountUsage, now: Date) -> Bool {
        (0...UsageGuidance.maximumAge).contains(now.timeIntervalSince(usage.readAt))
    }
}

extension UsagePresentations {
    /// A registered row with no reading of its own while a refresh runs is being checked, not "not
    /// reporting". Only rows a collector will read qualify: every registered Codex home while Codex is
    /// installed (its collector reads each one), and a saved Claude account once a CLI profile is
    /// linked to it. Anything else keeps its reason, so a refresh never makes it flicker.
    public static func awaitsFirstRead(_ presentation: UsageAccountPresentation, readings: [AccountUsage],
                                       refreshing: Bool, boundClaudeAccountIDs: Set<String>,
                                       codexInstalled: Bool) -> Bool {
        guard refreshing, presentation.usage.state == .notReporting, presentation.usage.windows.isEmpty,
              !readings.contains(where: { $0.id == presentation.id }) else { return false }
        switch presentation.owner {
        case .codex: return codexInstalled
        case .claude(let id): return boundClaudeAccountIDs.contains(id)
        case nil: return false
        }
    }
}

extension UsageAccountPresentation.Login {
    /// The lock beside the name. Each state has its own shape, so a confirmed sign-in reads apart
    /// from a saved one without its color: filled open, outlined open, closed. Unknown makes no claim.
    public var symbol: String? {
        switch self {
        case .verified: "lock.open.fill"
        case .saved: "lock.open"
        case .requiresSignIn: "lock.fill"
        case .unknown: nil
        }
    }
}

extension UsageText {
    /// The reset-ticket line under an account.
    public struct ResetCreditsLine: Equatable, Sendable {
        public let text: String
        /// The count comes from an earlier read: a failed or aged one keeps the last count it had.
        public let lastKnown: Bool
    }

    /// "Limit resets: 2 · first expires in 18d". A count carried over from an earlier read (the
    /// current one failed, or is too old to be current) says when it was read, like a last-known bar.
    public static func resetCreditsLine(_ usage: AccountUsage, now: Date) -> ResetCreditsLine? {
        guard let text = resetCredits(usage.resetCredits, now: now) else { return nil }
        let current = usage.state == .ok
            && (0...UsagePresentations.verifiedAgeLimit).contains(now.timeIntervalSince(usage.readAt))
        return current
            ? ResetCreditsLine(text: text, lastKnown: false)
            : ResetCreditsLine(text: text + " · " + updatedAgo(readAt: usage.readAt, now: now), lastKnown: true)
    }

    /// `resetsIn` for the middle of a sentence ("…, 58% left, resets in 2d 4h"), lower case where the
    /// language has case. nil when the interval can't be counted.
    public static func resetsInClause(_ resetsAt: Date, now: Date) -> String? {
        guard resetsIn(resetsAt, now: now) != nil else { return nil }
        return resetsAt.timeIntervalSince(now) < 60
            ? L10n.t(.usageResetsSoonClause)
            : L10n.t(.usageResetsInClause, countdown(to: resetsAt, from: now))
    }

    /// The model catalog's date ("2026-11-07") as the app's language writes a date; nil when it isn't one.
    public static func catalogDate(_ isoDay: String, language: AppLanguage) -> String? {
        let utc = TimeZone(secondsFromGMT: 0)!
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = utc
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: isoDay) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                               locale: Locale(identifier: language.rawValue),
                                               calendar: calendar, timeZone: utc))
    }
}

/// A slider value held while it is dragged and saved once when the drag ends. A change that comes
/// without a drag — arrow keys, a VoiceOver increment — is saved at once: waiting for a drag to end
/// that never started would leave the slider moved and nothing saved.
public struct SliderDraft: Equatable, Sendable {
    /// The value shown while a drag is in progress.
    public private(set) var value: Double?
    private var dragging = false

    public init() {}

    /// Returns the value to save now, if any.
    public mutating func set(_ newValue: Double) -> Double? {
        guard dragging else {
            value = nil
            return newValue
        }
        value = newValue
        return nil
    }

    /// Returns the value to save when a drag ends with a move.
    public mutating func editingChanged(_ editing: Bool) -> Double? {
        dragging = editing
        guard !editing, let held = value else { return nil }
        value = nil
        return held
    }
}

/// Speaks a result once: the same banner can be on screen in the menu and the window at the same
/// moment, and VoiceOver should not read it twice — even when other banners are announced in between.
public struct AnnouncementGate: Sendable {
    /// The same text inside this many seconds is the same event.
    public static let window: TimeInterval = 5
    private var announced: [String: Date] = [:]

    public init() {}

    public mutating func shouldAnnounce(_ text: String, at now: Date) -> Bool {
        guard !text.isEmpty else { return false }
        announced = announced.filter { (0..<Self.window).contains(now.timeIntervalSince($0.value)) }
        guard announced[text] == nil else { return false }
        announced[text] = now
        return true
    }
}
