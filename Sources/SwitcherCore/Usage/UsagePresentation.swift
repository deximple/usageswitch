import Foundation

/// One usage row's identity-facing presentation: display name, environment, login
/// state, and which saved account (if any) owns it. Pure data — no Codable, no
/// SwiftUI, no new lookups in credentials or databases.
public struct UsageAccountPresentation: Equatable, Sendable {
    public enum Environment: String, Sendable { case cli, app }
    public enum Login: String, Sendable { case verified, saved, requiresSignIn, unknown }
    public enum Owner: Equatable, Sendable { case claude(String), codex(String) }

    public let usage: AccountUsage
    public var id: String { usage.id }
    public let name: String
    /// Memory only — the UI applies the current masking policy.
    public let email: String?
    public let environment: Environment?
    public let login: Login
    public let badgeActive: Bool
    public let owner: Owner?

    public init(usage: AccountUsage, name: String, email: String?, environment: Environment?,
                login: Login, badgeActive: Bool, owner: Owner?) {
        self.usage = usage; self.name = name; self.email = email
        self.environment = environment; self.login = login
        self.badgeActive = badgeActive; self.owner = owner
    }
}

public enum UsagePresentations {
    /// How fresh a CLI .ok reading must be to count as verified-current.
    public static let verifiedAgeLimit: TimeInterval = 600

    /// Ordered identity presentations for the usage list. Each collected reading is
    /// preserved as-is; registered-but-uncollected environments append neutral rows.
    /// Names/emails come from the CURRENT registry, never stale collected labels.
    /// `claude`/`codex` are the live status models — nil in tests/demos means no
    /// registered metadata, so fixture rows stand alone.
    public static func accounts(
        readings: [AccountUsage],
        installations: [UsageInstallation],
        claude: SwitcherStatus?,
        codex: CodexStatus?,
        now: Date
    ) -> [UsageAccountPresentation] {
        var out: [UsageAccountPresentation] = []
        var codexSeen = Set<String>()
        var claudeAppIds = Set<String>()
        let codexAppInstalled = installations.contains { $0.provider == .codex && $0.app != nil }

        for usage in readings {
            let fresh = usage.state == .ok
                && (0...verifiedAgeLimit).contains(now.timeIntervalSince(usage.readAt))
            switch usage.provider {
            case .claude:
                guard !usage.id.hasPrefix("claude:app:") else { continue }
                // The CLI reading is separate from saved App logins — never linked by email.
                out.append(UsageAccountPresentation(
                    usage: usage, name: UsageText.accountLabel(usage, showEmails: true), email: nil,
                    environment: .cli,
                    login: fresh ? .verified : .unknown,
                    badgeActive: fresh, owner: nil))
            case .codex:
                // Owner matches the exact accountRef to a CodexAccount.id only —
                // never by label or email.
                // only REGISTERED accounts may own a reading — found/uncounted
                // candidates are unregistered environments, never owners
                let account = codex?.accounts.first { $0.id == usage.accountRef }
                if let account { codexSeen.insert(account.id) }
                let running = account?.pids.isEmpty == false
                let currentCLI = account?.kind == .standard || usage.accountRef == "standard"
                let login: UsageAccountPresentation.Login =
                    account?.state == .signedOut ? .requiresSignIn
                    : fresh && currentCLI ? .verified
                    : account?.identity != nil ? .saved
                    : fresh ? .verified : .unknown
                out.append(UsageAccountPresentation(
                    usage: usage,
                    name: account?.label ?? usage.label,
                    email: account?.email,
                    environment: running ? .app : currentCLI ? .cli : codexAppInstalled ? .app : .cli,
                    login: login,
                    badgeActive: running || (fresh && currentCLI && account?.state != .signedOut),
                    owner: account.map { .codex($0.id) }))
            case .cursor, .grok, .gemini, .antigravity, .devin, .opencode, .copilot:
                let hasCLI = installations.contains { $0.provider == usage.provider && $0.cli != nil }
                let hasAntigravityApp = usage.provider == .antigravity
                    && installations.contains { $0.provider == usage.provider && $0.app != nil }
                let environment: UsageAccountPresentation.Environment? = hasCLI ? .cli
                    : hasAntigravityApp ? .app : nil
                out.append(UsageAccountPresentation(
                    usage: usage, name: UsageText.accountLabel(usage, showEmails: true), email: nil,
                    environment: environment, login: fresh ? .verified : .unknown,
                    badgeActive: fresh && hasCLI, owner: nil))
            }
        }

        // Registered Claude App accounts are included whenever the provider is
        // present — installed OR collected. Production registered accounts belong
        // even without an installation; the demo seam suppresses canned metadata.
        if installations.contains(where: { $0.provider == .claude })
            || readings.contains(where: { $0.provider == .claude })
            || !(claude?.accounts.isEmpty ?? true) {
            for account in claude?.accounts ?? [] {
                guard claudeAppIds.insert(account.id).inserted else { continue }
                let expired = account.sessionExpiresAt.map { $0 <= now } ?? false
                let login: UsageAccountPresentation.Login = switch account.snapshot {
                case .ready: expired ? .requiresSignIn : .saved
                case .expired, .corrupt: .requiresSignIn
                }
                let active = account.isActive
                    && claude?.claude.activeAccountUuid == account.accountUuid
                    && claude?.claude.activeOrgUuid == account.orgUuid
                    && account.snapshot == .ready && !expired
                let row = readings.first(where: { $0.id == "claude:app:\(account.id)" }) ?? AccountUsage(
                    id: "claude:app:\(account.id)", provider: .claude,
                    accountRef: "app:\(account.id)", label: account.label,
                    plan: nil, windows: [], state: .notReporting,
                    readAt: now, toolVersion: nil)
                out.append(UsageAccountPresentation(
                    usage: row, name: account.label, email: account.email,
                    environment: .app, login: login,
                    badgeActive: active, owner: .claude(account.id)))
            }
        }

        // Registered Codex profiles that produced no reading: neutral nonnumeric rows.
        // A phantom empty standard home (no install, identity or registration) is excluded.
        let codexInstalled = installations.contains { $0.provider == .codex }
        for account in codex?.accounts ?? [] where !codexSeen.contains(account.id) {
            let phantom = account.kind == .standard && !codexInstalled
                && account.identity == nil
            guard !phantom else { continue }
            let running = account.pids.isEmpty == false
            let login: UsageAccountPresentation.Login =
                account.state == .signedOut ? .requiresSignIn
                : account.identity != nil ? .saved : .unknown
            let row = AccountUsage(
                id: "codex:\(account.id)", provider: .codex, accountRef: account.id,
                label: account.label, plan: account.identity?.plan, windows: [], state: .notReporting,
                readAt: now, toolVersion: nil,
                authentication: account.identity?.mode == .apiKey ? .apiKey : .unknown)
            out.append(UsageAccountPresentation(
                usage: row, name: account.label, email: account.email,
                environment: running ? .app : account.kind == .standard ? .cli : codexAppInstalled ? .app : .cli,
                login: login, badgeActive: running, owner: .codex(account.id)))
        }
        return UsageProvider.allCases.flatMap { provider in
            out.filter { $0.usage.provider == provider }
        }
    }

    /// How one window reads on the bars. `current` renders normally; `lastKnown` is the greyed
    /// "value as last read"; `resetSinceRead` drops the number because its reset has passed.
    public enum UsageWindowDisplay: Equatable, Sendable {
        case current
        case lastKnown
        case resetSinceRead
    }

    /// Display decision for one window: a reset-passed window never shows a number, a failed or
    /// over-age/invalid reading shows last-known, everything else is current.
    public static func windowDisplay(_ usage: AccountUsage, _ window: UsageWindow,
                                     now: Date) -> UsageWindowDisplay {
        if window.isStale(now: now) { return .resetSinceRead }
        let age = now.timeIntervalSince(usage.readAt)
        if usage.state != .ok || !(0...verifiedAgeLimit).contains(age)
            || !(window.usedPercent.isFinite && (0...100).contains(window.usedPercent)) {
            return .lastKnown
        }
        return .current
    }

    /// Compact menu rows: at most 3. Common (scope-nil) windows keep original
    /// order; the most-constrained trustworthy fresh window leads, then the
    /// remaining common windows, then other trustworthy windows by used percent
    /// descending (original index breaks ties). Stale/invalid values never rank
    /// as current — if none are trustworthy the original order is returned and
    /// the existing dash rendering stands. Window data is never modified.
    public static func compactWindows(_ usage: AccountUsage, now: Date) -> [UsageWindow] {
        guard usage.state == .ok,
              (0...verifiedAgeLimit).contains(now.timeIntervalSince(usage.readAt))
        else { return Array(usage.windows.prefix(3)) }
        let valid = usage.windows.indices.filter {
            let window = usage.windows[$0]
            return window.usedPercent.isFinite && (0...100).contains(window.usedPercent)
                && !window.isStale(now: now)
        }
        let ranked = valid.sorted {
            let a = usage.windows[$0].usedPercent, b = usage.windows[$1].usedPercent
            return a != b ? a > b : $0 < $1
        }
        guard let first = ranked.first else { return Array(usage.windows.prefix(3)) }
        let common = valid.filter { $0 != first && usage.windows[$0].scope == nil }
        let scoped = ranked.filter { $0 != first && usage.windows[$0].scope != nil }
        return ([first] + common + scoped).prefix(3).map { usage.windows[$0] }
    }
}

extension UsagePresentations {
    /// The saved-App "not linked to CLI quota" note applies only while the saved
    /// account has no CLI profile binding — a bound row's windows are already that
    /// profile's reading. `usage.id` is `claude:<accountRef>`; `accountRef` is `app:<accountID>`.
    public static func claudeAppUnlinked(usage: AccountUsage, boundAccountIDs: Set<String>) -> Bool {
        guard usage.provider == .claude, usage.accountRef.hasPrefix("app:") else { return false }
        return !boundAccountIDs.contains(String(usage.accountRef.dropFirst("app:".count)))
    }
}
