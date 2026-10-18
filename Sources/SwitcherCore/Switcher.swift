import Darwin
import Foundation

public struct SwitcherOptions: Sendable {
    /// Without any `beforeQuit:` log line by then, terminate() had no effect → one SIGTERM.
    public var quitRequestGrace: TimeInterval = 8
    /// Overall wait for a normal quit (quit cleanup alone may take up to ~95 s).
    public var quitTimeout: TimeInterval = 150
    /// Wait after Claude vetoed the quit ("Claude is still working" dialog).
    public var quitVetoWait: TimeInterval = 600
    public var treeExitTimeout: TimeInterval = 30
    public var launchVerifyTimeout: TimeInterval = 60
    public var settle: TimeInterval = 20
    public var pollInterval: TimeInterval = 0.5
    public var minFreeDiskGB: Int = 8
    public var updateWaitTimeout: TimeInterval = 240
    /// ShipIt must stay idle this long after Claude exits before the profile is touched.
    public var shipItQuietWindow: TimeInterval = 3
    public var allowFaultInjection = false
    public var allowUIGroup = false

    public init() {}
}

public enum SwitchStep: Equatable, Sendable {
    case preflight
    case suspendingRelaunchers
    case quittingClaude
    case waitingForClaudeDialog(seconds: Int)
    case capturingOutgoing
    case backingUp
    case swapping
    case launching
    case verifying
    case rollingBack
    case restoringRelaunchers
    case done

    public var title: String {
        switch self {
        case .preflight: return L10n.t(.stepPreflight)
        case .suspendingRelaunchers: return L10n.t(.stepSuspendingRelaunchers)
        case .quittingClaude: return L10n.t(.stepQuittingClaude)
        case .waitingForClaudeDialog(let s): return L10n.t(.stepWaitingForClaudeDialog, s)
        case .capturingOutgoing: return L10n.t(.stepCapturingOutgoing)
        case .backingUp: return L10n.t(.stepBackingUp)
        case .swapping: return L10n.t(.stepSwapping)
        case .launching: return L10n.t(.stepLaunching)
        case .verifying: return L10n.t(.stepVerifying)
        case .rollingBack: return L10n.t(.stepRollingBack)
        case .restoringRelaunchers: return L10n.t(.stepRestoringRelaunchers)
        case .done: return L10n.t(.stepDone)
        }
    }
}

public enum InjectedFault: String, Sendable { case postSwapVerify = "post-swap-verify" }

public struct SwitchResult: Codable, Equatable, Sendable {
    public let outcome: String
    public let from: AccountIdentity?
    public let to: AccountIdentity
    public let recapturedOutgoing: Bool
    public let durationSeconds: Double
    /// Set when the outgoing sign-in could not be saved as a snapshot and was kept aside instead.
    public var displacedPrevious: String? = nil
}

public struct CodeProbeResult: Codable, Equatable, Sendable {
    public let found: Bool
    public let pid: Int?
    public let accountUuid: String?
    public let email: String?
    public let configDirSet: Bool
    public let matches: Bool
}

/// Orchestrates a Claude Desktop account switch (design D2). All waits are bounded; every exit path
/// restores suspended relaunchers; a failed verification rolls back to the exact previous files.
public final class Switcher: @unchecked Sendable {
    public let env: SwitcherEnvironment
    public let fs: SafeFS
    public let processes: ClaudeProcesses
    public let table: ProcessTable
    public let app: ClaudeAppControl
    public let runner: CommandRunner
    public let clock: Clock
    public let log: ClaudeLog
    public let store: SnapshotStore
    public let swapper: SwapEngine
    public let relaunchers: RelauncherGuard
    public var options: SwitcherOptions
    let freeDiskGB: @Sendable () -> Int
    private var lockFDStorage: Int32 = -1
    private let lockFDGuard = NSLock()
    private var legacyLockFDStorage: Int32 = -1
    private var lockFD: Int32 {
        get { lockFDGuard.lock(); defer { lockFDGuard.unlock() }; return lockFDStorage }
        set { lockFDGuard.lock(); lockFDStorage = newValue; lockFDGuard.unlock() }
    }
    private var legacyLockFD: Int32 {
        get { lockFDGuard.lock(); defer { lockFDGuard.unlock() }; return legacyLockFDStorage }
        set { lockFDGuard.lock(); legacyLockFDStorage = newValue; lockFDGuard.unlock() }
    }

    public init(
        env: SwitcherEnvironment = .live(),
        table: ProcessTable = SystemProcessTable(),
        app: ClaudeAppControl = SystemClaudeAppControl(),
        runner: CommandRunner = SystemCommandRunner(),
        clock: Clock = SystemClock(),
        options: SwitcherOptions = SwitcherOptions(),
        freeDiskGB: (@Sendable () -> Int)? = nil
    ) {
        self.env = env
        self.options = options
        let fs = SafeFS(env: env, allowUIGroup: options.allowUIGroup)
        self.fs = fs
        self.table = table
        let processes = ClaudeProcesses(table: table, mainExecutable: env.claudeMainExecutable.path)
        self.processes = processes
        self.app = app
        self.runner = runner
        self.clock = clock
        log = ClaudeLog(logsDir: env.claudeLogsDir)
        store = SnapshotStore(env: env, fs: fs)
        swapper = SwapEngine(env: env, fs: fs, isClaudeRunning: { processes.anyClaudeNamedProcess() })
        relaunchers = RelauncherGuard(env: env, fs: fs, runner: runner)
        let userData = env.claudeUserData
        self.freeDiskGB = freeDiskGB ?? {
            var s = statfs()
            guard statfs(userData.deletingLastPathComponent().path, &s) == 0 else { return Int.max }
            return Int(UInt64(s.f_bavail) * UInt64(s.f_bsize) / 1_000_000_000)
        }
    }

    // MARK: - Queries

    /// Every Claude Desktop sign-in saved in this app, named by the user's name or its default name,
    /// in name order.
    public func accounts() -> [SwitcherAccount] {
        let names = AccountNames.load(env: env) ?? [:]
        let identities = store.savedIdentities()
        // A default name another account also shows (one email in two organizations) gets its organization.
        let shown = identities.map { SwitcherAccount.fold(names[$0.key] ?? SwitcherAccount.defaultName(for: $0)) }
        let counts = Dictionary(shown.map { ($0, 1) }, uniquingKeysWith: +)
        return identities.enumerated()
            .map { index, identity in
                SwitcherAccount(identity: identity, customName: names[identity.key],
                                distinguishOrg: names[identity.key] == nil && counts[shown[index], default: 0] > 1)
            }
            .sorted { lhs, rhs in
                let order = lhs.label.localizedStandardCompare(rhs.label)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    /// An account by id, or by a name it answers to (shown name, default name or email; case is ignored).
    /// A name that fits more than one account is refused rather than guessed.
    public func resolve(_ query: String) throws -> SwitcherAccount {
        let all = accounts()
        if let exact = all.first(where: { $0.id == query }) { return exact }
        let matches = all.filter { $0.answers(to: query) }
        guard matches.count < 2 else { throw SwitcherError.ambiguousAccount(query) }
        guard let match = matches.first else { throw SwitcherError.unknownAccount(query) }
        return match
    }

    public func account(matching query: String) -> SwitcherAccount? { try? resolve(query) }

    /// Gives an account the user's own name; nil or blank goes back to its default name (always allowed).
    /// A new name may not be another account's shown name, default name or email, so those keep finding it.
    @discardableResult
    public func renameAccount(_ query: String, to name: String?) throws -> SwitcherAccount {
        let account = try resolve(query)
        let newName = try AccountNames.validated(name)
        if let newName, accounts().contains(where: { $0.id != account.id && $0.answers(to: newName) }) {
            throw SwitcherError.duplicateAccountName(newName)
        }
        try AccountNames.update(env: env, fs: fs) { $0[account.id] = newName }
        return accounts().first { $0.id == account.id } ?? SwitcherAccount(identity: account.identity, customName: newName)
    }

    /// Deletes an account's saved sign-in (not allowed for the account Claude is using). Runs under the
    /// switch lock, so it never pulls a snapshot out from under a switch that is already under way.
    public func removeSaved(_ query: String) throws {
        let identity = try resolve(query).identity
        try acquireLock()
        defer { releaseLock() }
        guard !isInUse(identity) else { throw SwitcherError.cannotRemoveActive }
        // While the 1.0 import is unfinished, a later retry must not bring this sign-in back.
        try store.markLegacyFolderHandled(identity.key)
        try store.remove(identity)
        // The name goes with the sign-in. The removal already happened, so a failure here is not reported:
        // a leftover entry only names the account again if it is saved again later.
        try? AccountNames.update(env: env, fs: fs) { $0.removeValue(forKey: identity.key) }
    }

    /// The account Claude uses, or — when the log can't tell (signed out, mid-swap, rotated logs) — the
    /// account its config last knew.
    func isInUse(_ identity: AccountIdentity) -> Bool {
        if let active = activeIdentity() { return active.account == identity.accountUuid && active.org == identity.orgUuid }
        let known = (try? ClaudeConfig.load(env.claudeConfigJSON))?.lastKnownAccountUuid
        return known == identity.accountUuid
    }

    /// The personal 1.0 build was interrupted mid-swap; until it recovers, its recovery would undo our writes.
    public var legacyRecoveryPending: Bool {
        env.hasSeparateLegacyStore && FileManager.default.fileExists(atPath: env.legacyJournalFile.path)
    }

    /// Whether some other process holds the 1.0 build's switch lock right now (it is mid-switch, so its journal
    /// is expected). Probed with a shared, non-blocking lock that is released at once.
    func legacyLockHeldElsewhere() -> Bool {
        guard env.hasSeparateLegacyStore else { return false }
        let fd = open(env.legacyLockFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN)
        return false
    }

    func restorableSuspendedRelaunchers() -> [String] {
        let untrusted = Set(relaunchers.untrustedEntries().map(\.label))
        return relaunchers.journal().map(\.label).filter { !untrusted.contains($0) }
    }

    /// Identity Claude Desktop is (or was last) signed in as: the config marker and the newest log
    /// evidence must agree, and no logout may have followed.
    public func activeIdentity() -> (account: String, org: String)? {
        guard let config = try? ClaudeConfig.load(env.claudeConfigJSON),
              let known = config.lastKnownAccountUuid,
              let signal = log.latestIdentity(),
              signal.accountUuid == known, !signal.loggedOutAfter else { return nil }
        return (signal.accountUuid, signal.orgUuid)
    }

    /// - Parameter emails: account uuid → email seen in running Code-tab sessions, for accounts nobody listed.
    func identityFor(account: String, org: String, among accounts: [SwitcherAccount],
                     emails: [String: String] = [:]) -> AccountIdentity {
        guard let known = accounts.map(\.identity).first(where: { $0.accountUuid == account && $0.orgUuid == org }) else {
            return AccountIdentity(accountUuid: account, orgUuid: org, email: emails[account], displayName: nil)
        }
        // A sign-in first saved without an email gets one once a Code session shows it (listed emails always win).
        guard known.email == nil, let email = emails[account] else { return known }
        return AccountIdentity(accountUuid: known.accountUuid, orgUuid: known.orgUuid, email: email, displayName: known.displayName)
    }

    /// Emails of the accounts that Claude's running Code-tab sessions are signed in as (read before Claude quits,
    /// so a newly saved sign-in is named by its email rather than an id prefix).
    func codeSessionEmails() -> [String: String] {
        let procs = table.all()
        guard let main = processes.mainProcesses(in: procs).first else { return [:] }
        var emails: [String: String] = [:]
        for cli in processes.codeSessionCLIs(in: procs, main: main) {
            let values = table.environmentValues(pid: cli.pid, keys: ClaudeProcesses.codeIdentityKeys)
            if let account = values["CLAUDE_CODE_ACCOUNT_UUID"], let email = values["CLAUDE_CODE_USER_EMAIL"], !email.isEmpty {
                emails[account] = email
            }
        }
        return emails
    }

    /// Repairs leftovers from an interrupted run: restores relaunchers and rolls back a half-done swap
    /// (only while Claude is not running).
    public struct RecoveryReport: Sendable, Equatable {
        public let notes: [String]
        /// Something could not be settled (locked, failed, or a journal remains).
        public let needsAttention: Bool
    }

    /// Recovery with a machine-readable outcome (the CLI exit code uses it).
    public func recover() -> RecoveryReport {
        let run = runRecovery()
        return RecoveryReport(
            notes: run.notes,
            needsAttention: run.locked || run.failed || swapper.journalPresent || relaunchers.journalIsUnreadable()
                || !restorableSuspendedRelaunchers().isEmpty || legacyRecoveryPending)
    }

    @discardableResult
    public func recoverIfNeeded() -> [String] { runRecovery().notes }

    private func runRecovery() -> (notes: [String], locked: Bool, failed: Bool) {
        do {
            try acquireLock()
        } catch SwitcherError.anotherSwitchInProgress {
            return ([L10n.t(.recoverLocked)], true, false)
        } catch {
            // Not "busy": something is wrong with a lock file, and every switch will fail the same way.
            return ([L10n.t(.recoverFailed, (error as? SwitcherError)?.description ?? String(describing: error))], true, true)
        }
        defer { releaseLock() }
        var notes: [String] = []
        var failed = false
        try? fs.remove(env.tmpDir)
        store.sanitizeOriginalBackup()
        let imported = store.importLegacySnapshotsIfNeeded()
        if imported.failed > 0 {
            failed = true
            notes.append(L10n.t(.recoverImportFailed, imported.failed))
        }
        // The personal build's unfinished swap is newer than any of ours (ours only start while its journal is
        // absent and its lock is held), so it has to be undone first. Until then our journal and our suspended
        // relaunchers stay untouched: undoing ours first could put back a sign-in that its rollback then discards.
        if legacyRecoveryPending {
            notes.append(L10n.t(.warnLegacyRecoveryPending))
            return (notes, false, failed)
        }
        if swapper.journalPresent && processes.mainProcess() == nil {
            do {
                switch try swapper.resolvePending() {
                case .rolledBack: notes.append(L10n.t(.recoverRolledBack))
                case .committed: notes.append(L10n.t(.recoverCommitted))
                case nil: break
                }
            } catch {
                failed = true
                notes.append(L10n.t(.recoverFailed, String(describing: error)))
            }
        }
        if swapper.journalPresent {
            // Files may be mixed; keep Claude's relaunchers suspended until the journal is settled.
            if !relaunchers.journal().isEmpty { notes.append(L10n.t(.recoverRelaunchersHeld)) }
            return (notes, false, failed)
        }
        if relaunchers.journalIsUnreadable() { notes.append(L10n.t(.recoverRelauncherJournalUnreadable)) }
        let restored = relaunchers.restoreAll()
        if !restored.isEmpty { notes.append(L10n.t(.recoverRelaunchersRestored, restored.map(\.label).joined(separator: ", "))) }
        // Untrusted entries are reported by status() with their own warning; only these can still be restored.
        let stillSuspended = restorableSuspendedRelaunchers()
        if !stillSuspended.isEmpty {
            notes.append(L10n.t(.warnRelaunchersSuspended, stillSuspended.joined(separator: ", ")))
        }
        return (notes, false, failed)
    }

    // MARK: - Switch

    /// - Parameter force: re-apply the saved sign-in even when it is already the active account (repair).
    public func switchTo(
        _ accountID: String, confirmed: Bool, force: Bool = false, fault: InjectedFault? = nil,
        progress: @escaping (SwitchStep) -> Void = { _ in }
    ) throws -> SwitchResult {
        let started = clock.now()
        let all = accounts()
        let target = try resolve(accountID)
        let identity = target.identity
        progress(.preflight)
        let active = activeIdentity()
        let running = processes.mainProcess() != nil
        if !force, running, let active, active.account == identity.accountUuid, active.org == identity.orgUuid {
            return SwitchResult(outcome: "already_active", from: identity, to: identity, recapturedOutgoing: false,
                                durationSeconds: clock.now().timeIntervalSince(started))
        }
        guard let snapshot = store.latest(for: identity) else { throw SwitcherError.notEnrolled(label: target.label) }
        try store.verify(snapshot)
        let liveMeta = try? CookieJar.meta(of: env.claudeCookies)
        guard CookieJar.isCompatible(snapshot: snapshot.manifest.cookieMeta, live: liveMeta) else {
            throw SwitcherError.snapshotIncompatible(L10n.t(.reasonSchemaNewer, snapshot.manifest.cookieMeta.version, liveMeta?.version ?? 0))
        }
        let emails = codeSessionEmails()
        let from = active.map { identityFor(account: $0.account, org: $0.org, among: all, emails: emails) }

        var recaptured = false
        var displaced: URL?
        // Re-checked under the lock: the saved sign-in may have been removed since the check above.
        let stillSaved = { [store] in
            guard let current = store.latest(for: identity) else { throw SwitcherError.notEnrolled(label: target.label) }
            try store.verify(current)
        }
        try withExclusiveSession(confirmed: confirmed, progress: progress, precheck: stillSaved) { quit in
            recaptured = try recaptureOutgoing(quitClean: quit.clean, accounts: all, emails: emails, progress: progress)
            // A still-signed-in jar that could not be saved keeps its files aside instead of losing them.
            if !recaptured, let name = unsavedSignInName(accounts: all) {
                displaced = env.displacedDir.appendingPathComponent("\(name)-\(Int(clock.now().timeIntervalSince1970))")
            }
            progress(.backingUp)
            try store.makeOriginalBackupIfNeeded(from: env.claudeUserData, now: clock.now())
            progress(.swapping)
            // A recapture of the same identity (forced re-apply) produces a fresher generation; use the newest.
            let install = store.latest(for: identity) ?? snapshot
            if install != snapshot { try store.verify(install) }
            try stageAndInstall(cookiesFrom: install.dir, mutation: .restore(accountUuid: identity.accountUuid), stripAuthRows: false)
            try swapper.setKeepPrevious(displaced)
            try launchAndVerify(target: identity, previous: from, fault: fault, keepPreviousAt: displaced, progress: progress)
        }
        progress(.done)
        var result = SwitchResult(outcome: "switched", from: from, to: identity, recapturedOutgoing: recaptured,
                                  durationSeconds: clock.now().timeIntervalSince(started))
        if let displaced, FileManager.default.fileExists(atPath: displaced.path) {
            store.stripTokenCaches(inConfigAt: displaced.appendingPathComponent(SnapshotItems.config))
            result.displacedPrevious = displaced.path
        }
        return result
    }

    /// Saves Claude's current sign-in as a snapshot (quit → copy → relaunch → verify same account).
    public func captureCurrent(confirmed: Bool, progress: @escaping (SwitchStep) -> Void = { _ in }) throws -> Snapshot {
        let all = accounts()
        guard let active = activeIdentity() else { throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonNoSignInSignal)) }
        let identity = identityFor(account: active.account, org: active.org, among: all, emails: codeSessionEmails())
        var captured: Snapshot?
        try withExclusiveSession(confirmed: confirmed, progress: progress) { quit in
            guard quit.clean else { throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonUncleanQuitNotSaved)) }
            // Settling a leftover journal may have changed the live account since we looked.
            guard let now = activeIdentity(), now.account == identity.accountUuid, now.org == identity.orgUuid else {
                throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonAccountChanged))
            }
            progress(.capturingOutgoing)
            guard try recaptureGuardPasses() else {
                throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonCookieInvalidOrLoggedOut))
            }
            let snap = try store.capture(from: env.claudeUserData, identity: identity,
                                         claudeVersion: app.bundleVersion(appURL: env.claudeAppURL), now: clock.now())
            captured = snap
            progress(.backingUp)
            try store.makeOriginalBackupIfNeeded(from: env.claudeUserData, now: clock.now())
            do {
                try launchAndVerify(target: identity, previous: identity, fault: nil, progress: progress)
            } catch {
                try? fs.remove(snap.dir)   // never keep a generation whose account could not be confirmed
                throw error
            }
        }
        progress(.done)
        guard let captured else { throw SwitcherError.io(L10n.t(.reasonSaveFailed)) }
        return captured
    }

    /// Prepares a fresh sign-in: saves the current account, removes only the local sign-in rows and markers
    /// (no server logout), and relaunches Claude at its login screen.
    public func beginEnrollment(confirmed: Bool, progress: @escaping (SwitchStep) -> Void = { _ in }) throws {
        let all = accounts()
        let emails = codeSessionEmails()
        try withExclusiveSession(confirmed: confirmed, progress: progress) { quit in
            let saved = try recaptureOutgoing(quitClean: quit.clean, accounts: all, emails: emails, progress: progress)
            // Never clear the only copy of a sign-in: proceed only if it was just saved, is already saved, or
            // the live jar holds no valid sign-in.
            if !saved, unsavedSignInName(accounts: all) != nil { throw SwitcherError.cannotSaveCurrentLogin }
            progress(.backingUp)
            try store.makeOriginalBackupIfNeeded(from: env.claudeUserData, now: clock.now())
            progress(.swapping)
            try stageAndInstall(cookiesFrom: env.claudeUserData, mutation: .clearForLogin, stripAuthRows: true)
            try swapper.commit()
            progress(.launching)
            try app.launch(appURL: env.claudeAppURL)
        }
        progress(.done)
    }

    // MARK: - Code tab probe (design D5-4)

    /// Finds a Code-tab CLI started after `since` and compares its identity env (only those keys are read).
    public func probeCodeSession(expected: AccountIdentity, since: Date, trigger: Bool, timeout: TimeInterval) -> CodeProbeResult {
        // Only nudge an already running Claude: opening the URL could otherwise launch Claude itself.
        if trigger, processes.mainProcess() != nil, let url = URL(string: "claude://code/continue?session=last") {
            _ = app.open(url: url)
        }
        let deadline = clock.now().addingTimeInterval(timeout)
        while true {
            let procs = table.all()
            if let main = processes.mainProcesses(in: procs).first {
                let fresh = processes.codeSessionCLIs(in: procs, main: main).filter { $0.startTime >= since.addingTimeInterval(-1) }
                for cli in fresh {
                    let envs = table.environmentValues(pid: cli.pid, keys: ClaudeProcesses.codeIdentityKeys)
                    guard let acct = envs["CLAUDE_CODE_ACCOUNT_UUID"] else { continue }
                    return CodeProbeResult(
                        found: true, pid: Int(cli.pid), accountUuid: acct, email: envs["CLAUDE_CODE_USER_EMAIL"],
                        configDirSet: envs["CLAUDE_CONFIG_DIR"] != nil, matches: acct == expected.accountUuid)
                }
            }
            if clock.now() >= deadline { break }
            clock.sleep(options.pollInterval)
        }
        return CodeProbeResult(found: false, pid: nil, accountUuid: nil, email: nil, configDirSet: false, matches: false)
    }

    // MARK: - Session wrapper

    struct QuitOutcome { let clean: Bool }

    /// Lock → preflight → suspend relaunchers → quit Claude → body → always restore relaunchers.
    /// `precheck` runs under the lock, before anything is suspended or quit.
    func withExclusiveSession(
        confirmed: Bool, progress: @escaping (SwitchStep) -> Void, precheck: () throws -> Void = {},
        _ body: (QuitOutcome) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: env.claudeAppURL.path) else { throw SwitcherError.claudeNotInstalled }
        let free = freeDiskGB()
        guard free >= options.minFreeDiskGB else {
            throw SwitcherError.insufficientDisk(freeGB: free, requiredGB: options.minFreeDiskGB)
        }
        if let main = processes.mainProcess() {
            let sessions = processes.codeSessionCLIs(in: table.all(), main: main).count
            if sessions > 0 && !confirmed { throw SwitcherError.needsConfirmation(codeSessions: sessions) }
        }
        guard !isShipItRunning() else { throw SwitcherError.updateInProgress }
        // Design D2-0: a staged update would be installed (and Claude relaunched) by ShipIt when Claude quits.
        guard !updatePending() else { throw SwitcherError.updatePending }
        try acquireLock()
        defer { releaseLock() }
        // The personal build crashed mid-swap: its own recovery would undo whatever this switch writes.
        guard !legacyRecoveryPending else { throw SwitcherError.legacyRecoveryPending }
        try precheck()

        progress(.suspendingRelaunchers)
        // Registered before suspending: a partial failure must still re-bootstrap the agents already booted out.
        // While a swap journal is unresolved the files may be mixed, so the relaunchers stay suspended.
        defer {
            if !swapper.journalPresent {
                progress(.restoringRelaunchers)
                relaunchers.restoreAll()
            }
        }
        guard !relaunchers.journalIsUnreadable() else {
            throw SwitcherError.io(L10n.t(.reasonRelauncherJournalCorruptStop))
        }
        _ = try relaunchers.suspendAll()
        progress(.quittingClaude)
        let wasRunning = processes.mainProcess() != nil
        do {
            var quit = try quitClaude(progress: progress)
            if try waitForShipItQuiet(), processes.mainProcess() != nil {
                // ShipIt installed an update and relaunched Claude; quit the fresh instance too.
                quit = try quitClaude(progress: progress)
            }
            try swapper.resolvePending()
            try body(quit)
        } catch {
            // Never leave Claude closed after a failure, as long as its files are consistent.
            if wasRunning, processes.mainProcess() == nil, !swapper.journalPresent {
                try? app.launch(appURL: env.claudeAppURL)
            }
            throw error
        }
    }

    /// Waits until Claude's ShipIt updater has been idle for `shipItQuietWindow`. Returns true if it ran.
    func waitForShipItQuiet() throws -> Bool {
        let deadline = clock.now().addingTimeInterval(options.updateWaitTimeout)
        var ran = false
        var quietSince: Date?
        while true {
            if isShipItRunning() {
                ran = true
                quietSince = nil
            } else if let since = quietSince {
                if clock.now().timeIntervalSince(since) >= options.shipItQuietWindow { return ran }
            } else {
                quietSince = clock.now()
                if options.shipItQuietWindow <= 0 { return ran }
            }
            if clock.now() >= deadline { throw SwitcherError.updateInProgress }
            clock.sleep(min(1, max(options.pollInterval, 0.1)))
        }
    }

    // MARK: - Steps

    /// Non-nil when the live jar still holds a valid sessionKey that has no usable snapshot. "Signed in" is
    /// read from the jar itself, not inferred from logs, so an unknown identity is never treated as signed out.
    /// Returns a directory-safe name for keeping the files aside.
    func unsavedSignInName(accounts: [SwitcherAccount]) -> String? {
        guard let info = try? CookieJar.sessionInfo(of: env.claudeCookies), info.isValid(at: clock.now()) else { return nil }
        guard let active = activeIdentity() else { return "unknown" }
        let identity = identityFor(account: active.account, org: active.org, among: accounts)
        return store.hasUsableSnapshot(for: identity, now: clock.now()) ? nil : identity.key
    }

    func recaptureOutgoing(quitClean: Bool, accounts: [SwitcherAccount], emails: [String: String] = [:],
                           progress: (SwitchStep) -> Void) throws -> Bool {
        guard quitClean, let active = activeIdentity(), try recaptureGuardPasses() else { return false }
        progress(.capturingOutgoing)
        let identity = identityFor(account: active.account, org: active.org, among: accounts, emails: emails)
        _ = try store.capture(from: env.claudeUserData, identity: identity,
                              claudeVersion: app.bundleVersion(appURL: env.claudeAppURL), now: clock.now())
        return true
    }

    /// Design D2-5: the live jar must hold a valid sessionKey row and no logout may follow the last sign-in.
    func recaptureGuardPasses() throws -> Bool {
        guard let info = try? CookieJar.sessionInfo(of: env.claudeCookies), info.isValid(at: clock.now()) else { return false }
        // Anchored on the last `Initialization succeeded`, not on token lookups (design D2-5).
        return log.signedInSinceLastInit()
    }

    func stageAndInstall(cookiesFrom source: URL, mutation: ClaudeConfig.Mutation, stripAuthRows: Bool) throws {
        let staging = try swapper.prepareStaging()
        for name in SnapshotItems.cookieGroup {
            let src = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) { try fs.copy(src, to: staging.appendingPathComponent(name)) }
        }
        if stripAuthRows {
            try CookieJar.removeAuthRows(fromStagedCopy: staging.appendingPathComponent("Cookies"), stagingDir: staging, fs: fs)
        }
        guard let liveConfig = FileManager.default.contents(atPath: env.claudeConfigJSON.path) else {
            throw SwitcherError.io(L10n.t(.reasonConfigUnreadable))
        }
        try fs.write(try ClaudeConfig.mutated(liveConfig, mutation), to: staging.appendingPathComponent(SnapshotItems.config))
        do {
            try swapper.install(names: [SnapshotItems.config] + SnapshotItems.cookieGroup)
        } catch SwitcherError.swapInterrupted {
            // Something relaunched Claude mid-swap: quit it again and roll back while we still hold the session.
            if (try? quitClaude(progress: { _ in })) != nil, processes.mainProcess() == nil, (try? swapper.rollback()) != nil {
                throw SwitcherError.claudeStartedDuringSwap
            }
            throw SwitcherError.swapInterrupted
        }
    }

    func launchAndVerify(
        target: AccountIdentity, previous: AccountIdentity?, fault: InjectedFault?, keepPreviousAt: URL? = nil,
        progress: @escaping (SwitchStep) -> Void
    ) throws {
        progress(.launching)
        let cursor = ClaudeLog.Cursor(log: log)
        do {
            try app.launch(appURL: env.claudeAppURL)
            progress(.verifying)
            var verdict = waitForVerdict(cursor: cursor, target: target)
            if case .success = verdict, fault == .postSwapVerify, options.allowFaultInjection {
                verdict = .failure(reason: L10n.t(.reasonFaultInjected), needsRelogin: false)
            }
            switch verdict {
            case .success:
                // Verified: from here on errors are cleanup problems, never a reason to roll back.
                try? swapper.commit(keepPreviousAt: keepPreviousAt)
            case .failure(let reason, let needsRelogin):
                if needsRelogin { store.markNeedsRelogin(target) }
                throw SwitcherError.verificationFailed(reason, rollback: rollbackAfterFailedLaunch(previous: previous, progress: progress))
            case .pending:
                throw SwitcherError.verificationFailed(L10n.t(.reasonNoVerdict, Int(options.launchVerifyTimeout)),
                                                       rollback: rollbackAfterFailedLaunch(previous: previous, progress: progress))
            }
        } catch let e as SwitcherError {
            if case .verificationFailed = e { throw e }
            if swapper.journalPresent {
                _ = rollbackAfterFailedLaunch(previous: previous, progress: progress)
            }
            throw e
        }
    }

    func waitForVerdict(cursor: ClaudeLog.Cursor, target: AccountIdentity) -> LaunchVerdict {
        let deadline = clock.now().addingTimeInterval(options.launchVerifyTimeout + options.settle)
        while true {
            cursor.poll()
            let verdict = LaunchVerdict.evaluate(
                lines: cursor.collected, targetAccount: target.accountUuid, targetOrg: target.orgUuid,
                now: clock.now(), settle: options.settle)
            switch verdict {
            case .success:
                if let main = processes.mainProcess() {
                    guard main.ppid == 1 else {
                        return .failure(reason: L10n.t(.reasonNotLaunchdChild, Int(main.ppid)), needsRelogin: false)
                    }
                    let leaked = processes.leakedLaunchKeys(main: main)
                    if !leaked.isEmpty {
                        return .failure(reason: L10n.t(.reasonLeakedEnv, leaked.sorted().joined(separator: ", ")), needsRelogin: false)
                    }
                }
                let config = try? ClaudeConfig.load(env.claudeConfigJSON)
                guard config?.lastKnownAccountUuid == target.accountUuid else {
                    return .failure(reason: L10n.t(.reasonMarkerMismatch), needsRelogin: false)
                }
                return verdict
            case .failure: return verdict
            case .pending:
                if clock.now() >= deadline { return .pending }
                clock.sleep(options.pollInterval)
            }
        }
    }

    /// Quit the freshly launched (wrong) Claude, restore the previous files, relaunch, and — when the previous
    /// account is known — confirm Claude came back as that account.
    func rollbackAfterFailedLaunch(previous: AccountIdentity?, progress: @escaping (SwitchStep) -> Void) -> RollbackOutcome {
        progress(.rollingBack)
        // Decided to undo: if the quit below fails, later recovery must roll back, not commit the failed switch.
        do { try swapper.markForRollback() } catch { return .failed }
        if processes.mainProcess() != nil {
            do {
                _ = try quitClaude(progress: progress)
                // The failed launch may have staged an update; ShipIt then installs and relaunches on quit.
                if try waitForShipItQuiet(), processes.mainProcess() != nil { _ = try quitClaude(progress: progress) }
            } catch { return .failed }
        }
        do { try swapper.rollback() } catch { return .failed }
        let cursor = ClaudeLog.Cursor(log: log)
        do { try app.launch(appURL: env.claudeAppURL) } catch { return .unverified }
        guard let previous else { return .unverified }
        progress(.verifying)
        if case .success = waitForVerdict(cursor: cursor, target: previous) { return .verified }
        return .unverified
    }

    @discardableResult
    func quitClaude(progress: (SwitchStep) -> Void) throws -> QuitOutcome {
        let procs = table.all()
        guard let main = processes.mainProcesses(in: procs).first else {
            return QuitOutcome(clean: !processes.anyClaudeNamedProcess())
        }
        let tree = [main] + processes.descendants(of: main.pid, in: procs)
        let cursor = ClaudeLog.Cursor(log: log)
        let t0 = clock.now()
        _ = app.requestQuit(pid: main.pid)
        var sigtermSent = false
        var vetoed = false
        while table.all().contains(where: { $0.pid == main.pid && $0.startTime == main.startTime }) {
            cursor.poll()
            let elapsed = clock.now().timeIntervalSince(t0)
            if cursor.collected.contains(where: { $0.text.contains(ClaudeLog.vetoMarker) }) {
                vetoed = true
                progress(.waitingForClaudeDialog(seconds: Int(elapsed)))
            }
            let handled = cursor.collected.contains { $0.text.contains(ClaudeLog.quitHandlerMarker) }
            if !handled && !sigtermSent && elapsed > options.quitRequestGrace {
                _ = app.signalTerminate(pid: main.pid)
                sigtermSent = true   // at most one signal, whatever kill(2) returned
            }
            if elapsed > (vetoed ? options.quitVetoWait : options.quitTimeout) {
                throw vetoed ? SwitcherError.quitVetoed(waitedSeconds: Int(elapsed)) : SwitcherError.quitTimeout(waitedSeconds: Int(elapsed))
            }
            clock.sleep(options.pollInterval)
        }
        let treeDeadline = clock.now().addingTimeInterval(options.treeExitTimeout)
        while !processes.blockingProcesses(snapshotTree: tree, now: table.all()).isEmpty || processes.anyClaudeNamedProcess() {
            if clock.now() >= treeDeadline { throw SwitcherError.quitTimeout(waitedSeconds: Int(clock.now().timeIntervalSince(t0))) }
            clock.sleep(options.pollInterval)
        }
        cursor.poll()
        // Clean = the app finished its quit cleanup. (Observed on 2.42304.0: `updaterRunningInstance` keeps the
        // old pid after a clean quit, so it is not a usable signal.)
        let clean = cursor.collected.contains { line in ClaudeLog.cleanQuitMarkers.contains { line.text.contains($0) } }
        return QuitOutcome(clean: clean)
    }

    // MARK: - Updates (design D2-0)

    static let shipItLabel = "com.anthropic.claudefordesktop.ShipIt"

    func isShipItRunning() -> Bool {
        let r = runner.run("/bin/launchctl", ["print", "gui/\(env.uid)/\(Self.shipItLabel)"])
        guard r.status == 0 else { return false }
        return r.output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("state =") }?
            .contains("running") == true
            && !(r.output.contains("state = not running"))
    }

    /// A staged update newer than the installed bundle (a stale or older staged version is ignored).
    func updatePending() -> Bool {
        guard let staged = (try? ClaudeConfig.load(env.claudeConfigJSON))?.stagedUpdateVersion,
              let installed = app.bundleVersion(appURL: env.claudeAppURL) else { return false }
        return Self.isVersion(staged, newerThan: installed)
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Lock

    /// Kernel advisory lock (flock) held on an open descriptor for the whole session: atomic, released by
    /// the kernel if the process dies, and immune to pid reuse.
    func isLocked() -> Bool {
        if lockFD >= 0 { return true }
        let fd = open(env.lockFile.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN)
        return false
    }

    func acquireLock() throws {
        try fs.createDirectory(env.storeDir)
        try fs.check(env.lockFile)
        // O_NOFOLLOW: SafeFS accepts a dangling symlink here (its target does not exist yet), and O_CREAT would
        // follow it and create a file outside the store.
        let fd = open(env.lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError.io(L10n.t(.reasonLockOpenFailed)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SwitcherError.anotherSwitchInProgress
        }
        do {
            legacyLockFD = try acquireLegacyLock()
        } catch {
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
        lockFD = fd
    }

    /// The personal 1.0 build flocks its own `switch.lock`; holding it too keeps the two apps from switching
    /// at the same time in either direction. If that build's store exists, its (empty) lock file is created when
    /// missing — the 1.0 build opens the same path with O_CREAT, so this is exactly what it would do itself.
    func acquireLegacyLock() throws -> Int32 {
        guard env.hasSeparateLegacyStore, FileManager.default.fileExists(atPath: env.legacyStoreDir.path) else { return -1 }
        // O_NONBLOCK: a FIFO planted at this path must not hang the open.
        let fd = open(env.legacyLockFile.path, O_RDONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw SwitcherError.io(L10n.t(.reasonLockOpenFailed)) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == env.uid else {
            close(fd)
            throw SwitcherError.io(L10n.t(.reasonLockOpenFailed))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SwitcherError.anotherSwitchInProgress
        }
        return fd
    }

    func releaseLock() {
        if legacyLockFD >= 0 {
            flock(legacyLockFD, LOCK_UN)
            close(legacyLockFD)
            legacyLockFD = -1
        }
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }
}
