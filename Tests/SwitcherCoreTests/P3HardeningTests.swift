import Foundation
import Testing
@testable import SwitcherCore

/// audit P3: an unreadable process table is never "Claude is gone"; copies made while Claude
/// quit are re-checked; interrupted writes are debris; staging installs only what the manifest declares.
@Suite("P3 hardening")
struct P3HardeningTests {

    // MARK: process table failure

    /// The session gate must refuse before the lock, before suspending relaunchers, before any quit.
    @Test func unreadableProcessTableRefusesBeforeAnythingIsTouched() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        let mainPID = rig.world.mainPID
        rig.world.update { $0.tableUnreadable = true }
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
            == .swapFailed(L10n.t(.reasonProcessListUnreadable)))
        #expect(rig.world.read { ($0.quitRequests, $0.sigterms, $0.launches) } == (0, 0, 0))
        #expect(!rig.switcher.swapper.journalPresent)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.liveFingerprint() == before)
        #expect(rig.world.mainPID == mainPID)
    }

    /// Recovery may only settle a journal when Claude is certainly not running.
    @Test func recoveryLeavesAPendingJournalAloneWhileTheTableIsUnreadable() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let engine = rig.switcher.swapper
        let staging = try engine.prepareStaging()
        try rig.sandbox.fs.write(Data("incoming".utf8), to: staging.appendingPathComponent("Cookies"))
        try engine.install(names: ["Cookies"])
        try CrashFixture.markInstalling(fs: rig.sandbox.fs, env: rig.env, engine: engine)
        #expect(engine.journalPresent)

        rig.world.update { $0.tableUnreadable = true }
        _ = rig.switcher.recoverIfNeeded()
        #expect(engine.journalPresent)   // not settled on a guess

        rig.world.update { $0.tableUnreadable = false }
        _ = rig.switcher.recoverIfNeeded()
        #expect(!engine.journalPresent)  // settled once the table reads again
    }

    /// The set-aside guard shares the same rule: a table that can't be read can't prove Claude quit.
    @Test func setAsideIsRefusedWhileTheTableIsUnreadable() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        try rig.sandbox.write("{bad json", to: rig.env.journalFile)
        rig.world.update { $0.tableUnreadable = true }
        #expect(switcherError { _ = try rig.switcher.setAsidePendingJournal() }
            == .swapFailed(L10n.t(.reasonSetAsideWhileRunning)))
    }

    // MARK: Claude must still be quit around every copy

    /// A relaunch while the outgoing sign-in is being captured aborts; the half-read snapshot is dropped.
    @Test func aRelaunchMidCaptureAbortsTheSwitchAndDropsTheHalfRead() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.spawnClaudeWhenCopyingFiles = true }
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
            == .claudeStartedDuringSwap)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.world.mainPID != nil)
        #expect(!rig.switcher.swapper.journalPresent)
    }

    /// Same rule for the one-time original backup: a copy Claude could have touched is never kept.
    @Test func aRelaunchMidBackupAbortsAndDropsTheHalfMadeBackup() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean; $0.spawnClaudeWhenCopyingFiles = true }
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
            == .claudeStartedDuringSwap)
        #expect(rig.switcher.store.originalBackup() == nil)
    }

    // MARK: manifest-only staging

    /// A file present in the snapshot folder but absent from its manifest is never staged.
    @Test func stagingCopiesOnlyManifestEntries() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        // "Cookies-shm" is in the cookie group — older staging would have carried it over.
        try rig.sandbox.write("SHM", to: snap.dir.appendingPathComponent("Cookies-shm"))
        try rig.switcher.stageAndInstall(cookiesFrom: snap.dir, manifest: snap.manifest,
                                         mutation: .restore(accountUuid: FakeIdentity.b.account),
                                         stripAuthRows: false)
        #expect(!exists(rig.env.claudeUserData.appendingPathComponent("Cookies-shm")))
    }

    /// The same rule end to end: the stray file does not reach Claude's live folder.
    @Test func aFileOutsideTheManifestIsNeverInstalled() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        try rig.sandbox.write("SHM", to: snap.dir.appendingPathComponent("Cookies-shm"))
        _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(!exists(rig.env.claudeUserData.appendingPathComponent("Cookies-shm")))
    }

    @Test func stagingRefusesAMissingManifestEntry() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        let manifest = SnapshotManifest(
            identity: snap.manifest.identity, generation: snap.manifest.generation,
            capturedAt: snap.manifest.capturedAt, claudeVersion: snap.manifest.claudeVersion,
            cookieMeta: snap.manifest.cookieMeta, session: snap.manifest.session,
            files: snap.manifest.files + [.init(name: "ghost", sha256: "00", size: 1)])
        #expect(switcherError {
            try rig.switcher.stageAndInstall(cookiesFrom: snap.dir, manifest: manifest,
                                             mutation: .restore(accountUuid: FakeIdentity.b.account),
                                             stripAuthRows: false)
        } == .snapshotCorrupt(L10n.t(.reasonFileMissing, "ghost")))
    }

    /// A copy whose digest differs from the manifest is refused before anything is installed.
    @Test func stagingRefusesADigestMismatch() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        try rig.sandbox.write("tampered", to: snap.dir.appendingPathComponent("Cookies"))
        #expect(switcherError {
            try rig.switcher.stageAndInstall(cookiesFrom: snap.dir, manifest: snap.manifest,
                                             mutation: .restore(accountUuid: FakeIdentity.b.account),
                                             stripAuthRows: false)
        } == .snapshotCorrupt(L10n.t(.reasonHashMismatch, "Cookies")))
    }

    // MARK: commit failure is reported, not swallowed

    @Test func aFailedCommitSurfacesAsAWarningAndKeepsTheJournal() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        try rig.switcher.stageAndInstall(cookiesFrom: snap.dir, manifest: snap.manifest,
                                         mutation: .restore(accountUuid: FakeIdentity.b.account),
                                         stripAuthRows: false)
        // keepPreviousAt under a path whose parent is a regular file: the move inside commit fails.
        let blocker = rig.env.displacedDir.appendingPathComponent("blocked")
        try rig.sandbox.write("x", to: blocker)
        var warnings: [String] = []
        try rig.switcher.launchAndVerify(target: FakeIdentity.b.identity, previous: FakeIdentity.a.identity,
                                         fault: nil, keepPreviousAt: blocker.appendingPathComponent("keep"),
                                         warnings: &warnings, progress: { _ in })
        let template = L10n.t(.warnCommitCleanupFailed, "\u{0}\u{0}").components(separatedBy: "\u{0}\u{0}")
        #expect(warnings.count == 1)
        #expect(template.count == 2 && warnings.first!.hasPrefix(template[0]) && warnings.first!.hasSuffix(template[1]))
        #expect(rig.switcher.swapper.journalPresent)   // recoverable — nothing was silently settled
    }

    // MARK: generation numbers come from directory names

    @Test func generationNumbersComeFromDirectoryNamesNotManifests() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let identity = FakeIdentity.a.identity
        let base = rig.env.snapshotsDir.appendingPathComponent(identity.key, isDirectory: true)
        // gen-3 has a manifest that cannot be parsed: its number is still claimed.
        try rig.sandbox.write("not json", to: base.appendingPathComponent("gen-3/manifest.json"))
        let source = try rig.sandbox.scratch()
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: .a)
        let snap = try rig.switcher.store.capture(from: source, identity: identity, claudeVersion: nil)
        #expect(snap.dir.lastPathComponent == "gen-4")
        #expect(rig.switcher.store.latest(for: identity)?.dir.lastPathComponent == "gen-4")
    }

    // MARK: interrupted-write debris

    @Test func recoverySweepRemovesInterruptedLeftoversOnly() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let idDir = rig.env.snapshotsDir.appendingPathComponent(FakeIdentity.b.key, isDirectory: true)
        try rig.sandbox.write("x", to: rig.env.backupsDir.appendingPathComponent(".partial-dead/Cookies"))
        try rig.sandbox.write("x", to: rig.env.snapshotsDir.appendingPathComponent(".import-dead/manifest.json"))
        try rig.sandbox.write("x", to: idDir.appendingPathComponent(".gen-9-partial-dead/Cookies"))
        try rig.sandbox.write("x", to: rig.env.storeDir.appendingPathComponent(".prefs.json.tmp-dead"))
        // Orphaned previous/ and staging/ (no journal) are debris too.
        try rig.sandbox.write("x", to: rig.env.previousDir.appendingPathComponent("Cookies"))
        try rig.sandbox.write("x", to: rig.env.stagingDir.appendingPathComponent("Cookies"))
        let bGen = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))

        rig.switcher.store.removeInterruptedDebris()

        #expect(!exists(rig.env.backupsDir.appendingPathComponent(".partial-dead")))
        #expect(!exists(rig.env.snapshotsDir.appendingPathComponent(".import-dead")))
        #expect(!exists(idDir.appendingPathComponent(".gen-9-partial-dead")))
        #expect(!exists(rig.env.storeDir.appendingPathComponent(".prefs.json.tmp-dead")))
        #expect(!exists(rig.env.previousDir) && !exists(rig.env.stagingDir))
        #expect(exists(bGen.dir))   // real generations are untouched
    }

    /// previous/ and staging/ are never debris while a journal still needs them.
    @Test func recoverySweepKeepsPreviousAndStagingWhileAJournalIsPending() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let engine = rig.switcher.swapper
        let staging = try engine.prepareStaging()
        try rig.sandbox.fs.write(Data("incoming".utf8), to: staging.appendingPathComponent("Cookies"))
        try engine.install(names: ["Cookies"])
        try CrashFixture.markInstalling(fs: rig.sandbox.fs, env: rig.env, engine: engine)
        #expect(exists(rig.env.previousDir.appendingPathComponent("Cookies")))

        rig.switcher.store.removeInterruptedDebris()

        #expect(exists(rig.env.previousDir.appendingPathComponent("Cookies")))
        #expect(engine.journalPresent)
    }

    // MARK: monotonic time

    @Test func virtualUptimeAdvancesWithSleepOnly() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let t0 = rig.world.uptime()
        rig.world.sleep(5)
        #expect(rig.world.uptime() - t0 == 5)
    }
}
