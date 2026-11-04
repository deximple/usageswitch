import Foundation

/// Where a usage reading came from.
public enum UsageProvider: String, Codable, Sendable {
    case claude, codex, cursor
}

/// One reported usage window (a session, a week, a billing month, …).
public struct UsageWindow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, weekly, monthly, other }

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

    public init(id: String, provider: UsageProvider, accountRef: String, label: String, plan: String?,
                windows: [UsageWindow], state: UsageState, readAt: Date, toolVersion: String?) {
        self.id = id; self.provider = provider; self.accountRef = accountRef; self.label = label
        self.plan = plan; self.windows = windows; self.state = state; self.readAt = readAt
        self.toolVersion = toolVersion
    }
}
