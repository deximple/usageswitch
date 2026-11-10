import Foundation
import Testing
@testable import SwitcherCore

/// Progress steps stamped with the FakeWorld's virtual time.
final class TimedSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(SwitchStep, Date)] = []
    let world: FakeWorld
    init(world: FakeWorld) { self.world = world }
    func append(_ s: SwitchStep) { let t = world.now(); lock.lock(); items.append((s, t)); lock.unlock() }
    func firstTime(of step: SwitchStep) -> Date? { lock.lock(); defer { lock.unlock() }; return items.first { $0.0 == step }?.1 }
}

@Suite("Switcher failure, rollback, quit and ShipIt paths (FakeWorld)")
struct SwitcherRecoveryPathTests {
    func verificationFailure(_ rig: Rig, fault: InjectedFault? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) -> (reason: String, rollback: RollbackOutcome)? {
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, fault: fault) }
        guard case .verificationFailed(let reason, let rollback) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))", sourceLocation: sourceLocation)
            return nil
        }
        return (reason, rollback)
    }

    /// After a rollback: previous files byte-identical, Claude running again, relaunchers back, no journal.
    func expectRestored(_ rig: Rig, before: [String: Data?], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(rig.liveFingerprint() == before, sourceLocation: sourceLocation)
        #expect(rig.world.mainPID != nil, sourceLocation: sourceLocation)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel), sourceLocation: sourceLocation)
        #expect(rig.switcher.swapper.pendingJournal() == nil, sourceLocation: sourceLocation)
        #expect(!exists(rig.env.previousDir) && !rig.switcher.isLocked(), sourceLocation: sourceLocation)
    }

    @Test func setAsidePendingJournalMovesEverythingIntact() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let env = rig.env
        try FileManager.default.createDirectory(at: env.previousDir, withIntermediateDirectories: true)
        try Data("OUTGOING-cookies".utf8).write(to: env.previousDir.appendingPathComponent("Cookies"))
        // Only a damaged journal can be set aside; a readable one is settled by recovery.
        let broken = Data("{unreadable".utf8)
        try broken.write(to: env.journalFile)
        try FileManager.default.createDirectory(at: env.stagingDir, withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: env.stagingDir.appendingPathComponent("config.json"))

        let destination = try rig.switcher.setAsidePendingJournal().destination
        #expect(destination.deletingLastPathComponent().path == env.displacedDir.path)
        #expect(destination.lastPathComponent.hasPrefix("journal-"))
        #expect(!rig.switcher.status().pendingJournal)
        #expect(String(decoding: try Data(contentsOf: destination.appendingPathComponent("previous/Cookies")),
                       as: UTF8.self) == "OUTGOING-cookies")
        #expect(fileData(destination.appendingPathComponent("swap-journal.json")) == broken)
        #expect(!exists(env.stagingDir))
    }

    @Test func setAsidePendingJournalIsRefusedWhileClaudeRuns() throws {
        let rig = try Rig.make(); defer { rig.cleanup() } // Claude running
        try Data("{".utf8).write(to: rig.env.journalFile)
        #expect(throws: SwitcherError.self) { try rig.switcher.setAsidePendingJournal() }
        #expect(rig.env.journalFile.path == rig.env.journalFile.path) // untouched
        #expect(exists(rig.env.journalFile))
    }

    @Test func aReadableJournalCannotBeSetAside() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let env = rig.env
        try FileManager.default.createDirectory(at: env.previousDir, withIntermediateDirectories: true)
        try Data("OUTGOING-cookies".utf8).write(to: env.previousDir.appendingPathComponent("Cookies"))
        let journal = SwapEngine.Journal(state: "installing", applied: [])
        try JSONEncoder().encode(journal).write(to: env.journalFile)

        #expect(throws: SwitcherError.self) { try rig.switcher.setAsidePendingJournal() }
        #expect(exists(env.journalFile))
        #expect(String(decoding: try Data(contentsOf: env.previousDir.appendingPathComponent("Cookies")),
                       as: UTF8.self) == "OUTGOING-cookies")
    }

    @Test func journalUnreadableIsTrueOnlyForADamagedJournal() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        #expect(!rig.switcher.status().journalUnreadable)
        // A readable pending journal is pending but not unreadable.
        try JSONEncoder().encode(SwapEngine.Journal(state: "installing", applied: []))
            .write(to: rig.env.journalFile)
        #expect(rig.switcher.status().pendingJournal)
        #expect(!rig.switcher.status().journalUnreadable)
        // A damaged one is both.
        try Data("{broken".utf8).write(to: rig.env.journalFile)
        #expect(rig.switcher.status().journalUnreadable)
    }

    @Test func setAsideKeepsStagingFilesLeftMidSwap() throws {
        // install() can stop between swap and move: staging/ then holds the original live
        // file — possibly the only copy of an unsaved sign-in. Set-aside must keep it too.
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let env = rig.env
        try FileManager.default.createDirectory(at: env.stagingDir, withIntermediateDirectories: true)
        try Data("ORIGINAL-live-config".utf8).write(to: env.stagingDir.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: env.previousDir, withIntermediateDirectories: true)
        try Data("{unreadable".utf8).write(to: env.journalFile)

        let result = try rig.switcher.setAsidePendingJournal()
        let staged = result.destination.appendingPathComponent("staging/config.json")
        #expect(String(decoding: try Data(contentsOf: staged), as: UTF8.self) == "ORIGINAL-live-config")
        #expect(!exists(env.stagingDir))  // moved, not deleted
        #expect(exists(result.destination.appendingPathComponent("swap-journal.json")))
    }

    @Test func setAsideRestoresSuspendedRelaunchers() throws {
        // A damaged swap journal with Claude's relaunchers still suspended: set-aside must
        // re-bootstrap them — nothing else would until the next recovery.
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let env = rig.env
        try FileManager.default.createDirectory(at: env.previousDir, withIntermediateDirectories: true)
        _ = try rig.switcher.relaunchers.suspendAll()
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        try Data("{unreadable".utf8).write(to: env.journalFile)

        let result = try rig.switcher.setAsidePendingJournal()
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)   // suspended-relaunchers.json gone
        #expect(result.restoreNotes == [L10n.t(.recoverRelaunchersRestored, AgentFixture.keepaliveLabel)])
        #expect(!result.needsAttention)
    }

    @Test func displacedConfigsHaveNoTokenCachesAfterRecovery() throws {
        // A crash during verification leaves an "installed" journal: recovery commits it and
        // must strip token caches out of every displaced config.json (B-01).
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let env = rig.env
        let displaced = env.displacedDir.appendingPathComponent("unsaved-1")
        try FileManager.default.createDirectory(at: env.previousDir, withIntermediateDirectories: true)
        let cached = Data(#"{"oauth:tokenCache":{"token":"x"},"lastKnownAccountUuid":"a"}"#.utf8)
        try Data("OUTGOING-cookies".utf8).write(to: env.previousDir.appendingPathComponent("Cookies"))
        try cached.write(to: env.previousDir.appendingPathComponent("config.json"))
        var journal = SwapEngine.Journal(state: "installed", applied: [])
        journal.keepPreviousAt = displaced.path
        try JSONEncoder().encode(journal).write(to: env.journalFile)

        _ = rig.switcher.recoverIfNeeded()

        let config = try #require(try? ClaudeConfig.load(displaced.appendingPathComponent("config.json")))
        #expect(!config.hasTokenCache)
        #expect(String(decoding: try Data(contentsOf: displaced.appendingPathComponent("Cookies")),
                       as: UTF8.self) == "OUTGOING-cookies")
    }

    @Test func anUnreadableJournalFailsBeforeAnythingIsSuspendedOrQuit() throws {
        // A damaged swap journal must stop every session before relaunchers are suspended
        // or Claude is quit — the live files may be mid-swap (audit B-03).
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        try Data("{broken".utf8).write(to: rig.env.journalFile)
        func bootouts() -> Int { rig.world.read { $0.commands }.filter { $0.count > 1 && $0[1] == "bootout" }.count }
        let log = StepLog()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: log.append) }
            == .swapFailed(L10n.t(.reasonJournalCorrupt)))
        #expect(bootouts() == 0)
        #expect(rig.world.mainPID != nil) // Claude is still running, untouched
        #expect(!log.steps.contains(.suspendingRelaunchers))
    }

    @Test func captureAndEnrollmentAlsoFailOnAnUnreadableJournal() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try Data("{broken".utf8).write(to: rig.env.journalFile)
        func bootouts() -> Int { rig.world.read { $0.commands }.filter { $0.count > 1 && $0[1] == "bootout" }.count }
        #expect(switcherError { _ = try rig.switcher.captureCurrent(confirmed: false) }
            == .swapFailed(L10n.t(.reasonJournalCorrupt)))
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: false) }
            == .swapFailed(L10n.t(.reasonJournalCorrupt)))
        #expect(bootouts() == 0)
        #expect(rig.world.mainPID != nil)
    }

    // MARK: Launch faults that persist through the rollback relaunch

    @Test func noVerdictThatPersistsLeavesRollbackUnverified() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.launchLogsNothing = true }
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig))
        #expect(failure.rollback == .unverified)
        #expect(failure.reason.contains("60"))
        expectRestored(rig, before: before)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (2, 2))
    }

    @Test func foreignEnvironmentThatPersistsLeavesRollbackUnverified() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.launchEnvNames = ["HOME", "ANTHROPIC_API_KEY"] }
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig))
        #expect(failure.rollback == .unverified)
        #expect(failure.reason.contains("ANTHROPIC_API_KEY"))
        expectRestored(rig, before: before)
    }

    @Test(arguments: [false, true])
    func claudeNotParentedByLaunchdFailsVerification(persists: Bool) throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update {
            $0.launchParentPID = 4321 // e.g. started as a child of the switcher or a terminal
            if !persists { $0.afterLaunch = { $0.launchParentPID = 1 } }
        }
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig))
        #expect(failure.reason.contains("4321"))
        #expect(failure.rollback == (persists ? .unverified : .verified))
        expectRestored(rig, before: before)
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.a.account)
    }

    @Test func rollbackRelaunchFailureIsUnverified() throws {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        rig.world.update { $0.afterLaunch = { $0.launchError = .launchFailed("LaunchServices refused") } }
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig, fault: .postSwapVerify))
        #expect(failure.rollback == .unverified)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    @Test func unknownPreviousAccountCannotBeVerified() throws {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now().addingTimeInterval(-5), LogFixture.logout)])
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig, fault: .postSwapVerify))
        #expect(failure.rollback == .unverified) // files restored, but there is no account to confirm
        expectRestored(rig, before: before)
    }

    @Test func rollbackThatCannotQuitTheNewInstanceFailsAndKeepsTheJournal() throws {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        rig.world.update { $0.afterLaunch = { $0.quitMode = .ignore } }
        let before = rig.liveFingerprint()
        let failure = try #require(verificationFailure(rig, fault: .postSwapVerify))
        #expect(failure.rollback == .failed)
        #expect(rig.switcher.swapper.pendingJournal() != nil) // kept for automatic recovery
        #expect(exists(rig.env.previousDir))
        // The files are mixed, so Claude's relaunchers stay suspended until the journal is settled.
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(!rig.switcher.isLocked())

        // Later the user quits Claude; recovery must undo the failed switch, not accept it.
        rig.world.update { $0.quitMode = .normal }
        try rig.switcher.quitClaude(progress: { _ in })
        let notes = rig.switcher.recoverIfNeeded()
        #expect(notes == [L10n.t(.recoverRolledBack), L10n.t(.recoverRelaunchersRestored, AgentFixture.keepaliveLabel)])
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    /// The failed launch staged an update: quitting it lets ShipIt install it and relaunch Claude, which must be
    /// waited out and quit again before the files are swapped back.
    @Test func updateInstalledWhenTheFailedLaunchQuitsIsWaitedOutBeforeRollingBack() throws {
        var options = SwitcherOptions()
        options.allowFaultInjection = true
        let rig = try Rig.make(options: options); defer { rig.cleanup() }
        rig.world.update { $0.afterLaunch = { $0.shipItAfterNextQuit = (duration: 5, relaunchesClaude: true) } }
        let before = rig.liveFingerprint()
        let steps = TimedSteps(world: rig.world)
        let err = switcherError {
            _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, fault: .postSwapVerify, progress: steps.append)
        }
        guard case .verificationFailed(_, let rollback) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
        #expect(rollback == .verified)
        expectRestored(rig, before: before)
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.a.account)
        // Quit: the original instance, the failed one, and the one ShipIt relaunched. Launched by us: twice.
        #expect(rig.world.read { ($0.quitRequests, $0.sigterms, $0.launches) } == (3, 0, 2))
        let idleAt = try #require(rig.world.read { $0.shipItStoppedAt })
        #expect(try #require(steps.firstTime(of: .rollingBack)) < idleAt)
    }

    // MARK: Install failures

    @Test func nonRaceInstallFailureRelaunchesClaudeWithFilesUnchanged() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let outside = try rig.sandbox.scratch("outside").appendingPathComponent("Cookies")
        try Data("NOT-A-COOKIE-JAR".utf8).write(to: outside)
        // Once config.json is in, the staged Cookies becomes a symlink leaving the allowlist → SafeFS refuses it.
        rig.world.update {
            $0.whenJournalApplied = (count: 1, action: { env in
                let staged = env.stagingDir.appendingPathComponent("Cookies")
                try? FileManager.default.removeItem(at: staged)
                try? FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)
            })
        }
        let before = rig.liveFingerprint()
        let oldPID = rig.world.mainPID
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .swapFailed(let reason) = err else { Issue.record("expected swapFailed, got \(String(describing: err))"); return }
        #expect(reason.contains(outside.lastPathComponent) || reason.contains("쓰기 금지"))
        #expect(rig.world.read { $0.whenJournalApplied == nil }) // the sabotage really ran mid-install
        #expect(rig.liveFingerprint() == before)
        #expect(fileData(outside) == Data("NOT-A-COOKIE-JAR".utf8))
        // Claude was closed by us and must not be left closed: one relaunch, as a new process.
        #expect(rig.world.read { $0.launches } == 1)
        #expect(rig.world.mainPID != nil && rig.world.mainPID != oldPID)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    // MARK: Forced re-apply

    @Test func forcedReapplyInstallsTheNewestGeneration() throws {
        let rig = try Rig.make(active: .b, enrolled: [.b]); defer { rig.cleanup() }
        let liveBefore = try #require(fileData(rig.env.claudeCookies))
        let older = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        let olderCookies = fileData(older.dir.appendingPathComponent("Cookies"))
        #expect(olderCookies != liveBefore) // otherwise the test could not tell the generations apart

        #expect(try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false).outcome == "already_active")
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, force: true)
        #expect(result.outcome == "switched")
        #expect(result.from == FakeIdentity.b.identity && result.to == FakeIdentity.b.identity)
        #expect(result.recapturedOutgoing)
        let generations = rig.switcher.store.generations(for: FakeIdentity.b.identity)
        #expect(generations.map(\.manifest.generation) == [older.manifest.generation + 1, older.manifest.generation])
        // The fresh recapture (the live jar), not the older stored generation, was put back.
        #expect(fileData(generations[0].dir.appendingPathComponent("Cookies")) == liveBefore)
        #expect(fileData(rig.env.claudeCookies) == liveBefore)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (1, 1))
        #expect(rig.switcher.activeIdentity()?.account == FakeIdentity.b.account)
    }

    // MARK: Quit

    @Test func longQuitCleanupIsWaitedOutWithoutSignals() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitDuration = 100 }
        let t0 = rig.world.now()
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(result.recapturedOutgoing)
        #expect(rig.world.read { $0.sigterms } == 0)
        #expect(rig.world.now().timeIntervalSince(t0) >= 100)
    }

    /// A child that outlives Claude makes the quit time out: nothing is swapped and Claude is relaunched
    /// on its untouched files (never left closed).
    @Test func descendantOutlivingClaudeTimesOutWithoutSwapping() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let mcp = try #require(rig.world.spawnLingeringMCP())
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .quitTimeout = err else { Issue.record("expected quitTimeout, got \(String(describing: err))"); return }
        #expect(rig.world.mainPID != nil)
        #expect(rig.world.read { $0.launches } == 1)
        #expect(rig.world.read { s in s.procs.contains { $0.pid == mcp } }) // still alive, never signalled
        #expect(rig.world.read { $0.sigterms } == 0)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.switcher.store.originalBackup() == nil)
        #expect(rig.switcher.swapper.pendingJournal() == nil && !exists(rig.env.stagingDir))
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(!rig.switcher.isLocked())
    }

    /// Design D2-4 (measured on 2.42304.0): `updaterRunningInstance` keeps the old pid after a clean quit,
    /// so a leftover sentinel must not turn a clean quit into an unclean one.
    @Test func leftoverRunningInstanceSentinelDoesNotMakeQuitUnclean() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let pid = try #require(rig.world.mainPID)
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, runningPid: Int(pid))
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(result.recapturedOutgoing)
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).runningInstancePID == Int(pid)) // preserved verbatim
    }

    // MARK: ShipIt after quit

    @Test func shipItRunningRightAfterQuitIsWaitedOut() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.shipItAfterNextQuit = (duration: 12, relaunchesClaude: false) }
        let steps = TimedSteps(world: rig.world)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: steps.append)
        #expect(result.outcome == "switched")
        let idleAt = try #require(rig.world.read { $0.shipItStoppedAt })
        let touchedAt = try #require(steps.firstTime(of: .capturingOutgoing))
        // Nothing in the profile was read or written until ShipIt had been idle for the quiet window.
        #expect(touchedAt.timeIntervalSince(idleAt) >= rig.switcher.options.shipItQuietWindow)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (1, 1))
    }

    @Test func shipItRelaunchingClaudeIsQuitAgain() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.shipItAfterNextQuit = (duration: 5, relaunchesClaude: true) }
        let steps = TimedSteps(world: rig.world)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: steps.append)
        #expect(result.outcome == "switched")
        #expect(result.recapturedOutgoing)
        let idleAt = try #require(rig.world.read { $0.shipItStoppedAt })
        #expect(try #require(steps.firstTime(of: .swapping)) > idleAt)
        // One quit for the original instance, one for the instance ShipIt started; one launch by the switcher.
        #expect(rig.world.read { ($0.quitRequests, $0.sigterms, $0.launches) } == (2, 0, 1))
        #expect(FakeWorld.liveIdentity(rig.env)?.account == FakeIdentity.b.account)
    }

    @Test func shipItThatNeverGoesQuietAbortsBeforeTouchingFiles() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.shipItAfterNextQuit = (duration: 10_000, relaunchesClaude: false) }
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) } == .updateInProgress)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(!rig.switcher.isLocked())
    }
}
