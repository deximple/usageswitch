import Foundation
import Testing
@testable import SwitcherCore

/// The outgoing sign-in must never be lost: saved as a snapshot, kept aside, or the operation is refused.
@Suite("Switcher: outgoing sign-in safety (FakeWorld)")
struct SwitcherOutgoingSignInTests {
    static let a = FakeIdentity.a

    func configWithoutTokenCaches(_ dict: [String: Any]) -> NSDictionary {
        var out = dict
        for key in SnapshotItems.tokenCacheKeys { out.removeValue(forKey: key) }
        return NSDictionary(dictionary: out)
    }

    // MARK: switchTo keeps an unsaved outgoing sign-in aside

    @Test func uncleanQuitWithoutASnapshotKeepsTheOutgoingFilesAside() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let env = rig.env
        rig.world.update { $0.quitMode = .unclean }
        let originalCookies = fileData(env.claudeCookies)
        let originalConfig = try jsonObject(env.claudeConfigJSON)

        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched" && !result.recapturedOutgoing)
        #expect(result.from?.key == Self.a.key)   // unsaved and no Code session: no email known
        let kept = URL(fileURLWithPath: try #require(result.displacedPrevious))
        #expect(kept.deletingLastPathComponent().path == env.displacedDir.path)
        let prefix = "\(Self.a.account)__\(Self.a.org)-"
        #expect(kept.lastPathComponent.hasPrefix(prefix))
        #expect(Int(kept.lastPathComponent.dropFirst(prefix.count)) != nil) // epoch seconds
        // A's sign-in survives byte-for-byte; its config copy carries no token caches.
        #expect(fileData(kept.appendingPathComponent("Cookies")) == originalCookies)
        #expect(try jsonObject(kept.appendingPathComponent("config.json")) as NSDictionary
            == configWithoutTokenCaches(originalConfig))
        #expect(posixPermissions(env.displacedDir) == 0o700)
        #expect(posixPermissions(kept.appendingPathComponent("config.json")) == 0o600)
        // The switch itself is complete and clean.
        #expect(FakeWorld.liveIdentity(env)?.account == FakeIdentity.b.account)
        #expect(!rig.switcher.swapper.journalPresent && !exists(env.previousDir) && !exists(env.stagingDir))
        #expect(rig.switcher.store.latest(for: Self.a.identity) == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    /// Only a usable snapshot (intact, not rejected, sessionKey still valid) makes previous/ disposable.
    @Test(arguments: ["usable", "relogin", "expired", "corrupt"])
    func outgoingSnapshotStateDecidesWhetherPreviousIsKept(state: String) throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean }
        let snap = try rig.enroll(.a, sessionExpires: state == "expired" ? Date().addingTimeInterval(-60)
                                                                         : Date().addingTimeInterval(86400))
        if state == "relogin" { rig.switcher.store.markNeedsRelogin(Self.a.identity) }
        if state == "corrupt" { try Data("tampered".utf8).write(to: snap.dir.appendingPathComponent("Cookies")) }
        #expect(rig.switcher.store.hasUsableSnapshot(for: Self.a.identity, now: rig.world.now()) == (state == "usable"))

        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched" && !result.recapturedOutgoing)
        if state == "usable" {
            #expect(result.displacedPrevious == nil)
            #expect(!exists(rig.env.displacedDir))
        } else {
            let kept = try #require(result.displacedPrevious)
            #expect(exists(URL(fileURLWithPath: kept).appendingPathComponent("Cookies")))
        }
        #expect(!exists(rig.env.previousDir))
    }

    // MARK: an unreadable live jar is never "signed out" (audit B-02)

    @Test func anUnreadableLiveJarIsKeptAsideOnSwitch() throws {
        let rig = try Rig.make(active: .a, enrolled: [.b]); defer { rig.cleanup() }
        let original = Data("this is not a sqlite database".utf8)
        try original.write(to: rig.env.claudeCookies)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        let kept = URL(fileURLWithPath: try #require(result.displacedPrevious))
        #expect(fileData(kept.appendingPathComponent("Cookies")) == original)
        // The jar could not be read: it is kept aside, not treated as signed out and deleted.
        #expect(!rig.switcher.swapper.journalPresent && !exists(rig.env.previousDir))
    }

    @Test func aJarWhoseSchemaChangedIsKeptAside() throws {
        let rig = try Rig.make(active: .a, enrolled: [.b]); defer { rig.cleanup() }
        let db = try TestDB(rig.env.claudeCookies, create: false)
        try db.exec("ALTER TABLE cookies RENAME COLUMN is_httponly TO is_httponly2")
        db.close()
        let original = fileData(rig.env.claudeCookies)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        let kept = URL(fileURLWithPath: try #require(result.displacedPrevious))
        #expect(fileData(kept.appendingPathComponent("Cookies")) == original)
    }

    @Test func enrollmentRefusesWhenTheLiveJarCannotBeRead() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let original = Data("this is not a sqlite database".utf8)
        try original.write(to: rig.env.claudeCookies)
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: false) }
            == .cannotSaveCurrentLogin)
        #expect(fileData(rig.env.claudeCookies) == original)
    }

    // MARK: beginEnrollment never clears the only copy of a sign-in

    @Test func enrollmentRefusesWhenTheCurrentSignInCannotBeSaved() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean } // no clean quit → no recapture
        let before = rig.liveFingerprint()
        let oldPID = rig.world.mainPID
        let log = StepLog()
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: false, progress: log.append) }
            == .cannotSaveCurrentLogin)
        // Claude is relaunched on its untouched files; relaunchers are back; nothing was staged or backed up.
        #expect(rig.liveFingerprint() == before)
        #expect(FakeWorld.liveHasSessionKey(rig.env))
        #expect(rig.world.mainPID != nil && rig.world.mainPID != oldPID)
        #expect(rig.world.read { $0.launches } == 1)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(!rig.switcher.swapper.journalPresent && !exists(rig.env.stagingDir))
        #expect(rig.switcher.store.originalBackup() == nil)
        #expect(rig.switcher.store.latest(for: Self.a.identity) == nil)
        #expect(!log.steps.contains(.swapping) && !log.steps.contains(.backingUp))
        #expect(log.steps.last == .restoringRelaunchers)
    }

    @Test(arguments: ["signedOut", "usableSnapshot"])
    func enrollmentProceedsWhenNothingWouldBeLost(situation: String) throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean }
        if situation == "signedOut" {
            // Signed out = the jar holds no valid sessionKey (not merely a logout line in the log).
            try LogFixture.appendLines(rig.env.mainLog, [(rig.world.now().addingTimeInterval(-5), LogFixture.logout)])
            try CookieFixture.make(at: rig.env.claudeCookies, identity: .a, sessionExpires: Date().addingTimeInterval(-60))
            #expect(rig.switcher.activeIdentity() == nil)
        } else {
            try rig.enroll(.a)
        }
        let saved = rig.switcher.store.latest(for: Self.a.identity)
        try rig.switcher.beginEnrollment(confirmed: false)
        #expect(!FakeWorld.liveHasSessionKey(rig.env)) // signed out locally, ready for a fresh login
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).lastKnownAccountUuid == nil)
        #expect(rig.switcher.store.latest(for: Self.a.identity) == saved) // nothing recaptured after an unclean quit
        #expect(!rig.switcher.swapper.journalPresent)
        #expect(rig.world.mainPID != nil)
    }

    @Test func enrollmentRefusesWhenTheOnlySnapshotWasRejectedByClaude() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        rig.world.update { $0.quitMode = .unclean }
        try rig.enroll(.a)
        rig.switcher.store.markNeedsRelogin(Self.a.identity)
        let before = rig.liveFingerprint()
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: false) } == .cannotSaveCurrentLogin)
        #expect(rig.liveFingerprint() == before)
    }

    // MARK: captureCurrent

    /// Settling a leftover journal inside the session restores files of another account than the pre-check saw.
    @Test func captureAbortsWhenTheLiveAccountChangedAfterThePreCheck() throws {
        let rig = try Rig.make(active: .b, running: false, enrolled: []); defer { rig.cleanup() }
        let env = rig.env
        // An interrupted switch left A's config marker installed (journal still "installing")...
        let staging = try rig.switcher.swapper.prepareStaging()
        let liveConfig = try #require(fileData(env.claudeConfigJSON))
        try rig.sandbox.fs.write(try ClaudeConfig.mutated(liveConfig, .restore(accountUuid: Self.a.account)),
                                 to: staging.appendingPathComponent(SnapshotItems.config))
        try rig.switcher.swapper.install(names: [SnapshotItems.config])
        try CrashFixture.markInstalling(fs: rig.sandbox.fs, env: env, engine: rig.switcher.swapper)
        // ...and Claude was reopened on it and logged A.
        rig.world.startClaude()
        try LogFixture.appendLines(env.mainLog, [(rig.world.now(), LogFixture.initLine(.a))])
        #expect(rig.switcher.activeIdentity()?.account == Self.a.account)

        let err = switcherError { _ = try rig.switcher.captureCurrent(confirmed: false) }
        guard case .activeIdentityUnknown(let reason) = err else {
            Issue.record("expected activeIdentityUnknown, got \(String(describing: err))"); return
        }
        #expect(reason == L10n.t(.reasonAccountChanged))
        #expect(rig.switcher.store.latest(for: Self.a.identity) == nil)
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) == nil)
        // The leftover was rolled back (B's marker again) and Claude is not left closed.
        #expect(!rig.switcher.swapper.journalPresent)
        #expect(fileData(env.claudeConfigJSON) == liveConfig)
        #expect(rig.world.mainPID != nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    @Test func captureDeletesTheNewGenerationWhenTheRelaunchCannotConfirmTheAccount() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let older = try rig.enroll(.a)
        // The relaunch after the capture comes up as a child of another process (verification fails), once.
        rig.world.update { $0.launchParentPID = 4321; $0.afterLaunch = { $0.launchParentPID = 1 } }
        let err = switcherError { _ = try rig.switcher.captureCurrent(confirmed: false) }
        guard case .verificationFailed(let reason, let rollback) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
        #expect(reason.contains("4321"))
        #expect(rollback == .verified)
        // gen-2 was removed; the earlier generation is untouched (the manifest stores whole-second dates, so
        // compare location, number and content rather than the in-memory value).
        let generations = rig.switcher.store.generations(for: Self.a.identity)
        #expect(generations.map(\.dir) == [older.dir])
        #expect(generations.map(\.manifest.generation) == [1])
        #expect(generations.first?.manifest.files == older.manifest.files)
        try rig.switcher.store.verify(try #require(generations.first))
        #expect(!exists(rig.switcher.store.identityDir(Self.a.identity).appendingPathComponent("gen-2")))
        #expect(rig.world.mainPID != nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    // MARK: Relogin marker (design D5-2)

    @Test func signInRejectedAfterSwitchingMarksTheTargetForRelogin() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let env = rig.env
        let b = FakeIdentity.b.identity
        #expect(rig.switcher.store.hasUsableSnapshot(for: b, now: rig.world.now()))
        #expect(rig.switcher.status().accounts.first { $0.id == FakeIdentity.b.key }?.snapshot == .ready)
        // Only the post-swap launch rejects the stored sign-in; the rollback relaunch is normal.
        rig.world.update {
            $0.afterLaunch = { s in
                try? LogFixture.append(env.mainLog, LogFixture.line(s.now, "[auth] session_stale_relogin (sessionKey rejected)") + "\n")
            }
        }
        let before = rig.liveFingerprint()
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) }
        guard case .verificationFailed(let reason, let rollback) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
        #expect(reason.contains("session_stale_relogin"))
        #expect(rollback == .verified)
        #expect(rig.liveFingerprint() == before)

        let snap = try #require(rig.switcher.store.latest(for: b))
        #expect(rig.switcher.store.needsRelogin(snap))
        #expect(!rig.switcher.store.hasUsableSnapshot(for: b, now: rig.world.now()))
        try rig.switcher.store.verify(snap) // still intact: "expired", not "corrupt"
        let rows = Dictionary(uniqueKeysWithValues: rig.switcher.status().accounts.map { ($0.id, $0.snapshot) })
        #expect(rows[FakeIdentity.b.key] == .expired)
        // The outgoing account was recaptured before the failed attempt and is unaffected.
        #expect(rows[FakeIdentity.a.key] == .ready)
    }

    // MARK: Recapture guard (design D2-5)

    /// Review finding: a token-cache lookup after a logout must not count as "signed in" for the recapture.
    @Test func cacheKeyLookupAfterALogoutIsNotRecaptured() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let t = rig.world.now()
        try LogFixture.appendLines(rig.env.mainLog, [
            (t.addingTimeInterval(-30), LogFixture.loginTransition), (t.addingTimeInterval(-20), LogFixture.cacheKeyLine(.a)),
        ])
        #expect(!rig.switcher.log.signedInSinceLastInit())
        #expect(!(try rig.switcher.recaptureGuardPasses()))
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(!result.recapturedOutgoing)
        #expect(rig.switcher.store.latest(for: Self.a.identity) == nil)
        // The newest evidence still names A, so its unsaved files are kept aside rather than discarded.
        #expect(result.from?.key == Self.a.key)   // unsaved and no Code session: no email known
        #expect(result.displacedPrevious != nil)
    }

    // MARK: Clean-quit detection

    @Test(arguments: ClaudeLog.cleanQuitMarkers)
    func everyCleanQuitMarkerCountsAsACleanQuit(marker: String) throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.cleanQuitText = "[app] \(marker)" }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.recapturedOutgoing)
        #expect(result.displacedPrevious == nil)
    }

    @Test func quitWithoutACleanupMarkerIsUnclean() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        rig.world.update { $0.cleanQuitText = "[app] quit cleanup aborted" }
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched")
        #expect(!result.recapturedOutgoing) // "Starting onQuitCleanup handlers" alone is not a finished cleanup
        #expect(result.displacedPrevious != nil)
    }
}
