import Foundation

public enum SnapshotState: String, Codable, Sendable {
    case ready, expired, corrupt
}

public struct AccountStatus: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// The shown name (the user's name for the account, else its default name).
    public let label: String
    /// The user's own name, if any (nil: `label` is the default name).
    public let customName: String?
    /// The name used without a custom one (email, else display name, else the start of the id).
    public let defaultName: String
    public let email: String?
    public let accountUuid: String
    public let orgUuid: String
    public let isActive: Bool
    public let snapshot: SnapshotState
    public let capturedAt: Date?
    public let sessionExpiresAt: Date?

    public init(id: String, label: String, customName: String?, defaultName: String, email: String?, accountUuid: String,
                orgUuid: String, isActive: Bool, snapshot: SnapshotState, capturedAt: Date?, sessionExpiresAt: Date?) {
        self.id = id; self.label = label; self.customName = customName; self.defaultName = defaultName; self.email = email
        self.accountUuid = accountUuid; self.orgUuid = orgUuid; self.isActive = isActive; self.snapshot = snapshot
        self.capturedAt = capturedAt; self.sessionExpiresAt = sessionExpiresAt
    }
}

public struct ClaudeStatus: Codable, Equatable, Sendable {
    public let installed: Bool
    public let running: Bool
    public let pid: Int?
    public let version: String?
    public let activeAccountUuid: String?
    public let activeOrgUuid: String?
    public let activeEmail: String?
    public let codeSessions: Int

    public init(installed: Bool, running: Bool, pid: Int?, version: String?, activeAccountUuid: String?,
                activeOrgUuid: String?, activeEmail: String?, codeSessions: Int) {
        self.installed = installed; self.running = running; self.pid = pid; self.version = version
        self.activeAccountUuid = activeAccountUuid; self.activeOrgUuid = activeOrgUuid
        self.activeEmail = activeEmail; self.codeSessions = codeSessions
    }
}

public struct SwitcherStatus: Codable, Equatable, Sendable {
    public let claude: ClaudeStatus
    public let accounts: [AccountStatus]
    public let relaunchers: [String]
    public let suspendedRelaunchers: [String]
    public let originalBackup: String?
    public let pendingJournal: Bool
    /// A journal that exists but cannot be decoded: only this kind can be set aside (audit B-03).
    public let journalUnreadable: Bool
    public let nativeMultiAccount: Bool
    public let warnings: [String]

    public init(claude: ClaudeStatus, accounts: [AccountStatus], relaunchers: [String], suspendedRelaunchers: [String],
                originalBackup: String?, pendingJournal: Bool, journalUnreadable: Bool = false,
                nativeMultiAccount: Bool, warnings: [String]) {
        self.claude = claude; self.accounts = accounts; self.relaunchers = relaunchers
        self.suspendedRelaunchers = suspendedRelaunchers; self.originalBackup = originalBackup
        self.pendingJournal = pendingJournal; self.journalUnreadable = journalUnreadable
        self.nativeMultiAccount = nativeMultiAccount; self.warnings = warnings
    }

    public var activeAccount: AccountStatus? { accounts.first(where: \.isActive) }
}

extension Switcher {
    public func status() -> SwitcherStatus {
        let all = accounts()
        let procs = table.all()
        let main = processes.mainProcesses(in: procs).first
        let active = activeIdentity()
        let now = clock.now()

        let codeEmails = codeSessionEmails(in: procs)
        let rows: [AccountStatus] = all.compactMap { account in
            let identity = account.identity
            // Listed accounts always have a generation; one removed a moment ago is simply left out.
            guard let snap = store.latest(for: identity) else { return nil }
            let isActive = active?.account == identity.accountUuid && active?.org == identity.orgUuid
            let state: SnapshotState
            if (try? store.verify(snap)) == nil {
                state = .corrupt
            } else if !store.needsRelogin(snap), let session = snap.manifest.session, session.isValid(at: now) {
                state = .ready
            } else {
                state = .expired
            }
            return AccountStatus(
                id: account.id, label: account.label, customName: account.customName,
                defaultName: SwitcherAccount.defaultName(for: identity), email: identity.email,
                accountUuid: identity.accountUuid, orgUuid: identity.orgUuid, isActive: isActive, snapshot: state,
                capturedAt: snap.manifest.capturedAt, sessionExpiresAt: snap.manifest.session?.expiresAt)
        }

        // An account that isn't saved yet is still named by the email its Code sessions show.
        let activeEmail = active.flatMap { a in
            all.first { $0.identity.accountUuid == a.account && $0.identity.orgUuid == a.org }?.identity.email
                ?? codeEmails[a.account]
        }
        let claude = ClaudeStatus(
            installed: FileManager.default.fileExists(atPath: env.claudeAppURL.path),
            running: main != nil, pid: main.map { Int($0.pid) }, version: app.bundleVersion(appURL: env.claudeAppURL),
            activeAccountUuid: active?.account, activeOrgUuid: active?.org, activeEmail: activeEmail,
            codeSessions: main.map { processes.codeSessionCLIs(in: procs, main: $0).count } ?? 0)

        var warnings: [String] = []
        let native = logSignals.current().nativeMultiAccount
        if native { warnings.append(L10n.t(.warnNativeMultiAccount)) }
        if main != nil && active == nil { warnings.append(L10n.t(.warnActiveUnknown)) }
        if swapper.journalPresent {
            warnings.append(L10n.t(.warnPendingJournal))
        }
        // While the 1.0 build holds its lock it is simply mid-switch; its journal is only stale once it lets go.
        if legacyRecoveryPending && !legacyLockHeldElsewhere() { warnings.append(L10n.t(.warnLegacyRecoveryPending)) }
        if !relaunchers.journal().isEmpty && !swapper.journalPresent {
            warnings.append(L10n.t(.warnRelaunchersSuspended, relaunchers.journal().map(\.label).joined(separator: ", ")))
        }
        if relaunchers.journalIsUnreadable() { warnings.append(L10n.t(.warnRelauncherJournalCorrupt)) }
        if !relaunchers.untrustedEntries().isEmpty {
            warnings.append(L10n.t(.warnUntrustedRelaunchers, relaunchers.untrustedEntries().map(\.label).joined(separator: ", ")))
        }
        if let a = active {
            let identity = identityFor(account: a.account, org: a.org, among: all, emails: codeEmails)
            if store.latest(for: identity) == nil {
                warnings.append(L10n.t(.warnActiveNotSaved, identity.email.map(Privacy.maskEmail) ?? String(a.account.prefix(8))))
            }
        }

        return SwitcherStatus(
            claude: claude, accounts: rows, relaunchers: relaunchers.discover().map(\.label),
            suspendedRelaunchers: relaunchers.journal().map(\.label), originalBackup: store.originalBackup()?.path,
            pendingJournal: swapper.pendingJournal() != nil,
            journalUnreadable: swapper.journalIsUnreadable(), nativeMultiAccount: native, warnings: warnings)
    }
}
