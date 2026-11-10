import Foundation
import Testing
@testable import SwitcherCore

@Suite("SwapEngine crash recovery (write-ahead journal)")
struct SwapEngineRecoveryTests {
    static let names = SwapEngineTests.names

    /// Same layout as SwapEngineTests.prepare: config.json + Cookies swapped, Cookies-journal created,
    /// Cookies-wal removed, Cookies-shm absent on both sides.
    func prepare(_ sb: Sandbox, engine: SwapEngine) throws {
        try SwapEngineTests().prepare(sb, engine: engine)
    }

    func liveFingerprint(_ sb: Sandbox) -> [String: Data?] {
        fingerprint(sb.env.claudeUserData, Self.names + ["Preferences"])
    }

    func simulateCrash(_ sb: Sandbox, engine: SwapEngine, at name: String, _ point: CrashPoint, legacy: Bool = false) throws {
        try CrashFixture.interruptInstall(fs: sb.fs, env: sb.env, engine: engine, names: Self.names, at: name, point,
                                          legacy: legacy)
    }

    func text(_ url: URL) -> String? { fileData(url).map { String(decoding: $0, as: UTF8.self) } }

    static let crashCases: [CrashCase] = [
        .init(name: "config.json", point: .afterSave), .init(name: "config.json", point: .afterSwap),
        .init(name: "config.json", point: .afterMove),
        .init(name: "Cookies", point: .afterSave), .init(name: "Cookies", point: .afterSwap),
        .init(name: "Cookies", point: .afterMove),
        .init(name: "Cookies-journal", point: .afterSave), .init(name: "Cookies-journal", point: .afterMove),
        .init(name: "Cookies-wal", point: .afterSave), .init(name: "Cookies-wal", point: .afterMove),
    ]

    @Test func aCrashRightAfterInstallStillKeepsTheUnsavedSignIn() throws {
        // From docs/evidence/full-audit-20261110-repro/KeepPreviousRepro.swift, expectation inverted (B-01):
        // keepPreviousAt is in the first journal save, so a crash before the old setKeepPrevious call
        // still lands the outgoing files in displaced/.
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        let engine = SwapEngine(env: env, fs: sb.fs, isClaudeRunning: { false })
        try Data("OUTGOING-config".utf8).write(to: env.claudeUserData.appendingPathComponent("config.json"))
        try Data("OUTGOING-cookies".utf8).write(to: env.claudeUserData.appendingPathComponent("Cookies"))
        let displaced = env.displacedDir.appendingPathComponent("unsaved-account-1")
        let staging = try engine.prepareStaging()
        try sb.fs.write(Data("TARGET-config".utf8), to: staging.appendingPathComponent("config.json"))
        try sb.fs.write(Data("TARGET-cookies".utf8), to: staging.appendingPathComponent("Cookies"))
        try engine.install(names: ["config.json", "Cookies"], keepPreviousAt: displaced)
        #expect(engine.pendingJournal()?.keepPreviousAt == displaced.path)

        // <- the process dies here. Next launch: recovery settles the journal.
        #expect(try engine.resolvePending() == .committed)
        #expect(String(decoding: try Data(contentsOf: displaced.appendingPathComponent("Cookies")),
                       as: UTF8.self) == "OUTGOING-cookies")
        #expect(!FileManager.default.fileExists(atPath: env.previousDir.path))
        #expect(engine.pendingJournal() == nil)
    }

    @Test func theFirstJournalSaveAlreadyCarriesTheDestination() throws {
        // Claude launches before the first item is applied: install aborts but the journal
        // written before the loop must already carry keepPreviousAt.
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        let engine = SwapEngine(env: env, fs: sb.fs, isClaudeRunning: { true })
        try Data("OUTGOING-config".utf8).write(to: env.claudeUserData.appendingPathComponent("config.json"))
        try Data("OUTGOING-cookies".utf8).write(to: env.claudeUserData.appendingPathComponent("Cookies"))
        let displaced = env.displacedDir.appendingPathComponent("unsaved-account-2")
        let staging = try engine.prepareStaging()
        try sb.fs.write(Data("TARGET-config".utf8), to: staging.appendingPathComponent("config.json"))
        try sb.fs.write(Data("TARGET-cookies".utf8), to: staging.appendingPathComponent("Cookies"))
        #expect(throws: SwitcherError.self) {
            try engine.install(names: ["config.json", "Cookies"], keepPreviousAt: displaced)
        }
        #expect(engine.pendingJournal()?.keepPreviousAt == displaced.path)
    }

    /// `legacy`: the journal was written before `originalDigest` existed, so recovery uses `stagedDigest`.
    @Test(arguments: SwapEngineRecoveryTests.crashCases, [false, true])
    func interruptedInstallRollsBackByteIdentical(_ crash: CrashCase, legacy: Bool) throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try simulateCrash(sb, engine: engine, at: crash.name, crash.point, legacy: legacy)
        #expect(engine.pendingJournal()?.state == "installing")
        #expect(engine.pendingJournal()?.applied.contains { $0.originalDigest != nil } == !legacy)

        // A fresh engine (as after a restart) settles the journal from what it finds on disk.
        let recovered = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        #expect(try recovered.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before)
        #expect(recovered.pendingJournal() == nil)
        #expect(!exists(sb.env.previousDir) && !exists(sb.env.stagingDir) && !exists(sb.env.journalFile))
        #expect(try recovered.resolvePending() == nil)
    }

    @Test func everyItemDoneButNotYetInstalledIsRolledBack() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try engine.install(names: Self.names)
        try CrashFixture.markInstalling(fs: sb.fs, env: sb.env, engine: engine) // killed before the final "installed" save
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before)
    }

    @Test func installedJournalIsCommitted() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        let installed = liveFingerprint(sb)
        #expect(try engine.resolvePending() == .committed)
        #expect(liveFingerprint(sb) == installed)
        #expect(engine.pendingJournal() == nil)
        #expect(!exists(sb.env.previousDir) && !exists(sb.env.stagingDir))
        #expect(try engine.resolvePending() == nil)
        #expect(SwapEngine.Resolution.rolledBack.rawValue == "rolled_back")
    }

    @Test func prepareStagingRollsBackAnInterruptedInstallFirst() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        // The staged Cookies content is needed by this recovery; a naive staging reset would destroy it.
        try simulateCrash(sb, engine: engine, at: "Cookies", .afterSwap)
        let staging = try engine.prepareStaging()
        #expect(liveFingerprint(sb) == before)
        #expect(engine.pendingJournal() == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? ["?"]).isEmpty)
    }

    @Test func interruptedDirectorySwapIsDetectedByDigest() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = SafeFS(env: sb.env, allowUIGroup: true)
        let engine = SwapEngine(env: sb.env, fs: fs, isClaudeRunning: { false })
        let name = "Local Storage"
        let live = sb.env.claudeUserData.appendingPathComponent(name)
        try sb.write("old", to: live.appendingPathComponent("leveldb/1.log"))
        let staging = try engine.prepareStaging()
        let staged = staging.appendingPathComponent(name)
        try fs.createDirectory(staged.appendingPathComponent("leveldb"))
        try fs.write(Data("new".utf8), to: staged.appendingPathComponent("leveldb/2.log"))
        try engine.install(names: [])
        let entry = SwapEngine.Journal.Item(name: name, kind: .swapped, done: false, stagedDigest: try SwapEngine.digest(staged))
        try fs.write(try JSONEncoder().encode(SwapEngine.Journal(state: "installing", applied: [entry])), to: sb.env.journalFile)
        try fs.swap(staged, live) // killed right after the exchange
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(fileData(live.appendingPathComponent("leveldb/1.log")) == Data("old".utf8))
        #expect(!exists(live.appendingPathComponent("leveldb/2.log")))
    }

    @Test(arguments: [false, true])
    func interruptedRollbackCanBeResumed(legacy: Bool) throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try engine.install(names: [SnapshotItems.config])
        try CrashFixture.markInstalling(fs: sb.fs, env: sb.env, engine: engine, legacy: legacy)
        // A rollback killed between swapping previous/config.json back and deleting it.
        let prev = sb.env.previousDir.appendingPathComponent(SnapshotItems.config)
        try sb.fs.swap(prev, sb.env.claudeConfigJSON)
        #expect(liveFingerprint(sb) == before)
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before)
    }

    @Test func rollbackThatFailsMidwayIsResumedNeverCommitted() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try engine.install(names: Self.names) // "installed"; then the launched account fails verification
        // config.json is undone last; make that step fail after the Cookies group was already restored.
        try FileManager.default.removeItem(at: sb.env.claudeConfigJSON)
        #expect(throws: SwitcherError.self) { try engine.rollback() }
        #expect(engine.pendingJournal()?.state == "installing") // a half-undone install must not be committable
        try sb.write("whatever Claude wrote meanwhile", to: sb.env.claudeConfigJSON)
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before)
    }

    /// Review finding: after a failed verification Claude may already have rewritten the swapped-in files, so
    /// previous/ no longer holds the staged copy once a rollback has swapped the original back. A rollback killed
    /// at that point must not swap Claude's rewrite back over the restored original when it is resumed.
    @Test func resumedRollbackKeepsTheOriginalAfterClaudeRewroteTheSwappedInCopy() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try engine.install(names: Self.names)
        // The launched Claude writes its (swapped-in) cookie jar and config before the switch is undone.
        try sb.write("claude-rewrote-cookies", to: sb.env.claudeCookies)
        try sb.write("claude-rewrote-config", to: sb.env.claudeConfigJSON)
        // The rollback undid Cookies-wal and Cookies-journal, swapped Cookies back, and was killed before
        // deleting previous/Cookies (config.json not reached yet).
        let ud = sb.env.claudeUserData
        let prev = sb.env.previousDir
        try engine.markForRollback()
        try sb.fs.move(prev.appendingPathComponent("Cookies-wal"), to: ud.appendingPathComponent("Cookies-wal"))
        try sb.fs.remove(ud.appendingPathComponent("Cookies-journal"))
        try sb.fs.swap(prev.appendingPathComponent("Cookies"), sb.env.claudeCookies)
        #expect(text(sb.env.claudeCookies) == "live-cookies")
        #expect(text(prev.appendingPathComponent("Cookies")) == "claude-rewrote-cookies") // not the staged copy

        let resumed = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        #expect(try resumed.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before) // original bytes for every item, nothing lost
        #expect(!exists(prev) && !exists(sb.env.stagingDir) && !resumed.journalPresent)
    }

    @Test func rollbackRefusesWhileClaudeRunsBeforeAndBetweenItems() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let claude = ClaudeFlag()
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { claude.check() })
        try prepare(sb, engine: engine)
        let before = liveFingerprint(sb)
        try engine.install(names: Self.names)
        let installed = liveFingerprint(sb)
        let journal = try #require(engine.pendingJournal())
        let ud = sb.env.claudeUserData

        // Running before the first item: nothing is touched, the journal is exactly as it was.
        claude.start()
        #expect(switcherError { try engine.rollback() } == .claudeStartedDuringSwap)
        #expect(engine.pendingJournal() == journal)
        #expect(liveFingerprint(sb) == installed)

        // Claude appears after Cookies-wal and Cookies-journal were undone (4th check: before Cookies).
        claude.stop()
        claude.startAfter(4)
        #expect(switcherError { try engine.rollback() } == .claudeStartedDuringSwap)
        #expect(engine.pendingJournal()?.state == "installing") // half-undone: never committable
        #expect(text(ud.appendingPathComponent("Cookies-wal")) == "live-wal")
        #expect(!exists(ud.appendingPathComponent("Cookies-journal")))
        #expect(text(sb.env.claudeCookies) == "new-cookies") // not swapped under the running Claude
        #expect(text(sb.env.claudeConfigJSON) == "new-config")
        #expect(exists(sb.env.previousDir.appendingPathComponent("Cookies")))

        claude.stop()
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(liveFingerprint(sb) == before)
        #expect(!engine.journalPresent && !exists(sb.env.previousDir))
    }

    @Test func journalsFromOlderVersionsDecodeConservatively() throws {
        let raw = #"{"state":"installing","applied":[{"name":"Cookies","kind":"swapped"},"#
            + #"{"name":"config.json","kind":"swapped","done":false,"stagedDigest":"ab"}]}"#
        let journal = try JSONDecoder().decode(SwapEngine.Journal.self, from: Data(raw.utf8))
        #expect(journal.applied == [
            .init(name: "Cookies", kind: .swapped, done: true, stagedDigest: nil, originalDigest: nil),
            .init(name: "config.json", kind: .swapped, done: false, stagedDigest: "ab", originalDigest: nil),
        ])
        // Encoding omits the absent digest, so the journal round-trips unchanged.
        #expect(try JSONDecoder().decode(SwapEngine.Journal.self, from: JSONEncoder().encode(journal)) == journal)
    }

    // MARK: Helpers

    @Test func digestCoversFilesAndDirectories() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let dir = try sb.scratch("digest")
        try sb.write("a", to: dir.appendingPathComponent("d/x/1"))
        try sb.write("b", to: dir.appendingPathComponent("d/2"))
        let d = dir.appendingPathComponent("d")
        let first = try SwapEngine.digest(d)
        #expect(first.count == 64)
        #expect(try SwapEngine.digest(d) == first)
        try sb.write("B", to: dir.appendingPathComponent("d/2"))
        #expect(try SwapEngine.digest(d) != first)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("d/2"), to: dir.appendingPathComponent("d/3"))
        let renamed = try SwapEngine.digest(d)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("d/3"), to: dir.appendingPathComponent("d/2"))
        #expect(try renamed != SwapEngine.digest(d)) // paths are part of the digest, not just bytes
        #expect(try SwapEngine.digest(dir.appendingPathComponent("d/2")) == SwapEngineTests.sha256("B"))
        #expect(try SwapEngine.digest(dir.appendingPathComponent("missing")) == "")
        let unreadable = dir.appendingPathComponent("locked")
        try sb.write("x", to: unreadable)
        _ = chmod(unreadable.path, 0)
        defer { _ = chmod(unreadable.path, 0o600) }
        #expect(throws: SwitcherError.self) { try SwapEngine.digest(unreadable) }
    }

    @Test func existsSeesDanglingSymlinks() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let dir = try sb.scratch("links")
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("nowhere"))
        #expect(SwapEngine.exists(link))
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(!SwapEngine.exists(dir.appendingPathComponent("absent")))
    }
}
