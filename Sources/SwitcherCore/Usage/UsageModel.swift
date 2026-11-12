import Foundation

/// Where a usage reading came from.
public enum UsageProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex, cursor, grok, gemini, antigravity, devin, opencode, copilot

    /// Claude and Codex are read through their own vendor CLIs; every other provider
    /// touches local credentials or network and requires an explicit consent grant.
    public var requiresConsent: Bool { self != .claude && self != .codex }

    /// Stored next to the provider in `usageConnections` when its connect dialog was re-described.
    /// A grant without it was given under the older wording and no longer counts.
    public var disclosureMarker: String? {
        switch self {
        case .antigravity: "antigravity.v2"
        case .gemini: "gemini.v2"
        default: nil
        }
    }

    /// The connect dialog's explanation: what is read, what is run, and where requests go.
    public var consentBodyKey: L10nKey? {
        switch self {
        case .claude, .codex: nil
        case .cursor: .usageCursorAlertBody
        case .grok: .uiConnectGrokBody
        case .gemini: .uiConnectGeminiBody
        case .antigravity: .uiConnectAntigravityBody
        case .devin: .uiConnectDevinBody
        case .opencode: .uiConnectOpenCodeBody
        // Reachable only once gh detection lands — consent wording exists ahead of it.
        case .copilot: .uiConnectCopilotBody
        }
    }
}

public extension SwitcherSettings {
    /// Effective consent set: known consent-required providers present in
    /// `usageConnections`, plus Cursor when its legacy flag is on. Unknown values
    /// in `usageConnections` are ignored, never granted. A provider with a `disclosureMarker`
    /// is granted only together with that marker.
    var enabledUsageProviders: Set<UsageProvider> {
        // cursorUsageEnabled is Cursor's sole SSOT — a stray "cursor" entry in
        // usageConnections never grants it (nor any non-consent provider).
        let stored = usageConnections ?? []
        var out = Set(stored.compactMap { UsageProvider(rawValue: $0) }
            .filter { $0.requiresConsent && $0 != .cursor }
            .filter { $0.disclosureMarker.map(stored.contains) ?? true })
        if cursorUsageEnabled == true { out.insert(.cursor) }
        return out
    }
}

/// How the account authenticates to the provider. Subscription and API-key accounts are billed
/// differently, so they must never be conflated; `unknown` means the channel didn't say.
public enum UsageAuthentication: String, Codable, Sendable {
    case subscription, apiKey, unknown
}

/// One reported usage window (a session, a week, a billing month, …).
public struct UsageWindow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, daily, weekly, monthly, other }

    /// Classified from `durationMinutes`, never from which slot a channel reported it in.
    public let kind: Kind
    /// A window inside the plan ("Fable", "Cursor Models", "Other Models"); nil means the whole plan.
    public let scope: String?
    public let durationMinutes: Int?
    /// 0…100.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(scope: String? = nil, durationMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.kind = Self.kind(durationMinutes: durationMinutes)
        self.scope = scope
        self.durationMinutes = durationMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public static func kind(durationMinutes: Int?) -> Kind {
        guard let minutes = durationMinutes else { return .other }
        switch minutes {
        case 1...300: return .session
        case 1440: return .daily
        case 10080: return .weekly
        case 40320...44640: return .monthly
        default: return .other
        }
    }

    /// The reset moment has passed, so the number no longer says where the window stands.
    public func isStale(now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// A number read at `readAt` still says something at `now`: until its reset, or — when the
    /// reset is unknown — for one window length. Unknown reset and length: never.
    public func isMeaningfulAsLastKnown(readAt: Date, now: Date) -> Bool {
        if let resetsAt { return resetsAt > now }
        guard let durationMinutes, durationMinutes > 0 else { return false }
        return now.timeIntervalSince(readAt) < TimeInterval(durationMinutes) * 60
    }
}

/// Why a reading isn't a number. These are the only reasons a user ever sees: channel messages
/// can carry account identity, so their text is never surfaced.
public enum UsageProblem: String, Codable, Sendable {
    case noSignIn, cliMissing, managed, refused, timeout, network, schemaChanged, rateLimited
    /// The provider rejected the stored sign-in (HTTP 401/403): it was revoked, replaced by
    /// another sign-in, or belongs to an account the endpoint won't serve. The vendor CLI's
    /// own login fixes it.
    case signInRejected
    case profileInvalid, unsupportedVersion
    /// Installed but not connected (Cursor usage off). Created by orchestration, never by a collector.
    case connectionRequired
    /// A stored credential parsed fine but is expired or too close to expiry, and no consented
    /// memory-only refresh (Gemini) could replace it. The vendor CLI refreshes its own sign-in.
    case signInExpired
    /// The vendor says this account can't use the feature (e.g. a retired plan).
    case notEligible
    /// The answer named another account than the one this row reads (a login changed mid-read).
    case accountMismatch
}

public enum UsageState: Equatable, Sendable {
    case ok, notReporting, unavailable(UsageProblem), failed(UsageProblem)
}

/// One account's usage as last read. Readings are never persisted.
public struct AccountUsage: Equatable, Identifiable, Sendable {
    /// "<provider>:<accountRef>"
    public let id: String
    public let provider: UsageProvider
    /// Codex account id; "cli" for Claude; "cursor" for Cursor.
    public let accountRef: String
    /// Shown name (masked per settings by the caller).
    public let label: String
    public let plan: String?
    public let windows: [UsageWindow]
    public let state: UsageState
    public let readAt: Date
    /// CLI/app version stamp, for diagnosing a schema change after a vendor update.
    public let toolVersion: String?
    /// How this account authenticates; drives label/badge wording and billing separation.
    public let authentication: UsageAuthentication
    /// Memory-only opaque hash tying a reading to a login — distinguishes two accounts that share a
    /// display name without persisting a personal identifier. Never written to the snapshot JSON.
    public let identityKey: String?

    public init(id: String, provider: UsageProvider, accountRef: String, label: String, plan: String?,
                windows: [UsageWindow], state: UsageState, readAt: Date, toolVersion: String?,
                authentication: UsageAuthentication = .unknown, identityKey: String? = nil) {
        self.id = id; self.provider = provider; self.accountRef = accountRef; self.label = label
        self.plan = plan; self.windows = windows; self.state = state; self.readAt = readAt
        self.toolVersion = toolVersion
        self.authentication = authentication; self.identityKey = identityKey
    }

    /// The id names one saved Claude account (`claude:app:<accountUuid>__<orgUuid>`), so a previous
    /// reading under the same id can only be that account's.
    public var pinsAccountIdentity: Bool { provider == .claude && accountRef.hasPrefix("app:") }

    /// A failed/unavailable row that still carries windows: they are the last successful read's.
    public var showsLastKnown: Bool { state != .ok && state != .notReporting && !windows.isEmpty }

    /// The problem out of `.failed`/`.unavailable`, nil for the other states.
    public var problem: UsageProblem? {
        switch state {
        case .unavailable(let problem), .failed(let problem): return problem
        default: return nil
        }
    }

    /// Keeps the previous reading's windows on a failed/unavailable re-read — but only when the
    /// new reading is provably the same login. Returns `self` unless:
    ///   - the new state is `.failed` or `.unavailable` (never `.ok` or `.notReporting`),
    ///   - the row pins account identity (`claude:app:*`) or is a subscription account with
    ///     a non-empty identity key,
    ///   - a previous reading exists with the same id (and, for subscription rows, the same
    ///     authentication and identity key), and it has windows that haven't reset at `now`.
    /// Fail-closed by design: a new login, an API-mode switch, an unknown-identity row
    /// (`claude:cli`/Cursor) or a broken profile binding (.accountMismatch/.profileInvalid)
    /// can never show numbers that belong to a different login.
    public func retainingWindows(from previous: AccountUsage?, now: Date) -> AccountUsage {
        switch state {
        case .failed, .unavailable: break
        default: return self
        }
        guard let previous, previous.id == id, !previous.windows.isEmpty else { return self }
        let sameLogin: Bool
        if pinsAccountIdentity {
            sameLogin = problem != .accountMismatch && problem != .profileInvalid
        } else {
            sameLogin = authentication == .subscription && identityKey?.isEmpty == false
                && previous.authentication == authentication && previous.identityKey == identityKey
        }
        guard sameLogin else { return self }
        let kept = previous.windows.filter { $0.isMeaningfulAsLastKnown(readAt: previous.readAt, now: now) }
        guard !kept.isEmpty else { return self }
        return AccountUsage(id: id, provider: provider, accountRef: accountRef, label: label,
                            plan: plan ?? previous.plan, windows: kept, state: state,
                            readAt: previous.readAt, toolVersion: toolVersion,
                            authentication: authentication, identityKey: identityKey)
    }
}
