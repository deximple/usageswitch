import Foundation

/// Every user-visible string derived from a usage reading, in one place so the views stay dumb.
public enum UsageText {
    /// "Weekly", with a scope it becomes "Weekly · Fable".
    public static func name(of window: UsageWindow, scoped: Bool = true) -> String {
        let base: String
        switch window.kind {
        case .session: base = L10n.t(.usageWinSession)
        case .weekly: base = L10n.t(.usageWinWeekly)
        case .monthly: base = L10n.t(.usageWinMonthly)
        case .other: base = L10n.t(.usageWinOther)
        }
        guard scoped, let scope = window.scope else { return base }
        return L10n.t(.usageWinScope, base, scope)
    }

    /// "58% left", rounded.
    public static func left(_ window: UsageWindow) -> String {
        L10n.t(.usageLeft, Int((100 - window.usedPercent).rounded()))
    }

    /// "2d 4h" / "1h 13m" / "5m"; a reset in the past or under a minute away is "now".
    public static func countdown(to resetsAt: Date, from now: Date) -> String {
        let minutes = Int(resetsAt.timeIntervalSince(now)) / 60
        guard minutes >= 1 else { return L10n.t(.usageNow) }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? L10n.t(.usageDurDH, days, hours) : L10n.t(.usageDurD, days) }
        if hours > 0 { return mins > 0 ? L10n.t(.usageDurHM, hours, mins) : L10n.t(.usageDurH, hours) }
        return L10n.t(.usageDurM, minutes)
    }

    /// "updated 5m ago" for a stale window.
    public static func updatedAgo(readAt: Date, now: Date) -> String {
        let interval = max(60, now.timeIntervalSince(readAt))
        return L10n.t(.usageUpdatedAgo, countdown(to: Date(timeIntervalSince1970: interval),
                                                  from: Date(timeIntervalSince1970: 0)))
    }

    /// The localized reason a non-ok reading isn't a number; nil for `.ok`.
    public static func reason(_ state: UsageState, provider: UsageProvider) -> String? {
        switch state {
        case .ok: return nil
        case .notReporting: return L10n.t(.usageReasonNotReporting)
        case .unavailable(let problem), .failed(let problem): return self.problem(problem, provider: provider)
        }
    }

    static func problem(_ problem: UsageProblem, provider: UsageProvider) -> String {
        switch problem {
        case .noSignIn: return L10n.t(.usageReasonNoSignIn)
        case .cliMissing: return L10n.t(.usageReasonCliMissing)
        case .managed: return L10n.t(.usageReasonManaged)
        case .refused: return L10n.t(.usageReasonRefused)
        case .timeout: return L10n.t(.usageReasonTimeout)
        case .network: return L10n.t(.usageReasonNetwork)
        case .schemaChanged: return L10n.t(.usageReasonSchemaChanged, providerName(provider))
        case .rateLimited: return L10n.t(.usageReasonRateLimited)
        }
    }

    public static func providerName(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// SF Symbol name per provider.
    public static func providerGlyph(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .cursor: return "cube"
        }
    }

    /// The account line: fixed names for the CLI and Cursor rows (no identity), emails masked
    /// unless the user chose to always show them.
    public static func accountLabel(_ usage: AccountUsage, showEmails: Bool) -> String {
        switch (usage.provider, usage.accountRef) {
        case (.claude, "cli"): return L10n.t(.usageLabelCLI)
        case (.cursor, _): return L10n.t(.usageLabelCursor)
        default: return showEmails ? usage.label : Privacy.maskEmails(in: usage.label)
        }
    }

    /// Plan badge text: known plans get their display name, anything else shows as reported.
    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw
        }
    }
}
