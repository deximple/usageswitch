import Darwin
import Foundation
import Testing
@testable import SwitcherCore

/// Living next to the personal 1.0 build: recovery order, import retries, lock errors, and naming accounts
/// that only Claude's Code sessions know.
@Suite("Legacy coexistence")
struct LegacyCoexistenceTests {
    static let c = FakeIdentity.c

    static func legacyStore(_ rig: Rig) -> SnapshotStore {
        var env = rig.env
        env.storeDir = rig.env.legacyStoreDir
        return SnapshotStore(env: env, fs: SafeFS(env: env))
    }

    @discardableResult
    static func legacyCapture(_ rig: Rig, _ identity: FakeIdentity) throws -> URL {
        let source = try rig.sandbox.scratch()
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: identity)
        return try legacyStore(rig).capture(from: source, identity: identity.identity, claudeVersion: "1.0.0")
            .dir.deletingLastPathComponent()
    }

    // MARK: Recovery order

    @Test func ourRecoveryWaitsWhileThePersonalBuildHasAnUnfinishedSwap() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        _ = try rig.switcher.relaunchers.suspendAll()
        let bSnap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        let staging = try rig.switcher.swapper.prepareStaging()
        try rig.sandbox.fs.copy(bSnap.dir.appendingPathComponent("Cookies"), to: staging.appendingPathComponent("Cookies"))
        try rig.sandbox.fs.write(Data("{}".utf8), to: staging.appendingPathComponent("config.json"))
        try CrashFixture.interruptInstall(fs: rig.sandbox.fs, env: rig.env, engine: rig.switcher.swapper,
                                          names: Rig.liveNames, at: "Cookies", .afterMove)
        try rig.sandbox.write("{}", to: rig.env.legacyJournalFile)
        let mixed = rig.liveFingerprint()

        let report = rig.switcher.recover()
        #expect(report.notes == [L10n.t(.warnLegacyRecoveryPending)])
        #expect(report.needsAttention)
        #expect(rig.switcher.swapper.pendingJournal() != nil)   // ours is left for after the 1.0 build recovered
        #expect(rig.liveFingerprint() == mixed)
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().map(\.label) == [AgentFixture.keepaliveLabel])

        try FileManager.default.removeItem(at: rig.env.legacyJournalFile)
        #expect(rig.switcher.recoverIfNeeded().first == L10n.t(.recoverRolledBack))
        #expect(rig.switcher.swapper.pendingJournal() == nil)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    @Test func relaunchersThatCouldNotBeRestoredNeedAttention() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        _ = try rig.switcher.relaunchers.suspendAll()
        rig.world.update { $0.bootstrapFails = [AgentFixture.keepaliveLabel] }
        let report = rig.switcher.recover()
        #expect(report.needsAttention)
        #expect(report.notes == [L10n.t(.warnRelaunchersSuspended, AgentFixture.keepaliveLabel)])
        rig.world.update { $0.bootstrapFails = [] }
        #expect(!rig.switcher.recover().needsAttention)
    }

    @Test func aBrokenLockFileIsReportedAsAFailureNotAsBusy() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try FileManager.default.createDirectory(at: rig.env.legacyStoreDir, withIntermediateDirectories: true)
        try #require(mkfifo(rig.env.legacyLockFile.path, 0o600) == 0)
        let report = rig.switcher.recover()
        #expect(report.needsAttention)
        #expect(report.notes == [L10n.t(.recoverFailed, SwitcherError.io(L10n.t(.reasonLockOpenFailed)).description)])
        #expect(report.notes != [L10n.t(.recoverLocked)])
    }

    // MARK: Import retries

    @Test func aRetriedImportNeverBringsBackARemovedSignIn() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        try Self.legacyCapture(rig, Self.c)
        let d = try Self.legacyCapture(rig, .d)
        let dCookies = d.appendingPathComponent("gen-1/Cookies")
        _ = chmod(dCookies.path, 0o000)

        let first = rig.switcher.store.importLegacySnapshotsIfNeeded()
        #expect(first == .init(imported: 1, failed: 1))
        #expect(!exists(rig.env.legacyImportMarker))
        let report = rig.switcher.recover()
        #expect(report.notes.contains(L10n.t(.recoverImportFailed, 1)))
        #expect(report.needsAttention)

        try rig.switcher.removeSaved(Self.c.key)
        _ = chmod(dCookies.path, 0o600)
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 1, failed: 0))
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)   // stays removed
        #expect(rig.switcher.store.latest(for: FakeIdentity.d.identity) != nil)
        #expect(exists(rig.env.legacyImportMarker))
    }

    @Test func aSymlinkedFolderInThePersonalStoreIsNeverCopied() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let elsewhere = try rig.sandbox.scratch("elsewhere")
        let real = try Self.legacyCapture(rig, Self.c)
        try FileManager.default.moveItem(at: real, to: elsewhere.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: elsewhere.appendingPathComponent("moved"))

        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 0, failed: 0))
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.env.snapshotsDir.path)) ?? []).isEmpty)
        #expect(exists(rig.env.legacyImportMarker))
    }

    @Test func removingTheSignInWhoseImportFailedKeepsItRemoved() throws {
        let rig = try Rig.make(active: .a, enrolled: [.b]); defer { rig.cleanup() }
        let c = try Self.legacyCapture(rig, Self.c)
        let cookies = c.appendingPathComponent("gen-1/Cookies")
        _ = chmod(cookies.path, 0o000)
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 0, failed: 1))
        // Saved here in the meantime (e.g. captured on a switch), then removed by the user.
        try rig.enroll(Self.c)
        try rig.switcher.removeSaved(Self.c.key)
        _ = chmod(cookies.path, 0o600)
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 0, failed: 0))
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
        #expect(exists(rig.env.legacyImportMarker))
    }

    @Test func anUnreadableImportRecordStopsTheImport() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        try Self.legacyCapture(rig, Self.c)
        try rig.sandbox.write("{garbage", to: rig.env.legacyImportHandled)
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 0, failed: 1))
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
        #expect(!exists(rig.env.legacyImportMarker))
    }

    @Test func anEmptyLeftoverFolderDoesNotBlockTheImport() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        try Self.legacyCapture(rig, Self.c)
        try FileManager.default.createDirectory(at: rig.switcher.store.identityDir(Self.c.identity), withIntermediateDirectories: true)
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded() == .init(imported: 1, failed: 0))
        #expect(rig.switcher.store.latest(for: Self.c.identity) != nil)
    }

    @Test func aRunningPersonalSwitchIsNotReportedAsUnfinished() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try FileManager.default.createDirectory(at: rig.env.legacyStoreDir, withIntermediateDirectories: true)
        let fd = open(rig.env.legacyLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        try rig.sandbox.write("{}", to: rig.env.legacyJournalFile)
        #expect(!rig.switcher.status().warnings.contains(L10n.t(.warnLegacyRecoveryPending)))
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .anotherSwitchInProgress)
        flock(fd, LOCK_UN)
        close(fd)
        #expect(rig.switcher.status().warnings.contains(L10n.t(.warnLegacyRecoveryPending)))
    }

    @Test func untrustedRelauncherEntriesAreLeftToTheirOwnWarning() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        _ = try rig.switcher.relaunchers.suspendAll()
        try FileManager.default.removeItem(at: rig.env.launchAgentsDir.appendingPathComponent("\(AgentFixture.keepaliveLabel).plist"))
        #expect(!rig.switcher.relaunchers.untrustedEntries().isEmpty)
        let report = rig.switcher.recover()
        #expect(!report.notes.contains { $0.contains(AgentFixture.keepaliveLabel) })
        #expect(!report.needsAttention)
        #expect(rig.switcher.status().warnings.contains(
            L10n.t(.warnUntrustedRelaunchers, AgentFixture.keepaliveLabel)))
    }

    // MARK: Naming new sign-ins

    @Test func aNewSignInIsNamedByTheEmailOfItsCodeSession() throws {
        let rig = try Rig.make(active: Self.c, codeSession: Self.c, enrolled: []); defer { rig.cleanup() }
        let snap = try rig.switcher.captureCurrent(confirmed: true)
        #expect(snap.manifest.identity.email == Self.c.email)
        #expect(rig.switcher.accounts().map(\.label) == [Self.c.email])
    }

    @Test func withoutACodeSessionTheIdPrefixIsUsedUntilOneShowsTheEmail() throws {
        let rig = try Rig.make(active: Self.c, enrolled: []); defer { rig.cleanup() }
        _ = try rig.switcher.captureCurrent(confirmed: true)
        #expect(rig.switcher.accounts().map(\.label) == [String(Self.c.account.prefix(8))])

        let emails = [Self.c.account: Self.c.email]
        let named = rig.switcher.identityFor(account: Self.c.account, org: Self.c.org, among: rig.switcher.accounts(), emails: emails)
        #expect(named.email == Self.c.email)
        // An email already saved with the sign-in always wins over a session's.
        let saved = [SwitcherAccount(identity: FakeIdentity.a.identity)]
        let kept = rig.switcher.identityFor(account: FakeIdentity.a.account, org: FakeIdentity.a.org, among: saved,
                                            emails: [FakeIdentity.a.account: "other@example.com"])
        #expect(kept.email == FakeIdentity.a.email)
    }

    // MARK: Removal racing a switch

    @Test func aSignInRemovedAfterThePreflightStopsTheSwitchBeforeClaudeQuits() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        let store = rig.switcher.store
        // `freeDiskGB` runs inside the session, after the unlocked checks and before the lock: the removal lands
        // exactly in the window the precheck exists for.
        let racing = Switcher(env: rig.env, table: rig.world, app: rig.world, runner: rig.world, clock: rig.world,
                              freeDiskGB: { try? store.remove(FakeIdentity.b.identity); return 100 })
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try racing.switchTo(FakeIdentity.b.key, confirmed: true) } == .notEnrolled(label: FakeIdentity.b.email))
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.liveFingerprint() == before)
        #expect(!racing.isLocked())
    }

    // MARK: Masking free text

    @Test func emailsInsideTextAreMaskedOnce() {
        let raw = "Switched to alex.kim.2026@example.com (24 s); work@example.com kept."
        let masked = Privacy.maskEmails(in: raw)
        #expect(masked == "Switched to \(Privacy.maskEmail("alex.kim.2026@example.com")) (24 s); ••••@example.com kept.")
        #expect(Privacy.maskEmails(in: masked) == masked)
        #expect(Privacy.maskEmails(in: "账户abc@x.com已保存") == "账户•••@x.com已保存")
        #expect(Privacy.maskEmails(in: "no address here") == "no address here")
        // Labels mixing text and an address, several addresses, accented addresses, and a bare "@".
        #expect(Privacy.maskEmails(in: "Work (jay@corp.com)") == "Work (•••@corp.com)")
        #expect(Privacy.maskEmails(in: "a@x.com / bob@y.com") == "•@x.com / •••@y.com")
        #expect(Privacy.maskEmails(in: "josé.garcía@münchen.de") == Privacy.maskEmail("josé.garcía@münchen.de"))
        #expect(Privacy.maskEmails(in: "계정sam.lee@corp.com으로") == "계정\(Privacy.maskEmail("sam.lee@corp.com"))으로")
        #expect(Privacy.maskEmails(in: "Work @ Acme") == "Work @ Acme")
    }
}
