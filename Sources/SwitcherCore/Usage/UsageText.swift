import Foundation

/// Every user-visible string derived from a usage reading, in one place so the views stay dumb.
public enum UsageText {
    /// "Weekly", with a scope it becomes "Weekly · Fable".
    public static func name(of window: UsageWindow, scoped: Bool = true) -> String {
        let base: String
        switch window.kind {
        case .session: base = L10n.t(.usageWinSession)
        case .daily: base = L10n.t(.usageWinDaily)
        case .weekly: base = L10n.t(.usageWinWeekly)
        case .monthly: base = L10n.t(.usageWinMonthly)
        case .other: base = L10n.t(.usageWinOther)
        }
        guard scoped, let scope = window.scope else { return base }
        return L10n.t(.usageWinScope, base, scope)
    }

    /// Remaining share 0…100 as an Int, or nil for non-finite or negative input. 104% used is
    /// still 0 left; a runaway value never overflows into a fake hundred.
    public static func percentLeft(_ usedPercent: Double) -> Int? {
        guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return Int(max(0, min(100, 100 - usedPercent)).rounded())
    }

    /// Seconds until a reset, only when safely representable: non-finite or
    /// Int-overflowing intervals yield nil (views render a dash); past/sub-minute
    /// deltas yield 0 and mean "now".
    private static func safeSeconds(to resetsAt: Date, from now: Date) -> Int? {
        let delta = resetsAt.timeIntervalSince(now)
        guard delta.isFinite else { return nil }
        if delta < 60 { return 0 }
        if delta >= Double(Int.max) { return nil }
        let seconds = Int(delta)
        // representation bound: localized %d and callers assume day counts fit Int32
        if seconds / 86400 > Int(Int32.max) { return nil }
        return seconds
    }

    /// Compact locale-invariant countdown for the tight menu list: `2d 3h`, `1h 12m`, `5m`.
    /// Past/sub-minute reads mean the localized "now"; non-finite intervals yield a dash.
    public static func compactCountdown(to resetsAt: Date, from now: Date) -> String {
        guard let total = safeSeconds(to: resetsAt, from: now) else { return "—" }
        if total < 60 { return L10n.t(.usageNow) }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days >= 1 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours >= 1 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// "58% left", rounded — "—" for a reading whose percent isn't a real number.
    public static func left(_ window: UsageWindow) -> String {
        percentLeft(window.usedPercent).map { $0 == 0 ? L10n.t(.usageUsedUp) : L10n.t(.usageLeft, $0) } ?? "—"
    }

    /// "2d 4h" / "1h 13m" / "5m"; a reset in the past or under a minute away is "now".
    public static func countdown(to resetsAt: Date, from now: Date) -> String {
        guard let seconds = safeSeconds(to: resetsAt, from: now) else { return "—" }
        let minutes = seconds / 60
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

    /// The row's reason. A saved Claude account whose CLI profile is signed out gets the
    /// profile-specific text — the generic one reads as "sign in to Claude Desktop".
    public static func reason(for usage: AccountUsage) -> String? {
        if usage.pinsAccountIdentity, usage.state == .unavailable(.noSignIn) {
            return L10n.t(.usageReasonClaudeProfileNoSignIn, L10n.t(.uiDetails))
        }
        return reason(usage.state, provider: usage.provider)
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
        case .noSignIn: return L10n.t(.usageReasonNoSignIn, providerName(provider))
        case .signInExpired: return L10n.t(.usageReasonSignInExpired, cliCommand(provider))
        case .cliMissing: return L10n.t(.usageReasonCliMissing)
        case .managed: return L10n.t(.usageReasonManaged)
        case .refused: return L10n.t(.usageReasonRefused)
        case .signInRejected: return L10n.t(.usageReasonSignInRejected, cliCommand(provider))
        case .timeout: return L10n.t(.usageReasonTimeout)
        case .network: return L10n.t(.usageReasonNetwork)
        case .schemaChanged: return L10n.t(.usageReasonSchemaChanged, providerName(provider))
        case .rateLimited: return L10n.t(.usageReasonRateLimited)
        case .connectionRequired: return L10n.t(.usageReasonConnectionRequired)
        case .notEligible:
            return provider == .gemini ? L10n.t(.usageReasonGeminiRetired)
                : L10n.t(.usageReasonNotEligible, providerName(provider))
        case .accountMismatch: return L10n.t(.usageReasonAccountMismatch)
        case .profileInvalid: return L10n.t(.usageReasonProfileInvalid)
        case .unsupportedVersion: return L10n.t(.usageReasonUnsupportedVersion)
        }
    }

    /// The vendor CLI the user runs once to refresh a local sign-in — display only.
    public static func cliCommand(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        case .cursor: return "cursor-agent login"
        case .grok: return "grok login"
        case .gemini: return "gemini"
        case .antigravity: return "agy"
        case .devin: return "devin auth login"
        case .opencode: return "opencode auth login"
        case .copilot: return "gh auth login"
        }
    }

    public static func providerName(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .devin: return "Devin"
        case .opencode: return "OpenCode"
        case .copilot: return "GitHub Copilot"
        }
    }

    /// SF Symbol name per provider.
    public static func providerGlyph(_ provider: UsageProvider) -> String {
        switch provider {
        case .claude: return "asterisk"
        case .codex: return "hexagon"
        case .cursor: return "cube"
        case .grok: return "star"
        case .gemini: return "sparkle"
        case .antigravity: return "sparkles"
        case .devin: return "diamond"
        case .opencode: return "circle"
        case .copilot: return "paperplane"
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
