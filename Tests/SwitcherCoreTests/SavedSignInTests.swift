import Darwin
import Foundation
import Testing
@testable import SwitcherCore

/// The account list (saved sign-ins), naming accounts, removing saved sign-ins, and living next to the personal
/// 1.0 build's store.
@Suite("Accounts and saved sign-ins")
struct SavedSignInTests {
    static let c = FakeIdentity.c

    // MARK: The account list

    @Test func theListIsTheSavedSignInsInNameOrder() throws {
        let rig = try Rig.make(enrolled: [Self.c, .b]); defer { rig.cleanup() }
        let accounts = rig.switcher.accounts()
        // Default names are the emails; fake.21@… sorts before fake.c@….
        #expect(accounts.map(\.id) == [FakeIdentity.b.key, Self.c.key])
        #expect(accounts.map(\.label) == [FakeIdentity.b.email, Self.c.email])
        #expect(accounts.allSatisfy { $0.customName == nil })
        let row = try #require(rig.switcher.status().accounts.first { $0.id == Self.c.key })
        #expect(row.snapshot == .ready && !row.isActive && row.defaultName == Self.c.email)
    }

    @Test func anySavedAccountCanBeSwitchedToByIdOrName() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let result = try rig.switcher.switchTo(Self.c.key, confirmed: true)
        #expect(result.to == Self.c.identity)
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).lastKnownAccountUuid == Self.c.account)
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: "Work")
        #expect(try rig.switcher.switchTo("work", confirmed: true).to == FakeIdentity.b.identity)   // names ignore case
    }

    @Test func activeAccountWithoutSavedSignInIsWarnedAbout() throws {
        let rig = try Rig.make(codeSession: .a, enrolled: [.b]); defer { rig.cleanup() }   // the session shows the email
        let warning = L10n.t(.warnActiveNotSaved, Privacy.maskEmail(FakeIdentity.a.email))
        #expect(rig.switcher.status().warnings.contains(warning))
        #expect(!warning.contains(FakeIdentity.a.email))
    }

    // MARK: Names

    @Test func renamingSetsResetsAndPersistsNames() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let renamed = try rig.switcher.renameAccount(Self.c.key, to: "  Side project  ")
        #expect(renamed.label == "Side project" && renamed.customName == "Side project")
        #expect(rig.switcher.accounts().map(\.label) == [FakeIdentity.b.email, "Side project"])
        #expect(posixPermissions(rig.env.accountNamesFile) == 0o600)
        // Another switcher (the CLI, the next launch) sees the same names.
        let other = Switcher(env: rig.env, table: rig.world, app: rig.world, runner: rig.world, clock: rig.world,
                             freeDiskGB: { 100 })
        #expect(other.account(matching: "SIDE PROJECT")?.id == Self.c.key)
        // Blank goes back to the default name; removing the last name leaves no file behind.
        try rig.switcher.renameAccount("side project", to: "   ")
        #expect(rig.switcher.account(matching: Self.c.key)?.label == Self.c.email)
        #expect(!exists(rig.env.accountNamesFile))
    }

    @Test func namesAreOneLineShortAndUnique() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let invalid = SwitcherError.invalidAccountName(maxLength: AccountNames.maxLength)
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: String(repeating: "x", count: 41)) } == invalid)
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: "two\nlines") } == invalid)
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: "tab\there") } == invalid)
        let long = String(repeating: "가", count: 40)
        #expect(try rig.switcher.renameAccount(Self.c.key, to: long).label == long)
        // Unique among shown names, default (email) names included, ignoring case.
        let taken = FakeIdentity.b.email.uppercased()
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: taken) } == .duplicateAccountName(taken))
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: "Work")
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: "work") } == .duplicateAccountName("work"))
        #expect(switcherError { try rig.switcher.renameAccount("nobody", to: "x") } == .unknownAccount("nobody"))
        #expect(rig.switcher.account(matching: Self.c.key)?.label == long)
    }

    @Test func aNameCanNeverPointAtAnotherAccount() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: "Work")
        // B still answers to its email under a custom name, so no other account may take that email as a name.
        let bEmail = FakeIdentity.b.email
        #expect(switcherError { try rig.switcher.renameAccount(Self.c.key, to: bEmail) } == .duplicateAccountName(bEmail))
        #expect(rig.switcher.account(matching: bEmail)?.id == FakeIdentity.b.key)
        #expect(rig.switcher.account(matching: "WORK")?.id == FakeIdentity.b.key)
        try rig.switcher.removeSaved(Self.c.email)
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) != nil)
    }

    @Test func clashingNamesAreShownApartAndNeverGuessed() throws {
        // B took C's email as its name while C wasn't saved yet; then C is saved.
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: Self.c.email)
        try rig.enroll(Self.c)
        let labels = Dictionary(uniqueKeysWithValues: rig.switcher.accounts().map { ($0.id, $0.label) })
        #expect(labels[FakeIdentity.b.key] == Self.c.email)
        #expect(labels[Self.c.key] == "\(Self.c.email) · \(Self.c.org.prefix(8))")
        #expect(switcherError { _ = try rig.switcher.resolve(Self.c.email) } == .ambiguousAccount(Self.c.email))
        #expect(switcherError { try rig.switcher.removeSaved(Self.c.email) } == .ambiguousAccount(Self.c.email))
        #expect(rig.switcher.store.latest(for: Self.c.identity) != nil)
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) != nil)
        // Going back to the default name is always allowed.
        #expect(try rig.switcher.renameAccount(FakeIdentity.b.key, to: nil).customName == nil)
        #expect(rig.switcher.account(matching: Self.c.email)?.id == Self.c.key)
    }

    @Test func oneEmailInTwoOrganizationsGetsTwoNames() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        let otherOrg = FakeIdentity(account: FakeIdentity.b.account, org: "eeeeeeee-2222-4222-8222-eeeeeeeeeeee",
                                    email: FakeIdentity.b.email, name: FakeIdentity.b.name)
        try rig.enroll(otherOrg)
        let labels = rig.switcher.accounts().map(\.label)
        #expect(labels == ["\(FakeIdentity.b.email) · bbbbbbbb", "\(FakeIdentity.b.email) · eeeeeeee"])
        #expect(switcherError { _ = try rig.switcher.resolve(FakeIdentity.b.email) } == .ambiguousAccount(FakeIdentity.b.email))
        #expect(rig.switcher.account(matching: labels[1])?.id == otherOrg.key)
        #expect(rig.switcher.account(matching: otherOrg.key)?.id == otherOrg.key)
    }

    @Test func anUnreadableNamesFileIsNeverOverwritten() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        try rig.sandbox.write("{not json", to: rig.env.accountNamesFile)
        #expect(rig.switcher.accounts().map(\.label) == [FakeIdentity.b.email, Self.c.email])
        let err = switcherError { try rig.switcher.renameAccount(Self.c.key, to: "Side") }
        guard case .io = err else { Issue.record("expected io, got \(String(describing: err))"); return }
        #expect(fileData(rig.env.accountNamesFile) == Data("{not json".utf8))
        // Removing a sign-in still works; the file is left as it was.
        try rig.switcher.removeSaved(Self.c.key)
        #expect(fileData(rig.env.accountNamesFile) == Data("{not json".utf8))
    }

    @Test func emojiNamesAreFineButInvisiblesAndBidiOverridesAreNot() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        // Plain and ZWJ-composed emoji are fine; the ZWJ must sit between emoji scalars.
        #expect(try rig.switcher.renameAccount(FakeIdentity.b.key, to: "👩‍💻 Work").label == "👩‍💻 Work")
        #expect(switcherError { try rig.switcher.renameAccount(FakeIdentity.b.key, to: "a\u{200D}b") }
            == .invalidAccountName(maxLength: AccountNames.maxLength))
        #expect(try rig.switcher.renameAccount(FakeIdentity.b.key, to: "soft\u{00AD}hyphen").customName == "soft\u{00AD}hyphen")
        #expect(switcherError { try rig.switcher.renameAccount(FakeIdentity.b.key, to: "\u{202E}kroW") }
            == .invalidAccountName(maxLength: AccountNames.maxLength))
    }

    @Test func concurrentRenamesNeverLoseEachOther() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let other = Switcher(env: rig.env, table: rig.world, app: rig.world, runner: rig.world, clock: rig.world,
                             freeDiskGB: { 100 })
        let switchers = [rig.switcher, other]
        let targets = [FakeIdentity.b.key, Self.c.key]
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            _ = try? switchers[i % 2].renameAccount(targets[i % 2], to: "\(i % 2 == 0 ? "B" : "C")\(i)")
        }
        let names = try #require(AccountNames.load(env: rig.env))
        #expect(names.count == 2)
        #expect(names[FakeIdentity.b.key]?.hasPrefix("B") == true && names[Self.c.key]?.hasPrefix("C") == true)
    }

    // MARK: Removing

    @Test func removingASavedSignInDeletesOnlyThatAccountAndItsName() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        try rig.switcher.renameAccount(Self.c.key, to: "Side project")
        try rig.switcher.renameAccount(FakeIdentity.b.key, to: "Work")
        try rig.switcher.removeSaved("side project")   // by name
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) != nil)
        #expect(rig.switcher.accounts().map(\.id) == [FakeIdentity.b.key])
        #expect(AccountNames.load(env: rig.env) == [FakeIdentity.b.key: "Work"])
        #expect(rig.liveFingerprint() == before)
        // Saved again later, it starts from its default name.
        try rig.enroll(Self.c)
        #expect(rig.switcher.account(matching: Self.c.key)?.label == Self.c.email)
    }

    @Test func theActiveAccountAndUnknownIDsCannotBeRemoved() throws {
        let rig = try Rig.make(enrolled: [.a, .b]); defer { rig.cleanup() }
        #expect(switcherError { try rig.switcher.removeSaved(FakeIdentity.a.key) } == .cannotRemoveActive)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) != nil)
        #expect(switcherError { try rig.switcher.removeSaved("nope") } == .unknownAccount("nope"))
        #expect(SwitcherError.cannotRemoveActive.code == "cannot_remove_active")
    }

    // MARK: Personal 1.0 store

    /// The same sandbox, but with the personal build's store as its store.
    static func legacyEnv(_ rig: Rig) -> SwitcherEnvironment {
        var env = rig.env
        env.storeDir = rig.env.legacyStoreDir
        return env
    }

    @Test func legacySignInsAreCopiedOnceAndNeverModified() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        let legacyEnv = Self.legacyEnv(rig)
        let legacy = SnapshotStore(env: legacyEnv, fs: SafeFS(env: legacyEnv))
        let source = try rig.sandbox.scratch()
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: Self.c)
        _ = try legacy.capture(from: source, identity: Self.c.identity, claudeVersion: "1.0.0")
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: .b, tag: "lgcy")
        _ = try legacy.capture(from: source, identity: FakeIdentity.b.identity, claudeVersion: "1.0.0")
        let legacyB = fileData(try #require(legacy.latest(for: FakeIdentity.b.identity)).dir.appendingPathComponent("Cookies"))
        let ownB = fileData(try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity)).dir.appendingPathComponent("Cookies"))

        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded().imported == 1)   // only C: B already exists here
        let copied = try #require(rig.switcher.store.latest(for: Self.c.identity))
        try rig.switcher.store.verify(copied)
        #expect(fileData(copied.dir.appendingPathComponent("Cookies")) != nil)
        #expect(fileData(try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity)).dir.appendingPathComponent("Cookies")) == ownB)
        #expect(ownB != legacyB)
        #expect(legacy.latest(for: Self.c.identity) != nil)   // copied, not moved
        #expect(exists(rig.env.legacyImportMarker))

        _ = try legacy.capture(from: source, identity: FakeIdentity.d.identity, claudeVersion: "1.0.0")
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded().imported == 0)   // once only
        #expect(rig.switcher.store.latest(for: FakeIdentity.d.identity) == nil)
    }

    @Test func noLegacyStoreMeansNothingToImport() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        #expect(rig.switcher.store.importLegacySnapshotsIfNeeded().imported == 0)
        var same = rig.env
        same.storeDir = rig.env.legacyStoreDir
        #expect(!same.hasSeparateLegacyStore)
        #expect(SnapshotStore(env: same, fs: SafeFS(env: same)).importLegacySnapshotsIfNeeded().imported == 0)
    }

    /// Simulates the personal build holding its own switch lock.
    static func holdLegacyLock(_ rig: Rig) throws -> Int32 {
        try FileManager.default.createDirectory(at: rig.env.legacyStoreDir, withIntermediateDirectories: true)
        let fd = open(rig.env.legacyLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    @Test func aSwitchInThePersonalBuildBlocksThisApp() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let fd = try Self.holdLegacyLock(rig)
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .anotherSwitchInProgress)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(!rig.switcher.isLocked())   // our own lock was released again
        #expect(rig.switcher.recover().needsAttention)

        flock(fd, LOCK_UN)
        close(fd)
        #expect(!rig.switcher.recover().needsAttention)
        _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true)
        #expect(try ClaudeConfig.load(rig.env.claudeConfigJSON).lastKnownAccountUuid == FakeIdentity.b.account)
    }

    @Test func thePersonalBuildIsBlockedWhileThisAppSwitches() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let fd = try Self.holdLegacyLock(rig)
        flock(fd, LOCK_UN)   // the file exists (the personal build switched before), nobody holds it
        try rig.switcher.acquireLock()
        #expect(flock(fd, LOCK_EX | LOCK_NB) != 0)
        rig.switcher.releaseLock()
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        close(fd)
    }

    @Test func anUnfinishedSwitchOfThePersonalBuildBlocksEveryMutation() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.sandbox.write("{}", to: rig.env.legacyJournalFile)
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .legacyRecoveryPending)
        #expect(switcherError { _ = try rig.switcher.captureCurrent(confirmed: true) } == .legacyRecoveryPending)
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: true) } == .legacyRecoveryPending)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(!rig.switcher.isLocked())
        // Visible in the status and in the CLI's recover exit code, not just as a refusal.
        #expect(rig.switcher.status().warnings.contains(L10n.t(.warnLegacyRecoveryPending)))
        #expect(rig.switcher.recover().needsAttention)
        #expect(SwitcherError.legacyRecoveryPending.code == "legacy_recovery_pending")

        try FileManager.default.removeItem(at: rig.env.legacyJournalFile)
        #expect(!rig.switcher.status().warnings.contains(L10n.t(.warnLegacyRecoveryPending)))
        #expect(!rig.switcher.recover().needsAttention)
    }

    // MARK: Review follow-ups

    @Test func removingWaitsForNoOneAndRefusesWhileASwitchHoldsTheLock() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let other = Switcher(env: rig.env, table: rig.world, app: rig.world, runner: rig.world, clock: rig.world,
                             freeDiskGB: { 100 })
        try other.acquireLock()
        #expect(switcherError { try rig.switcher.removeSaved(Self.c.key) } == .anotherSwitchInProgress)
        #expect(rig.switcher.store.latest(for: Self.c.identity) != nil)
        other.releaseLock()
        try rig.switcher.removeSaved(Self.c.key)
        #expect(rig.switcher.store.latest(for: Self.c.identity) == nil)
    }

    @Test func theConfigsLastAccountCountsAsInUseWhenTheLogCannotTell() throws {
        let rig = try Rig.make(enrolled: [.a, .b]); defer { rig.cleanup() }
        try FileManager.default.removeItem(at: rig.env.mainLog)
        #expect(rig.switcher.activeIdentity() == nil)
        #expect(switcherError { try rig.switcher.removeSaved(FakeIdentity.a.key) } == .cannotRemoveActive)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) != nil)
        try rig.switcher.removeSaved(FakeIdentity.b.key)
        #expect(rig.switcher.store.latest(for: FakeIdentity.b.identity) == nil)
    }

    @Test func thePrecheckRunsUnderTheLockBeforeAnythingIsTouched() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        var lockedDuringPrecheck = false
        let err = switcherError {
            try rig.switcher.withExclusiveSession(confirmed: true, progress: { _ in }, precheck: {
                lockedDuringPrecheck = rig.switcher.isLocked()
                throw SwitcherError.notEnrolled(label: "gone")
            }) { _ in Issue.record("body must not run") }
        }
        #expect(err == .notEnrolled(label: "gone"))
        #expect(lockedDuringPrecheck)
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.liveFingerprint() == before)
        #expect(!rig.switcher.isLocked())
    }

    @Test func switchingToARemovedSignInStopsBeforeQuittingClaude() throws {
        let rig = try Rig.make(enrolled: [.b]); defer { rig.cleanup() }
        let before = rig.liveFingerprint()
        try rig.switcher.store.remove(FakeIdentity.b.identity)
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .unknownAccount(FakeIdentity.b.key))
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.liveFingerprint() == before)
    }

    @Test func recoverReportsFailuresAndLeftoverJournals() throws {
        let rig = try Rig.make(running: false); defer { rig.cleanup() }
        #expect(!rig.switcher.recover().needsAttention)
        try rig.sandbox.write("{not json", to: rig.env.journalFile)
        let report = rig.switcher.recover()
        #expect(report.needsAttention)
        #expect(report.notes.first?.hasPrefix(L10n.t(.recoverFailed, "")) == true)
    }

    @Test func emailsAreMaskedButKeepTheirDomain() {
        #expect(Privacy.maskEmail("alex.kim.2026@example.com") == "al" + String(repeating: "•", count: 8) + "026@example.com")
        #expect(Privacy.maskEmail("work@example.com") == "••••@example.com")
        #expect(Privacy.maskEmail("no-at-sign") == "no-at-sign")
        #expect(!Privacy.maskEmail(FakeIdentity.c.email).contains("fake.c"))
    }

    // MARK: Import hardening

    /// A legacy store holding one identity, returning that identity's folder in the legacy store.
    static func legacyCapture(_ rig: Rig, _ identity: FakeIdentity) throws -> URL {
        let legacyEnv = Self.legacyEnv(rig)
        let legacy = SnapshotStore(env: legacyEnv, fs: SafeFS(env: legacyEnv))
        let source = try rig.sandbox.scratch()
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: identity)
        return try legacy.capture(from: source, identity: identity.identity, claudeVersion: "1.0.0").dir.deletingLastPathComponent()
    }

    @Test func importSkipsSymlinksMismatchesAndCorruptCopies() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let store = rig.switcher.store
        // Symlink inside the copied folder.
        let c = try Self.legacyCapture(rig, Self.c)
        let outside = try rig.sandbox.scratch("secret").appendingPathComponent("x")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: c.appendingPathComponent("gen-1/extra"), withDestinationURL: outside)
        // Folder named after D but holding A's manifest.
        let a = try Self.legacyCapture(rig, .a)
        try FileManager.default.moveItem(at: a, to: rig.env.legacySnapshotsDir.appendingPathComponent(FakeIdentity.d.identity.key))
        // Newest generation tampered with.
        let b = try Self.legacyCapture(rig, .b)
        try Data("tampered".utf8).write(to: b.appendingPathComponent("gen-1/Cookies"))

        #expect(store.importLegacySnapshotsIfNeeded().imported == 0)
        for identity in [Self.c, .a, .b, .d] { #expect(store.latest(for: identity.identity) == nil) }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.env.snapshotsDir.path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(exists(rig.env.legacyImportMarker))   // nothing failed: rejected copies are final
    }

    @Test func aFailedCopyIsRetriedAndLeavesNothingBehind() throws {
        let rig = try Rig.make(enrolled: []); defer { rig.cleanup() }
        let store = rig.switcher.store
        let c = try Self.legacyCapture(rig, Self.c)
        let cookies = c.appendingPathComponent("gen-1/Cookies")
        _ = chmod(cookies.path, 0o000)
        #expect(store.importLegacySnapshotsIfNeeded().imported == 0)
        #expect(!exists(rig.env.legacyImportMarker))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.env.snapshotsDir.path)) ?? []).isEmpty)
        _ = chmod(cookies.path, 0o600)
        #expect(store.importLegacySnapshotsIfNeeded().imported == 1)
        #expect(store.latest(for: Self.c.identity) != nil)
        #expect(exists(rig.env.legacyImportMarker))
    }

    @Test func aFolderWhoseManifestNamesAnotherAccountIsNotListed() throws {
        let rig = try Rig.make(enrolled: [.b, Self.c]); defer { rig.cleanup() }
        let cDir = rig.switcher.store.identityDir(Self.c.identity)
        try FileManager.default.copyItem(at: cDir, to: rig.switcher.store.identityDir(FakeIdentity.d.identity))
        #expect(rig.switcher.store.savedIdentities().map(\.key) == [FakeIdentity.b.identity.key, Self.c.identity.key].sorted())
        let ids = rig.switcher.accounts().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Legacy lock file

    @Test func theLegacyLockIsCreatedOnlyWhenThatStoreExists() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.switcher.acquireLock()
        rig.switcher.releaseLock()
        #expect(!exists(rig.env.legacyStoreDir))

        try FileManager.default.createDirectory(at: rig.env.legacyStoreDir, withIntermediateDirectories: true)
        try rig.switcher.acquireLock()
        #expect(exists(rig.env.legacyLockFile))
        let probe = open(rig.env.legacyLockFile.path, O_RDONLY)
        #expect(flock(probe, LOCK_EX | LOCK_NB) != 0)   // held while we hold ours
        rig.switcher.releaseLock()
        #expect(flock(probe, LOCK_EX | LOCK_NB) == 0)
        close(probe)
    }

    @Test func aFifoAtTheLegacyLockPathFailsInsteadOfHanging() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try FileManager.default.createDirectory(at: rig.env.legacyStoreDir, withIntermediateDirectories: true)
        try #require(mkfifo(rig.env.legacyLockFile.path, 0o600) == 0)
        #expect(switcherError { try rig.switcher.acquireLock() } == .io(L10n.t(.reasonLockOpenFailed)))
        #expect(!rig.switcher.isLocked())
    }
}
