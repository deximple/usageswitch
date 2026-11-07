import Foundation

/// The last usage read, as `--cli usage` prints it. Display-safe identity, authentication and
/// window data only — never credentials — and the label is always email-masked, regardless of the
/// show-emails setting. Written by the app after every refresh;
/// the CLI reads the file and never touches the network, the Keychain or a vendor tool.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let accounts: [Account]

    public struct Account: Codable, Equatable, Sendable {
        /// "<provider>:<accountRef>", same id the app uses.
        public let id: String
        public let provider: String
        /// Always email-masked in the persisted file — the show-emails toggle never reaches disk.
        public let label: String
        public let plan: String?
        /// "ok" | "notReporting" | "unavailable" | "failed"; `problem` names the reason.
        public let state: String
        public let problem: String?
        public let readAt: Date
        public let toolVersion: String?
        /// `UsageAuthentication.rawValue` — absent in older files, additive.
        public let authentication: String?
        public let windows: [Window]
    }

    public struct Window: Codable, Equatable, Sendable {
        public let kind: String
        public let scope: String?
        public let durationMinutes: Int?
        public let usedPercent: Double
        public let leftPercent: Double
        public let resetsAt: Date?
    }

    /// `showEmails` is kept in the signature for call-site compatibility but is deliberately NOT
    /// honored: the persisted file and `--cli usage` output always mask emails. The visual
    /// reveal-emails setting is a UI concern; what leaves the app is always masked.
    public init(usages: [AccountUsage], generatedAt: Date, showEmails: Bool) {
        self.generatedAt = generatedAt
        accounts = usages.map { Self.account($0, label: UsageText.accountLabel($0, showEmails: false)) }
    }

    /// Shared row mapping: the usage row's own id/provider/state/problem/readAt/version/plan and
    /// windows (with derived leftPercent) plus its authentication rawValue. `label` arrives
    /// already masked from the caller — the raw initializer's collected label, or the
    /// presentation's current registry name.
    private static func account(_ usage: AccountUsage, label: String) -> Account {
        let (state, problem): (String, String?)
        switch usage.state {
        case .ok: (state, problem) = ("ok", nil)
        case .notReporting: (state, problem) = ("notReporting", nil)
        case .unavailable(let p): (state, problem) = ("unavailable", p.rawValue)
        case .failed(let p): (state, problem) = ("failed", p.rawValue)
        }
        return Account(id: usage.id, provider: usage.provider.rawValue, label: label,
                       plan: usage.plan, state: state, problem: problem,
                       readAt: usage.readAt, toolVersion: usage.toolVersion,
                       authentication: usage.authentication.rawValue,
                       windows: usage.windows.map { window in
            Window(kind: window.kind.rawValue, scope: window.scope,
                   durationMinutes: window.durationMinutes, usedPercent: window.usedPercent,
                   leftPercent: max(0, 100 - window.usedPercent), resetsAt: window.resetsAt)
        })
    }

    /// Writes through SafeFS so the allowlist applies; the store dir already exists once the app ran.
    public func write(env: SwitcherEnvironment, fs: SafeFS) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try fs.write(try encoder.encode(self), to: env.usageSnapshotFile)
    }

    /// Every account label email-masked; everything else copied verbatim. Idempotent — safe on
    /// labels that are already masked or never contained an email.
    public func masked() -> UsageSnapshot {
        UsageSnapshot(generatedAt: generatedAt, accounts: accounts.map {
            Account(id: $0.id, provider: $0.provider, label: Privacy.maskEmails(in: $0.label),
                    plan: $0.plan, state: $0.state, problem: $0.problem,
                    readAt: $0.readAt, toolVersion: $0.toolVersion,
                    authentication: $0.authentication, windows: $0.windows)
        })
    }

    /// The last written snapshot; nil when the app never finished a read (or the file is unreadable).
    /// Masked on load too, so snapshots written before masking-on-write still protect emails.
    public static func load(env: SwitcherEnvironment) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: env.usageSnapshotFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UsageSnapshot.self, from: data))?.masked()
    }

    /// Snapshot built from identity presentations — each row keeps its collected
    /// usage data but labels resolve through the CURRENT registry name (masked),
    /// never a stale collected label. No email/owner/identityKey is serialized.
    public init(presentations: [UsageAccountPresentation], generatedAt: Date) {
        self.generatedAt = generatedAt
        accounts = presentations.map { Self.account($0.usage, label: Privacy.maskEmails(in: $0.name)) }
    }

    /// Direct memberwise init used only by `masked()` — never writes a label it didn't mask.
    private init(generatedAt: Date, accounts: [Account]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }
}
