import Foundation

/// The last usage read, as `--cli usage` prints it. Display-safe identity, authentication and
/// window data only — never credentials — and the label is always email-masked, regardless of the
/// show-emails setting. Written by the app after every refresh;
/// the CLI reads the file and never touches the network, the Keychain or a vendor tool.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let accounts: [Account]

    public struct Account: Codable, Equatable, Sendable {
        /// Opaque account reference. Account-backed provider ids are ordinal in the snapshot.
        public let id: String
        /// Optional for compatibility with snapshots written before account references were exposed.
        public let accountRef: String?
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
        accounts = Self.makeAccounts(usages.map {
            ($0, UsageText.accountLabel($0, showEmails: false))
        })
    }

    /// Shared row mapping. Account-backed ids and refs are replaced with presentation-order
    /// ordinals; stable singleton provider refs remain useful and do not identify a user.
    private static func makeAccounts(_ rows: [(AccountUsage, String)]) -> [Account] {
        var ordinals = OpaqueOrdinals()
        return rows.map { usage, label in
            let identity = ordinals.identity(provider: usage.provider.rawValue,
                                             id: usage.id, accountRef: usage.accountRef)
            return account(usage, label: label, id: identity.id, accountRef: identity.accountRef)
        }
    }

    private static func account(_ usage: AccountUsage, label: String,
                               id: String, accountRef: String?) -> Account {
        let (state, problem): (String, String?)
        switch usage.state {
        case .ok: (state, problem) = ("ok", nil)
        case .notReporting: (state, problem) = ("notReporting", nil)
        case .unavailable(let p): (state, problem) = ("unavailable", p.rawValue)
        case .failed(let p): (state, problem) = ("failed", p.rawValue)
        }
        return Account(id: safeString(id), accountRef: accountRef.map(safeString),
                       provider: usage.provider.rawValue, label: safeString(Privacy.maskEmails(in: label)),
                       plan: usage.plan.map(safeString), state: state, problem: problem,
                       readAt: usage.readAt, toolVersion: usage.toolVersion.map(safeString),
                       authentication: usage.authentication.rawValue,
                       windows: usage.windows.map { window in
            Window(kind: window.kind.rawValue, scope: window.scope.map(safeString),
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

    /// Re-masks old labels and anonymizes legacy account ids before the CLI emits a loaded snapshot.
    public func masked() -> UsageSnapshot {
        var ordinals = OpaqueOrdinals()
        let safeAccounts = accounts.map { account in
            let identity = ordinals.identity(provider: account.provider,
                                             id: account.id, accountRef: account.accountRef)
            return Account(id: Self.safeString(identity.id),
                           accountRef: identity.accountRef.map(Self.safeString),
                           provider: Self.safeString(account.provider),
                           label: Self.safeString(Privacy.maskEmails(in: account.label)),
                           plan: account.plan.map(Self.safeString), state: account.state,
                           problem: account.problem, readAt: account.readAt,
                           toolVersion: account.toolVersion.map(Self.safeString),
                           authentication: account.authentication,
                           windows: account.windows.map {
                Window(kind: $0.kind, scope: $0.scope.map(Self.safeString),
                       durationMinutes: $0.durationMinutes, usedPercent: $0.usedPercent,
                       leftPercent: $0.leftPercent, resetsAt: $0.resetsAt)
            })
        }
        return UsageSnapshot(generatedAt: generatedAt, accounts: safeAccounts)
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
        accounts = Self.makeAccounts(presentations.map { ($0.usage, $0.name) })
    }

    /// Direct memberwise init used only by `masked()` — never writes a label it didn't mask.
    private init(generatedAt: Date, accounts: [Account]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    private struct OpaqueOrdinals {
        private var claudeApp = 0
        private var codex = 0

        mutating func identity(provider: String, id: String,
                               accountRef: String?) -> (id: String, accountRef: String?) {
            if provider == "claude",
               (id.hasPrefix("claude:app:") || id.hasPrefix("claude:app#")) {
                claudeApp += 1
                return ("claude:app#\(claudeApp)", "app#\(claudeApp)")
            }
            if provider == "codex" {
                codex += 1
                return ("codex#\(codex)", "codex#\(codex)")
            }
            return (id, accountRef)
        }
    }

    private static func safeString(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
            with: "••••", options: [.regularExpression, .caseInsensitive])
    }
}
