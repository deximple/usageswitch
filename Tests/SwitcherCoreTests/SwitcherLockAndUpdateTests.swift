import Darwin
import Foundation
import Testing
@testable import SwitcherCore

/// Values recorded from inside a progress callback.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("Switcher session lock (flock) and pending updates")
struct SwitcherLockAndUpdateTests {
    func otherSwitcher(_ rig: Rig) -> Switcher {
        Switcher(env: rig.env, table: rig.world, app: rig.world, runner: rig.world, clock: rig.world,
                 freeDiskGB: { 100 })
    }

    // MARK: Lock

    @Test func secondSwitcherIsLockedOutWhileTheFirstHoldsTheLock() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let other = otherSwitcher(rig)
        #expect(!rig.switcher.isLocked() && !other.isLocked())
        try other.acquireLock()
        #expect(other.isLocked()) // its own session counts as locked
        #expect(rig.switcher.isLocked())
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .anotherSwitchInProgress)
        #expect(switcherError { _ = try rig.switcher.captureCurrent(confirmed: true) } == .anotherSwitchInProgress)
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: true) } == .anotherSwitchInProgress)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(rig.switcher.recoverIfNeeded() == [L10n.t(.recoverLocked)])

        other.releaseLock()
        other.releaseLock() // idempotent
        #expect(!rig.switcher.isLocked() && !other.isLocked())
        #expect(exists(rig.env.lockFile)) // the lock file itself is never deleted
        #expect(try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false).outcome == "switched")
        #expect(exists(rig.env.lockFile) && !rig.switcher.isLocked() && !other.isLocked())
    }

    @Test func lockIsHeldForTheWholeSessionAndBlocksRecoveryElsewhere() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let other = otherSwitcher(rig)
        let seen = Recorder<(SwitchStep, Bool)>()
        let recoveryNotes = Recorder<[String]>()
        _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false) { step in
            seen.append((step, other.isLocked()))
            // Another app instance starting mid-switch must not "repair" the journal being written.
            if step == .launching { recoveryNotes.append(other.recoverIfNeeded()) }
        }
        let byStep = seen.values
        #expect(byStep.first?.0 == .preflight && byStep.first?.1 == false) // preflight runs before the lock
        let inSession = byStep.filter { $0.0 != .preflight && $0.0 != .done }
        #expect(!inSession.isEmpty && inSession.allSatisfy { $0.1 })
        #expect(byStep.last?.0 == .done && byStep.last?.1 == false)
        #expect(recoveryNotes.values == [[L10n.t(.recoverLocked)]])
        #expect(!rig.switcher.swapper.journalPresent)
    }

    /// No pid-file semantics: whatever an earlier (dead or alive) process left in the file, only a held flock blocks.
    @Test(arguments: ["99999", "self", "parent", "garbage", ""])
    func leftoverLockFileContentNeverBlocks(content: String) throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.sandbox.fs.createDirectory(rig.env.storeDir)
        let text = content == "self" ? "\(getpid())" : content == "parent" ? "\(getppid())" : content
        try rig.sandbox.fs.write(Data(text.utf8), to: rig.env.lockFile)
        #expect(!rig.switcher.isLocked())
        #expect(rig.switcher.recoverIfNeeded().isEmpty)
        #expect(try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false).outcome == "switched")
        #expect(exists(rig.env.lockFile) && !rig.switcher.isLocked())
    }

    /// A real other process holding the flock blocks; once it has exited, its leftover lock file does not.
    @Test func lockHeldByAnotherProcessBlocksUntilThatProcessExits() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.sandbox.fs.createDirectory(rig.env.storeDir)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        // -k: keep the file afterwards, exactly like a crashed switcher would leave it.
        holder.arguments = ["-k", rig.env.lockFile.path, "/bin/sh", "-c", "echo held; read x"]
        let stdin = Pipe(), stdout = Pipe()
        holder.standardInput = stdin
        holder.standardOutput = stdout
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        #expect(String(decoding: stdout.fileHandleForReading.readData(ofLength: 5), as: UTF8.self) == "held\n")

        #expect(rig.switcher.isLocked())
        let before = rig.liveFingerprint()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .anotherSwitchInProgress)
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.recoverIfNeeded() == [L10n.t(.recoverLocked)])

        try stdin.fileHandleForWriting.close() // the holder exits; the kernel drops its lock
        holder.waitUntilExit()
        #expect(exists(rig.env.lockFile))
        #expect(!rig.switcher.isLocked())
        #expect(try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false).outcome == "switched")
    }

    @Test func lockFileOutsideTheAllowlistIsRefused() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.sandbox.fs.createDirectory(rig.env.storeDir)
        // A planted symlink must not let the lock open (O_CREAT) a file outside the store.
        let outside = try rig.sandbox.scratch("lock").appendingPathComponent("elsewhere.lock")
        try FileManager.default.createSymbolicLink(at: rig.env.lockFile, withDestinationURL: outside)
        #expect(switcherError { try rig.switcher.acquireLock() } == .io(L10n.t(.reasonLockOpenFailed)))
        #expect(!exists(outside))
        #expect(!rig.switcher.isLocked())
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) } == .io(L10n.t(.reasonLockOpenFailed)))
        #expect(!exists(outside))
        #expect(rig.world.read { $0.quitRequests } == 0)
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    // MARK: Pending update (design D2-0)

    @Test func newerStagedUpdateIsRefusedBeforeAnythingIsTouched() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, stagedVersion: "1.1.0")
        let before = rig.liveFingerprint()
        let pid = rig.world.mainPID
        let log = StepLog()
        #expect(switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false, progress: log.append) }
            == .updatePending)
        #expect(log.steps == [.preflight])
        #expect(switcherError { _ = try rig.switcher.captureCurrent(confirmed: false) } == .updatePending)
        #expect(switcherError { try rig.switcher.beginEnrollment(confirmed: false) } == .updatePending)
        // Claude was not quit, relaunchers were not suspended, the lock was never taken.
        #expect(rig.world.read { ($0.quitRequests, $0.sigterms, $0.launches) } == (0, 0, 0))
        #expect(rig.world.mainPID == pid)
        #expect(!rig.world.read { $0.commands }.contains { $0.count > 1 && $0[1] == "bootout" })
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
        #expect(!exists(rig.env.lockFile))
        #expect(rig.liveFingerprint() == before)
        #expect(rig.switcher.store.latest(for: FakeIdentity.a.identity) == nil)
        #expect(rig.switcher.store.originalBackup() == nil)
        #expect(rig.world.bundleVersion(appURL: rig.env.claudeAppURL) == "1.0.0")
    }

    @Test(arguments: ["0.9.0", "1.0.0", "1.0", "0.99.99", "garbage"])
    func staleOrOlderStagedVersionIsIgnored(staged: String) throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, stagedVersion: staged)
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: false)
        #expect(result.outcome == "switched" && result.recapturedOutgoing)
        #expect(rig.world.read { ($0.quitRequests, $0.launches) } == (1, 1))
        #expect(rig.world.bundleVersion(appURL: rig.env.claudeAppURL) == "1.0.0")
    }

    @Test func noStagedVersionOrUnknownBundleVersionIsNotPending() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, stagedVersion: nil)
        #expect(!rig.switcher.updatePending())
        try ConfigFixture.make(at: rig.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, stagedVersion: "9.0.0")
        #expect(rig.switcher.updatePending())
        rig.world.update { $0.bundleVersion = nil }
        #expect(!rig.switcher.updatePending())
    }

    @Test(arguments: [
        ("1.1.0", "1.0.0", true), ("1.0.0", "1.0.0", false), ("0.9.9", "1.0.0", false), ("1.0.10", "1.0.9", true),
        ("1.0", "1.0.0", false), ("1.0.0.1", "1.0.0", true), ("2", "1.99.99", true), ("1.2.3", "1.10.0", false),
        ("1.10.0", "1.9.9", true), ("x", "0", false), ("1.x.1", "1.0.0", true),
    ])
    func versionComparisonIsNumericPerComponent(a: String, b: String, newer: Bool) {
        #expect(Switcher.isVersion(a, newerThan: b) == newer)
    }
}
