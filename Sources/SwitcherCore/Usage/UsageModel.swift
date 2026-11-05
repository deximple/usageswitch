import Foundation

/// Where a usage reading came from.
public enum UsageProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex, cursor, grok, gemini, devin, opencode

    /// Claude and Codex are read through their own vendor CLIs; every other provider
    /// touches local credentials or network and requires an explicit consent grant.
    public var requiresConsent: Bool { self != .claude && self != .codex }
}

public extension SwitcherSettings {
    /// Effective consent set: known consent-required providers present in
    /// `usageConnections`, plus Cursor when its legacy flag is on. Unknown values
    /// in `usageConnections` are ignored, never granted.
    var enabledUsageProviders: Set<UsageProvider> {
        // cursorUsageEnabled is Cursor's sole SSOT — a stray "cursor" entry in
        // usageConnections never grants it (nor any non-consent provider).
        var out = Set((usageConnections ?? []).compactMap { UsageProvider(rawValue: $0) }
            .filter { $0.requiresConsent && $0 != .cursor })
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
    /// A window inside the plan ("Fable", "Auto", "API"); nil means the whole plan.
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
}

/// Why a reading isn't a number. These are the only reasons a user ever sees: channel messages
/// can carry account identity, so their text is never surfaced.
public enum UsageProblem: String, Codable, Sendable {
    case noSignIn, cliMissing, managed, refused, timeout, network, schemaChanged, rateLimited
    /// Installed but not connected (Cursor usage off). Created by orchestration, never by a collector.
    case connectionRequired
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

    /// Keeps the previous reading's windows on a failed/unavailable re-read — but only when the
    /// new reading is provably the same subscription login. Returns `self` unless:
    ///   - the new state is `.failed` or `.unavailable` (never `.ok` or `.notReporting`),
    ///   - the new reading is a subscription account with a non-empty identity key,
    ///   - a previous reading exists with the same id, authentication and identity key,
    ///     and it has windows.
    /// Fail-closed by design: a new login, an API-mode switch or an unknown-identity account
    /// (Claude/Cursor) can never show numbers that belong to a different login.
    public func retainingWindows(from previous: AccountUsage?) -> AccountUsage {
        switch state {
        case .failed, .unavailable: break
        default: return self
        }
        guard authentication == .subscription, let identityKey, !identityKey.isEmpty,
              let previous, previous.id == id, previous.authentication == authentication,
              previous.identityKey == identityKey, !previous.windows.isEmpty
        else { return self }
        return AccountUsage(id: id, provider: provider, accountRef: accountRef, label: label,
                            plan: plan ?? previous.plan, windows: previous.windows,
                            state: state, readAt: previous.readAt, toolVersion: toolVersion,
                            authentication: authentication, identityKey: identityKey)
    }
}
