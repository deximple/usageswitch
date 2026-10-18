import Foundation
import Testing
@testable import SwitcherCore

@Suite("Switcher capture / enrollment / status / probe / recovery")
struct SwitcherSessionTests {
    // MARK: captureCurrent

    @Test func captureCurrentSavesActiveAccountAndRelaunches() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let live = fileData(rig.env.claudeCookies)
        let before = rig.liveFingerprint()
        let snap = try rig.switcher.captureCurrent(confirmed: false)
        #expect(snap.manifest.identity.key == FakeIdentity.a.key)
        #expect(snap.manifest.generation == 1)
        #expect(snap.manifest.claudeVersion == "1.0.0")
        #expect(fileData(snap.dir.appendingPathComponent("Cookies")) == live)
        #expect(rig.liveFingerprint() == before) // capture never edits the live profile
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (1, 1))
        #expect(rig.world.mainPID != nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.store.originalBackup() != nil)
    }

    @Test func captureCurrentNeedsAKnownSignedInAccount() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: nil)
        guard case .activeIdentityUnknown = switcherError({ _ = try rig.switcher.captureCurrent(confirmed: true) }) else {
            Issue.record("expected activeIdentityUnknown"); return
        }
        #expect(rig.world.read { $0.quitRequests } == 0)
    }

    @Test func captureCurrentRefusesUncleanQuitOrInvalidCookie() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean }
        guard case .activeIdentityUnknown = switcherError({ _ = try rig.switcher.captureCurrent(confirmed: true) }) else {
            Issue.record("expected activeIdentityUnknown (unclean)"); return
        }
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))

        let rig2 = try Rig.make(enrolled: []); defer { rig2.cleanup() }
        try CookieFixture.make(at: rig2.env.claudeCookies, identity: .a, includeSession: false)
        guard case .activeIdentityUnknown = switcherError({ _ = try rig2.switcher.captureCurrent(confirmed: true) }) else {
            Issue.record("expected activeIdentityUnknown (no cookie)"); return
        }
        #expect(rig2.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
    }

    // MARK: beginEnrollment

    @Test func beginEnrollmentStripsOnlyAuthRowsAndMarkers() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let liveBefore = fileData(rig.env.claudeCookies)
        try rig.switcher.beginEnrollment(confirmed: false)
        // Outgoing account was saved first, with its sign-in intact.
        let aSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.a.identity))
        #expect(fileData(aSnap.dir.appendingPathComponent("Cookies")) == liveBefore)
        #expect(try CookieJar.sessionInfo(of: aSnap.dir.appendingPathComponent("Cookies")) != nil)
        // Live jar: sign-in rows gone, device-trust / Cloudflare kept.
        #expect(try CookieFixture.names(rig.env.claudeCookies) == [
            ".claude.ai cf_clearance", ".claude.ai fixture_identity", ".example.com sessionKey",
            "claude.ai __Host-ant_trusted_device",
        ])
        let config = try jsonObject(rig.env.claudeConfigJSON)
        #expect(config["lastKnownAccountUuid"] == nil)
        #expect(config["oauth:tokenCache"] == nil && config["oauth:tokenCacheV2"] == nil)
        #expect(config["coworkTrustedDeviceToken:\(FakeIdentity.clientUuid)"] != nil)
        // Committed (no rollback material) and Claude relaunched at its login screen.
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(!exists(rig.env.previousDir))
        #expect(rig.world.mainPID != nil)
        #expect(!FakeWorld.liveHasSessionKey(rig.env))
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        // The original backup still holds the signed-in jar.
        let backup = try #require(rig.switcher.store.originalBackup())
        #expect(fileData(backup.appendingPathComponent("Cookies")) == liveBefore)
    }

    // MARK: status

    @Test func statusRowsCoverEverySnapshotState() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let aExpiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 5 * 86400)
        try rig.enroll(.a, sessionExpires: aExpiry)
        try rig.enroll(.b)
        let c = try rig.enroll(.c)
        try Data("tampered".utf8).write(to: c.dir.appendingPathComponent("Cookies"))
        try rig.enroll(.d, sessionExpires: Date().addingTimeInterval(-3600))
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: "Zed")

        let status = rig.switcher.status()
        let rows = Dictionary(uniqueKeysWithValues: status.accounts.map { ($0.id, $0) })
        // Name order: the default (email) names of A, C and D, then B's own name.
        #expect(status.accounts.map(\.id) == [FakeIdentity.a.key, FakeIdentity.c.key, FakeIdentity.d.key, FakeIdentity.b.key])
        #expect(rows[FakeIdentity.a.key]?.isActive == true)
        #expect(rows[FakeIdentity.a.key]?.snapshot == .ready)
        #expect(rows[FakeIdentity.a.key]?.email == FakeIdentity.a.email)
        #expect(rows[FakeIdentity.a.key]?.label == FakeIdentity.a.email)
        #expect(rows[FakeIdentity.a.key]?.customName == nil)
        #expect(rows[FakeIdentity.a.key]?.sessionExpiresAt == aExpiry)
        #expect(rows[FakeIdentity.a.key]?.capturedAt != nil)
        #expect(rows[FakeIdentity.b.key]?.label == "Zed")
        #expect(rows[FakeIdentity.b.key]?.customName == "Zed")
        #expect(rows[FakeIdentity.b.key]?.defaultName == FakeIdentity.b.email)
        #expect(rows[FakeIdentity.c.key]?.snapshot == .corrupt)
        #expect(rows[FakeIdentity.d.key]?.snapshot == .expired)
        #expect(status.accounts.filter(\.isActive).map(\.id) == [FakeIdentity.a.key])
        #expect(status.activeAccount?.id == FakeIdentity.a.key)

        #expect(status.claude.installed && status.claude.running)
        #expect(status.claude.pid == rig.world.mainPID.map(Int.init))
        #expect(status.claude.version == "1.0.0")
        #expect(status.claude.activeAccountUuid == FakeIdentity.a.account)
        #expect(status.claude.activeOrgUuid == FakeIdentity.a.org)
        #expect(status.claude.activeEmail == FakeIdentity.a.email)
        #expect(status.claude.codeSessions == 0)
        #expect(status.relaunchers == [AgentFixture.keepaliveLabel])
        #expect(status.suspendedRelaunchers.isEmpty)
        #expect(status.originalBackup == nil)
        #expect(!status.pendingJournal)
        #expect(!status.nativeMultiAccount)
        #expect(status.warnings.isEmpty)
        // The status JSON never carries cookie values.
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        #expect(!json.contains("FAKE-SESSION"))
        #expect(json.contains("corrupt") && json.contains("Zed"))
    }

    @Test func statusWarnings() throws {
        let rig = try Rig.make(active: .c, codeSession: .c, enrolled: []); defer { rig.cleanup() }
        try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now(), "[net] GET https://claude.ai/api/auth/accounts 200")])
        var status = rig.switcher.status()
        #expect(status.nativeMultiAccount)
        #expect(status.claude.codeSessions == 1)
        #expect(status.claude.activeAccountUuid == FakeIdentity.c.account)
        #expect(status.claude.activeEmail == FakeIdentity.c.email)   // from its Code session; not saved yet
        #expect(status.warnings.count == 2) // native multi-account + not saved yet
        #expect(status.accounts.allSatisfy { !$0.isActive })

        try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now(), LogFixture.logout)])
        status = rig.switcher.status()
        #expect(status.claude.activeAccountUuid == nil)
        #expect(status.warnings.count == 2) // native multi-account + cannot confirm sign-in
    }

    @Test func statusWhileNotRunningWithPendingState() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        _ = try rig.switcher.relaunchers.suspendAll()
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.write(Data("{}".utf8), to: staging.appendingPathComponent("config.json"))
        try rig.switcher.swapper.install(names: [SnapshotItems.config])
        let status = rig.switcher.status()
        #expect(!status.claude.running && status.claude.pid == nil)
        #expect(status.pendingJournal)
        #expect(status.suspendedRelaunchers == [AgentFixture.keepaliveLabel])
        #expect(status.claude.activeAccountUuid == nil) // marker gone from the half-installed config
        #expect(status.warnings == [L10n.t(.warnPendingJournal)])
    }

    // MARK: probeCodeSession

    @Test func probeFindsMatchingCodeSession() throws {
        let rig = try Rig.make(codeSession: .a); defer { rig.cleanup() }
        let r = rig.switcher.probeCodeSession(expected: FakeIdentity.a.identity, since: .distantPast, trigger: false, timeout: 5)
        #expect(r.found && r.matches)
        #expect(r.accountUuid == FakeIdentity.a.account)
        #expect(r.email == FakeIdentity.a.email)
        #expect(!r.configDirSet)
        #expect(r.pid != nil)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("FAKE-OAUTH"))
    }

    @Test func probeReportsMismatch() throws {
        let rig = try Rig.make(codeSession: .a); defer { rig.cleanup() }
        let r = rig.switcher.probeCodeSession(expected: FakeIdentity.b.identity, since: .distantPast, trigger: false, timeout: 5)
        #expect(r.found && !r.matches)
        #expect(r.accountUuid == FakeIdentity.a.account)
    }

    @Test func probeNotFoundTimesOutOnVirtualClock() throws {
        let rig = try Rig.make(codeSession: .a); defer { rig.cleanup() }
        let t0 = rig.world.now()
        // Only sessions started after `since` count; the terminal CLI outside Claude never does.
        let r = rig.switcher.probeCodeSession(expected: FakeIdentity.a.identity, since: t0.addingTimeInterval(100),
                                              trigger: false, timeout: 7)
        #expect(!r.found && !r.matches && r.pid == nil)
        #expect(rig.world.now().timeIntervalSince(t0) >= 7)
        let rig2 = try Rig.make(running: false); defer { rig2.cleanup() }
        #expect(!rig2.switcher.probeCodeSession(expected: FakeIdentity.a.identity, since: .distantPast, trigger: false, timeout: 1).found)
    }

    @Test func probeTriggerOpensDeepLinkAndWaitsForNewSession() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.codeSessionOnOpen = true }
        let r = rig.switcher.probeCodeSession(expected: FakeIdentity.a.identity, since: rig.world.now(), trigger: true, timeout: 30)
        #expect(rig.world.read { $0.opened } == [URL(string: "claude://code/continue?session=last")!])
        #expect(r.found && r.matches)
    }

    @Test func probeTriggerNeverOpensTheURLWhenClaudeIsNotRunning() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        rig.world.update { $0.codeSessionOnOpen = true }
        let r = rig.switcher.probeCodeSession(expected: FakeIdentity.a.identity, since: rig.world.now(), trigger: true, timeout: 3)
        #expect(rig.world.read { $0.opened }.isEmpty) // opening claude:// could launch Claude itself
        #expect(!r.found)
        #expect(rig.world.mainPID == nil && rig.world.read { $0.launches } == 0)
    }

    // MARK: recoverIfNeeded

    /// Stages B's jar and an empty config so a (possibly interrupted) install can be left behind.
    func stageForB(_ rig: Rig) throws {
        let bSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.copy(bSnap.dir.appendingPathComponent("Cookies"), to: staging.appendingPathComponent("Cookies"))
        try rig.sandbox.fs.write(Data("{}".utf8), to: staging.appendingPathComponent("config.json"))
    }

    @Test func recoverRollsBackStaleJournalAndRestoresRelaunchers() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        _ = try rig.switcher.relaunchers.suspendAll()
        try stageForB(rig)
        // Killed after moving the old jar aside but before marking the item done.
        try CrashFixture.interruptInstall(fs: rig.sandbox.fs, env: rig.env, engine: rig.switcher.swapper,
                                          names: Rig.liveNames, at: "Cookies", .afterMove)
        #expect(rig.liveFingerprint() != before)
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))

        let notes = rig.switcher.recoverIfNeeded()
        #expect(notes.count == 2)
        #expect(notes.first == L10n.t(.recoverRolledBack))
        #expect(notes.last?.contains(AgentFixture.keepaliveLabel) == true)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(rig.switcher.recoverIfNeeded().isEmpty)
    }

    @Test func recoverCommitsAFullyInstalledJournal() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        try stageForB(rig)
        try rig.switcher.swapper.install(names: Rig.liveNames) // died after "installed", before commit
        let installed = rig.liveFingerprint()
        #expect(rig.switcher.recoverIfNeeded() == [L10n.t(.recoverCommitted)])
        #expect(rig.liveFingerprint() == installed)
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(!exists(rig.env.previousDir) && !exists(rig.env.stagingDir))
    }

    @Test func recoverLeavesJournalAndRelaunchersAloneWhileClaudeRuns() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.write(Data("{}".utf8), to: staging.appendingPathComponent("config.json"))
        try rig.switcher.swapper.install(names: [SnapshotItems.config])
        _ = try rig.switcher.relaunchers.suspendAll()
        rig.world.startClaude() // e.g. the user reopened Claude after a crash mid-switch
        let installed = rig.liveFingerprint()
        // The files may be mixed: neither the journal nor the relaunchers are touched yet.
        #expect(rig.switcher.recoverIfNeeded() == [L10n.t(.recoverRelaunchersHeld)])
        #expect(rig.switcher.swapper.pendingJournal() != nil)
        #expect(rig.liveFingerprint() == installed)
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(rig.world.read { $0.commands }.allSatisfy { $0.count < 2 || $0[1] != "bootstrap" })

        // Once Claude is gone the journal is settled, and only then are the relaunchers restored.
        try rig.switcher.quitClaude(progress: { _ in })
        #expect(rig.switcher.recoverIfNeeded() == [
            L10n.t(.recoverCommitted), L10n.t(.recoverRelaunchersRestored, AgentFixture.keepaliveLabel),
        ])
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.recoverIfNeeded().isEmpty)
    }

    @Test func recoverWithAJournalButNoSuspendedRelaunchersSaysNothing() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.write(Data("{}".utf8), to: staging.appendingPathComponent("config.json"))
        try rig.switcher.swapper.install(names: [SnapshotItems.config])
        rig.world.startClaude()
        #expect(rig.switcher.recoverIfNeeded().isEmpty)
        #expect(rig.switcher.swapper.journalPresent)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel)) // never suspended, never touched
    }

    @Test func recoverClearsTmpAndStripsTokenCachesFromAnOlderOriginalBackup() throws {
        let rig = try Rig.make(running: false, enrolled: []); defer { rig.cleanup() }
        let env = rig.env
        let fs = rig.sandbox.fs
        // Leftovers of an interrupted registry read, and an original backup made by an earlier version.
        try fs.createDirectory(env.tmpDir)
        try fs.write(Data("FAKE-COPY".utf8), to: env.tmpDir.appendingPathComponent("localstorage.sqlite3"))
        let backup = env.backupsDir.appendingPathComponent("original-20260101T000000Z", isDirectory: true)
        try fs.createDirectory(backup)
        try fs.copy(env.claudeConfigJSON, to: backup.appendingPathComponent("config.json"))
        try fs.copy(env.claudeCookies, to: backup.appendingPathComponent("Cookies"))
        #expect(try ClaudeConfig.load(backup.appendingPathComponent("config.json")).hasTokenCache)
        let liveConfig = fileData(env.claudeConfigJSON)

        #expect(rig.switcher.recoverIfNeeded().isEmpty)
        #expect(!exists(env.tmpDir))
        let kept = try ClaudeConfig.load(backup.appendingPathComponent("config.json"))
        #expect(!kept.hasTokenCache)
        #expect(kept.lastKnownAccountUuid == FakeIdentity.a.account)
        #expect(fileData(backup.appendingPathComponent("Cookies")) == fileData(env.claudeCookies))
        #expect(fileData(env.claudeConfigJSON) == liveConfig) // the live config keeps its caches
    }

    @Test func recoverReportsAnUnreadableRelauncherJournalAndKeepsIt() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        try rig.sandbox.fs.createDirectory(rig.env.storeDir)
        try rig.sandbox.fs.write(Data("[{\"label\":".utf8), to: rig.env.relauncherJournalFile)
        #expect(rig.switcher.recoverIfNeeded() == [L10n.t(.recoverRelauncherJournalUnreadable)])
        #expect(fileData(rig.env.relauncherJournalFile) == Data("[{\"label\":".utf8))
        #expect(rig.world.read { $0.commands }.allSatisfy { $0.count < 2 || $0[1] != "bootstrap" })
    }

    @Test func recoverReportsRollbackFailure() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        _ = try rig.switcher.relaunchers.suspendAll()
        try stageForB(rig)
        try CrashFixture.interruptInstall(fs: rig.sandbox.fs, env: rig.env, engine: rig.switcher.swapper,
                                          names: Rig.liveNames, at: "Cookies", .afterSave)
        // The live config.json vanished, so swapping previous/config.json back cannot happen.
        try FileManager.default.removeItem(at: rig.env.claudeConfigJSON)
        let notes = rig.switcher.recoverIfNeeded()
        #expect(notes.count == 2)
        #expect(notes.first?.hasPrefix(L10n.t(.recoverFailed, "")) == true)
        #expect(notes.last == L10n.t(.recoverRelaunchersHeld))
        #expect(rig.switcher.swapper.pendingJournal() != nil)
        #expect(exists(rig.env.previousDir.appendingPathComponent("config.json"))) // rollback material kept
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel)) // still mixed: relaunchers stay suspended
    }

    @Test func defaultDiskProbeReadsTheVolume() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let world = FakeWorld(env: sb.env)
        let switcher = Switcher(env: sb.env, table: world, app: world, runner: world, clock: world)
        let reported = switcher.freeDiskGB()
        // Int.max is the "statfs failed" fallback, not a reading; the value must match the volume's own figure.
        #expect(reported != Int.max)
        let volume = sb.env.claudeUserData.deletingLastPathComponent()
        let available = try #require(try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
        #expect(abs(reported - available / 1_000_000_000) <= 2)
        #expect(switcher.accounts().isEmpty)   // nothing saved yet
    }
}
