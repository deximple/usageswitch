import Foundation
import Testing
@testable import SwitcherCore

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SwitchStep] = []
    func append(_ s: SwitchStep) { lock.lock(); items.append(s); lock.unlock() }
    var steps: [SwitchStep] { lock.lock(); defer { lock.unlock() }; return items }
    var sawDialogWait: Bool { steps.contains { if case .waitingForClaudeDialog = $0 { return true }; return false } }
}

@Suite("Switcher.switchTo end-to-end (FakeWorld)")
struct SwitcherSwitchTests {
    /// Nothing changed: live files identical, relaunchers loaded, journals gone, lock released, Claude untouched.
    func expectUntouched(_ rig: Rig, before: [String: Data?], mainPID: pid_t?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rig.liveFingerprint() == before, sourceLocation: sourceLocation)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel), sourceLocation: sourceLocation)
        #expect(rig.switcher.relaunchers.journal().isEmpty, sourceLocation: sourceLocation)
        #expect(!rig.switcher.swapper.journalPresent, sourceLocation: sourceLocation)
        #expect(!rig.switcher.isLocked(), sourceLocation: sourceLocation)
        #expect(rig.world.mainPID == mainPID, sourceLocation: sourceLocation)
    }

    @Test func switchAToBSucceedsAndRecapturesA() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let env = rig.env
        let oldPID = try #require(rig.world.mainPID)
        let oldStart = try #require(rig.world.mainStart)
        let originalA = fileData(env.claudeCookies)
        let prefs = fileData(env.claudeUserData.appendingPathComponent("Preferences"))
        let bSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        let log = StepLog()

        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: log.append)

        #expect(result.outcome == "switched")
        #expect(result.from?.key == FakeIdentity.a.key)
        #expect(result.to == FakeIdentity.b.identity)
        #expect(result.recapturedOutgoing)
        #expect(result.displacedPrevious == nil) // saved as a snapshot, so previous/ is simply discarded
        #expect(result.durationSeconds > 20) // settle window passed on the virtual clock
        // Outgoing A captured byte-for-byte; live jar is now B's snapshot.
        let aSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.a.identity))
        #expect(aSnap.manifest.generation == 1)
        #expect(fileData(aSnap.dir.appendingPathComponent("Cookies")) == originalA)
        #expect(fileData(env.claudeCookies) == fileData(bSnap.dir.appendingPathComponent("Cookies")))
        // config.json: marker → B, token caches gone, everything else preserved.
        let config = try jsonObject(env.claudeConfigJSON)
        #expect(config["lastKnownAccountUuid"] as? String == FakeIdentity.b.account)
        #expect(config["oauth:tokenCache"] == nil && config["oauth:tokenCacheV2"] == nil)
        #expect(config["coworkTrustedDeviceToken:\(FakeIdentity.clientUuid)"] as? String == "FAKE-DEVICE-TOKEN-0001")
        #expect(config["dxt:allowlistEnabled:\(FakeIdentity.a.org)"] as? Bool == true)
        #expect((config["updaterRunningInstance"] as? [String: Any])?["pid"] as? Int == 4242)
        #expect(fileData(env.claudeUserData.appendingPathComponent("Preferences")) == prefs)
        // Relaunched once, as a new process; relaunchers restored; no leftovers.
        let newPID = try #require(rig.world.mainPID)
        #expect(newPID != oldPID)
        #expect(try #require(rig.world.mainStart) > oldStart)
        #expect(rig.world.read { ($0.quitRequests, $0.sigterms, $0.launches) } == (1, 0, 1))
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.world.read { $0.journalHadLabelAtBootout[AgentFixture.keepaliveLabel] } == true)
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(!exists(env.previousDir) && !exists(env.stagingDir) && !exists(env.displacedDir))
        #expect(exists(env.lockFile) && !rig.switcher.isLocked()) // the lock file stays; only the flock is released
        // One-time original backup holds A's jar.
        let backup = try #require(rig.switcher.store.originalBackup())
        #expect(fileData(backup.appendingPathComponent("Cookies")) == originalA)
        // Status agrees.
        #expect(rig.switcher.activeIdentity()?.account == FakeIdentity.b.account)
        let order: [SwitchStep] = [.preflight, .suspendingRelaunchers, .quittingClaude, .capturingOutgoing, .backingUp,
                                   .swapping, .launching, .verifying, .restoringRelaunchers, .done]
        #expect(log.steps == order)
    }

    @Test func switchBackRestoresOriginalJarAndRecapturesB() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let originalA = fileData(rig.env.claudeCookies)
        _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        let back = try rig.switcher.switchTo(FakeIdentity.a.key, confirmed: false)
        #expect(back.outcome == "switched")
        #expect(back.from == FakeIdentity.b.identity)
        #expect(back.recapturedOutgoing)
        #expect(fileData(rig.env.claudeCookies) == originalA)
        #expect(rig.switcher.store.generations(for: FakeIdentity.b.identity).map(\.manifest.generation) == [2, 1])
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.a.account)
        #expect(rig.world.read { $0.launches } == 2)
    }

    @Test(arguments: [FakeIdentity.b.key, FakeIdentity.b.email])
    func switchingToTheActiveAccountIsANoOp(id: String) throws {
        let rig = try Rig.make(active: .b, enrolled: [.a, .b]); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        let result = try rig.switcher.switchTo(id, confirmed: false)
        #expect(result.outcome == "already_active")
        #expect(result.to == FakeIdentity.b.identity)
        #expect(!result.recapturedOutgoing)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (0, 0))
        #expect(rig.world.read { $0.commands }.isEmpty)
        expectUntouched(rig, before: before, mainPID: pid)
        #expect(rig.switcher.store.generations(for: FakeIdentity.b.identity).count == 1)   // nothing new saved
    }

    @Test func refusesUnknownAccounts() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        #expect(switcherError { _ = try rig.switcher.switchTo("account-zzz", confirmed: true) } == .unknownAccount("account-zzz"))
        // An account without a saved sign-in isn't in the list at all.
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
            == .unknownAccount(FakeIdentity.b.key))
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.email, confirmed: true) }
            == .unknownAccount(FakeIdentity.b.email))
        #expect(rig.world.read { $0.quitRequests } == 0)
        expectUntouched(rig, before: before, mainPID: pid)
    }

    @Test func codeSessionsNeedConfirmation() throws {
        let rig = try Rig.make(codeSession: .a); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) } == .needsConfirmation(codeSessions: 1))
        expectUntouched(rig, before: before, mainPID: pid)
        #expect(rig.world.read { $0.quitRequests } == 0)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true)
        #expect(result.outcome == "switched")
    }

    @Test func quitVetoChangesNothingAndRestoresRelaunchers() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .veto(allowAfter: nil) }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        let log = StepLog()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: log.append) }
        guard case .quitVetoed(let waited) = err else { Issue.record("expected quitVetoed, got \(String(describing: err))"); return }
        #expect(waited >= 600)
        #expect(log.sawDialogWait)
        #expect(log.steps.last == .restoringRelaunchers)
        #expect(rig.world.read { $0.sigterms } == 0) // never signal a vetoed quit
        expectUntouched(rig, before: before, mainPID: pid)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.switcher.store.originalBackup() == nil)
        #expect(!rig.world.read { $0.commands }.filter { $0.count > 1 && $0[1] == "bootout" }.isEmpty)
    }

    @Test func vetoThenUserConfirmsProceeds() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .veto(allowAfter: 45) }
        let log = StepLog()
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: log.append)
        #expect(result.outcome == "switched")
        #expect(log.sawDialogWait)
        #expect(rig.world.read { $0.sigterms } == 0)
    }

    /// At most one SIGTERM, also when kill(2) reports failure (it is never retried in a loop).
    @Test(arguments: [true, false])
    func quitTimeoutSendsOneSigtermAndChangesNothing(killSucceeds: Bool) throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .ignore; $0.sigtermResult = killSucceeds }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .quitTimeout(let waited) = err else { Issue.record("expected quitTimeout, got \(String(describing: err))"); return }
        #expect(waited >= 150)
        #expect(rig.world.read { $0.sigterms } == 1)
        expectUntouched(rig, before: before, mainPID: pid)
    }

    @Test func sigtermFallbackWhenTerminateIsIgnored() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .ignore; $0.sigtermQuits = true }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(rig.world.read { $0.sigterms } == 1)
    }

    @Test func injectedPostSwapFaultRollsBackByteIdentical() throws {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let log = StepLog()
        let err = switcherError {
            _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, fault: .postSwapVerify, progress: log.append)
        }
        guard case .verificationFailed(let reason, let rollback) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
        #expect(rollback == .verified)
        #expect(reason.contains("post-swap-verify"))
        #expect(log.steps.contains(.rollingBack))
        #expect(rig.liveFingerprint() == before)
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.a.account)
        #expect(rig.world.mainPID != nil) // relaunched on the previous account
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (2, 2))
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(!exists(rig.env.previousDir))
        // Not a rejected sign-in: B's snapshot stays usable.
        let b = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        #expect(!rig.switcher.store.needsRelogin(b))
    }

    @Test func faultInjectionIsInertUnlessAllowed() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, fault: .postSwapVerify)
        #expect(result.outcome == "switched")
    }

    @Test func wrongAccountAfterLaunchRollsBack() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        try rig.enroll(.b, cookieIdentity: .c) // mislabelled snapshot: really another account's jar
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .verificationFailed(let reason, .verified) = err else {
            Issue.record("expected rolled-back verificationFailed, got \(String(describing: err))"); return
        }
        #expect(reason.contains("cccccccc"))
        #expect(rig.liveFingerprint() == before)
    }

    @Test func anInitLineObservedJustBeforeTheDeadlineStillSettles() throws {
        var options = SwitcherOptions()
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        // The init line lands inside the launch-verify window but is first polled
        // near its end: it must still get the full settle, not a deadline rollback.
        rig.world.update {
            $0.launchInitDelay = options.launchVerifyTimeout + options.pollInterval / 2
            $0.afterLaunch = { $0.launchInitDelay = 2; $0.afterLaunch = nil }
        }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
    }

    @Test func anInitLineAfterTheVerifyWindowStillTimesOut() throws {
        var options = SwitcherOptions()
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        rig.world.update {
            $0.launchInitDelay = options.launchVerifyTimeout + options.pollInterval + 2
            $0.afterLaunch = { $0.launchInitDelay = 2; $0.afterLaunch = nil }
        }
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .verificationFailed = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
    }

    @Test func noVerdictWithinTimeoutRollsBack() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        // Only the post-swap launch is silent; the rollback relaunch initialises normally.
        rig.world.update { $0.launchLogsNothing = true; $0.afterLaunch = { $0.launchLogsNothing = false } }
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .verificationFailed(let reason, .verified) = err else {
            Issue.record("expected verified rollback, got \(String(describing: err))"); return
        }
        #expect(reason.contains("60"))
        #expect(rig.liveFingerprint() == before)
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.a.account)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (2, 2))
    }

    @Test func inheritedForeignEnvironmentFailsVerification() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update {
            $0.launchEnvNames = ["HOME", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"]
            $0.afterLaunch = { $0.launchEnvNames = FakeWorld.dockLaunchEnvNames }
        }
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .verificationFailed(let reason, .verified) = err else {
            Issue.record("expected verified rollback, got \(String(describing: err))"); return
        }
        #expect(reason.contains("ANTHROPIC_API_KEY, CLAUDE_CONFIG_DIR"))
        #expect(!reason.contains("HOME"))
        #expect(rig.liveFingerprint() == before)
    }

    @Test func launchFailureRollsBack() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.launchError = .launchFailed("LaunchServices refused") }
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
            == .launchFailed("LaunchServices refused"))
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    /// Claude relaunched by something else mid-swap: the switcher (still holding the session) quits it again,
    /// rolls the files back byte-identical, restores relaunchers and relaunches Claude on the original files.
    @Test func claudeRelaunchedMidSwapIsQuitAndUndone() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.spawnClaudeWhenJournalApplied = 1 }
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        #expect(err == .claudeStartedDuringSwap)
        #expect(rig.world.read { $0.claudeStartedDuringSwap })
        #expect(rig.liveFingerprint() == before)
        #expect(!rig.switcher.swapper.journalPresent)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(rig.world.mainPID != nil)   // relaunched on the restored files
        #expect(!rig.switcher.isLocked())
    }

    @Test func insufficientDiskIsRefusedUpFront() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.freeGB = 3 }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
            == .insufficientDisk(freeGB: 3, requiredGB: 8))
        expectUntouched(rig, before: before, mainPID: pid)
        #expect(rig.world.read { $0.quitRequests } == 0)
    }

    @Test func runningShipItIsRefusedUpFront() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.shipItRunning = true }
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .updateInProgress)
        expectUntouched(rig, before: before, mainPID: pid)
        #expect(rig.world.read { $0.quitRequests } == 0)
    }


    @Test func missingClaudeAppIsRefused() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try FileManager.default.removeItem(at: rig.env.claudeAppURL)
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .claudeNotInstalled)
    }

    @Test func corruptOrIncompatibleSnapshotIsRefusedBeforeQuitting() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let snap = try rig.enroll(.b)
        try Data("tampered".utf8).write(to: snap.dir.appendingPathComponent("Cookies"))
        guard case .snapshotCorrupt = switcherError({ _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }) else {
            Issue.record("expected snapshotCorrupt"); return
        }
        try rig.enroll(.b, version: 30, lastCompatible: 26) // newer generation, schema too new for live 24
        guard case .snapshotIncompatible = switcherError({ _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }) else {
            Issue.record("expected snapshotIncompatible"); return
        }
        #expect(rig.world.read { $0.quitRequests } == 0)
    }

    @Test func partialRelauncherSuspendFailureStillRestores() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let opener = try AgentFixture.writePlist(env: rig.env, label: "com.user.claude-opener", plist: [
            "Label": "com.user.claude-opener", "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
        ])
        rig.world.addAgent(label: "com.user.claude-opener", plist: opener)
        rig.world.update { $0.bootoutFails = ["com.user.claude-opener"] }
        let before = rig.liveFingerprint()
        guard case .io = switcherError({ _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }) else {
            Issue.record("expected io"); return
        }
        // The agent that *was* booted out before the failure must be bootstrapped again.
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.world.read { $0.quitRequests } == 0)
    }

    @Test func staleSwapJournalWhileClaudeRunsDoesNotBreakNextSwitch() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        // An earlier run installed a config change and crashed before commit/rollback; then Claude was reopened.
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.write(try ClaudeConfig.mutated(fileData(rig.env.claudeConfigJSON)!, .restore(accountUuid: FakeIdentity.a.account)),
                                 to: staging.appendingPathComponent("config.json"))
        try rig.switcher.swapper.install(names: [SnapshotItems.config])
        #expect(rig.switcher.swapper.pendingJournal() != nil)
        rig.world.startClaude()
        let bSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))

        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(fileData(rig.env.claudeCookies) == fileData(bSnap.dir.appendingPathComponent("Cookies")))
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).lastKnownAccountUuid == FakeIdentity.b.account)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
    }

    @Test func interruptedSwapIsRolledBackBeforeTheNextSwitchTouchesAnything() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let originalA = fileData(rig.env.claudeCookies)
        let bSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        // An earlier run died right after exchanging Cookies (config.json already applied, not yet committed).
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.write(Data("{\"broken\":true}".utf8), to: staging.appendingPathComponent("config.json"))
        try rig.sandbox.fs.copy(bSnap.dir.appendingPathComponent("Cookies"), to: staging.appendingPathComponent("Cookies"))
        try CrashFixture.interruptInstall(fs: rig.sandbox.fs, env: rig.env, engine: rig.switcher.swapper,
                                          names: Rig.liveNames, at: "Cookies", .afterSwap)
        #expect(rig.liveFingerprint() != before)

        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        // The outgoing account was recaptured from the restored files, not from the half-installed mix.
        #expect(result.recapturedOutgoing)
        let aSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.a.identity))
        #expect(fileData(aSnap.dir.appendingPathComponent("Cookies")) == originalA)
        #expect(fileData(rig.env.claudeCookies) == fileData(bSnap.dir.appendingPathComponent("Cookies")))
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).lastKnownAccountUuid == FakeIdentity.b.account)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (0, 1))
        #expect(rig.switcher.swapper.pendingJournal() == nil)
    }

    /// A logout line in the log is not proof the jar is empty: while it still holds a valid sessionKey the
    /// unsaved files are kept aside (identity unknown → "unknown").
    @Test func logoutLineButValidJarSkipsRecaptureAndKeepsTheFilesAside() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now().addingTimeInterval(-5), LogFixture.logout)])
        let original = fileData(rig.env.claudeCookies)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(result.from == nil)
        #expect(!result.recapturedOutgoing)
        let kept = URL(fileURLWithPath: try #require(result.displacedPrevious))
        #expect(kept.lastPathComponent.hasPrefix("unknown-"))
        #expect(fileData(kept.appendingPathComponent("Cookies")) == original)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(!exists(rig.env.previousDir))
    }

    /// A jar whose sessionKey is already gone has no sign-in to lose: nothing is kept.
    @Test func signedOutJarIsNeitherRecapturedNorKept() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now().addingTimeInterval(-5), LogFixture.logout)])
        try CookieFixture.make(at: rig.env.claudeCookies, identity: .a, sessionExpires: Date().addingTimeInterval(-60))
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(!result.recapturedOutgoing)
        #expect(result.displacedPrevious == nil)
        #expect(!exists(rig.env.previousDir) && !exists(rig.env.displacedDir))
    }

    /// An expired sessionKey can no longer sign in, so there is nothing to keep aside.
    @Test func expiredLiveSessionIsNeitherRecapturedNorKept() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try CookieFixture.make(at: rig.env.claudeCookies, identity: .a, sessionExpires: Date().addingTimeInterval(-60))
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(!result.recapturedOutgoing)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(result.displacedPrevious == nil)
        #expect(!exists(rig.env.displacedDir))
    }

    /// The displacement decision is journaled before Claude relaunches: a crash during verification followed
    /// by recovery still keeps the unsaved sign-in.
    @Test func displacementSurvivesACrashDuringVerification() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let original = fileData(rig.env.claudeCookies)
        let keepAt = rig.env.displacedDir.appendingPathComponent("crash-test")
        // The session's swap ran (Claude quit) and the destination was journaled; then the process "died"
        // before verification could commit.
        try rig.switcher.quitClaude(progress: { _ in })
        _ = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.copy(try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity)).dir.appendingPathComponent("Cookies"),
                                to: rig.env.stagingDir.appendingPathComponent("Cookies"))
        try rig.switcher.swapper.install(names: SnapshotItems.cookieGroup)
        try rig.switcher.swapper.setKeepPrevious(keepAt)
        #expect(rig.switcher.swapper.pendingJournal()?.state == "installed")
        // Recovery commits the installed journal and honours the recorded destination.
        _ = rig.switcher.recoverIfNeeded()
        #expect(!rig.switcher.swapper.journalPresent && !exists(rig.env.previousDir))
        #expect(fileData(keepAt.appendingPathComponent("Cookies")) == original)
    }

    @Test func uncleanQuitSkipsRecapture() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(!result.recapturedOutgoing)
        #expect(result.displacedPrevious != nil) // A has no snapshot: its files are kept, not discarded
    }
}
