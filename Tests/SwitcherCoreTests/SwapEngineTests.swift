import CryptoKit
import Foundation
import Testing
@testable import SwitcherCore

@Suite("SwapEngine")
struct SwapEngineTests {
    static let names = [SnapshotItems.config] + SnapshotItems.cookieGroup

    /// Live: config.json, Cookies, Cookies-wal (stale sidecar). Staged: config.json, Cookies, Cookies-journal.
    func prepare(_ sb: Sandbox, engine: SwapEngine) throws {
        let ud = sb.env.claudeUserData
        try sb.write("live-config", to: ud.appendingPathComponent("config.json"))
        try sb.write("live-cookies", to: ud.appendingPathComponent("Cookies"))
        try sb.write("live-wal", to: ud.appendingPathComponent("Cookies-wal"))
        try sb.write("untouched", to: ud.appendingPathComponent("Preferences"))
        let staging = try engine.prepareStaging()
        try sb.fs.write(Data("new-config".utf8), to: staging.appendingPathComponent("config.json"))
        try sb.fs.write(Data("new-cookies".utf8), to: staging.appendingPathComponent("Cookies"))
        try sb.fs.write(Data("new-journal".utf8), to: staging.appendingPathComponent("Cookies-journal"))
    }

    func text(_ url: URL) -> String? { fileData(url).map { String(decoding: $0, as: UTF8.self) } }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func installSwapsCreatesRemovesAndJournals() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        let ud = sb.env.claudeUserData
        #expect(text(ud.appendingPathComponent("config.json")) == "new-config")
        #expect(text(ud.appendingPathComponent("Cookies")) == "new-cookies")
        #expect(text(ud.appendingPathComponent("Cookies-journal")) == "new-journal")
        #expect(!exists(ud.appendingPathComponent("Cookies-wal")))
        #expect(text(ud.appendingPathComponent("Preferences")) == "untouched")
        #expect(text(sb.env.previousDir.appendingPathComponent("Cookies")) == "live-cookies")
        #expect(text(sb.env.previousDir.appendingPathComponent("Cookies-wal")) == "live-wal")
        let journal = try #require(engine.pendingJournal())
        #expect(journal.state == "installed")
        // Every item is marked done and carries the digests of the content it installed (none for removals) and
        // of the live content it replaced (none for creations), both recorded before the item was touched.
        #expect(journal.applied == [
            .init(name: "config.json", kind: .swapped, done: true, stagedDigest: Self.sha256("new-config"),
                  originalDigest: Self.sha256("live-config")),
            .init(name: "Cookies", kind: .swapped, done: true, stagedDigest: Self.sha256("new-cookies"),
                  originalDigest: Self.sha256("live-cookies")),
            .init(name: "Cookies-journal", kind: .created, done: true, stagedDigest: Self.sha256("new-journal"),
                  originalDigest: nil),
            .init(name: "Cookies-wal", kind: .removed, done: true, stagedDigest: nil, originalDigest: Self.sha256("live-wal")),
        ])
        // The journal survives on disk (a new engine instance sees it).
        #expect(SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false }).pendingJournal() == journal)
        #expect(posixPermissions(sb.env.journalFile) == 0o600)
    }

    @Test func rollbackRestoresByteIdenticalFiles() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        let before = fingerprint(sb.env.claudeUserData, Self.names + ["Preferences"])
        try engine.install(names: Self.names)
        try engine.rollback()
        #expect(fingerprint(sb.env.claudeUserData, Self.names + ["Preferences"]) == before)
        #expect(engine.pendingJournal() == nil)
        #expect(!exists(sb.env.previousDir) && !exists(sb.env.stagingDir) && !exists(sb.env.journalFile))
        try engine.rollback() // nothing pending → no-op
    }

    @Test func commitKeepsNewFilesAndDiscardsPrevious() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        #expect(engine.journalPresent)
        try engine.commit()
        #expect(text(sb.env.claudeCookies) == "new-cookies")
        #expect(engine.pendingJournal() == nil && !engine.journalPresent)
        #expect(!exists(sb.env.previousDir) && !exists(sb.env.stagingDir))
    }

    @Test func commitCanKeepThePreviousFilesAside() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        let previous = fingerprint(sb.env.previousDir, Self.names)
        let destination = sb.env.displacedDir.appendingPathComponent("acct__org-1")
        try engine.commit(keepPreviousAt: destination)
        #expect(fingerprint(destination, Self.names) == previous)
        #expect(text(destination.appendingPathComponent("Cookies")) == "live-cookies")
        #expect(text(sb.env.claudeCookies) == "new-cookies")
        #expect(!engine.journalPresent && !exists(sb.env.previousDir) && !exists(sb.env.stagingDir))
        // Nothing to keep (no previous/): the destination is simply not created.
        let second = sb.env.displacedDir.appendingPathComponent("acct__org-2")
        try engine.commit(keepPreviousAt: second)
        #expect(!exists(second))
    }

    /// Keeping previous/ moves it first and removes the journal only afterwards: if the move fails, the
    /// journal (with the recorded destination) survives and a later resolvePending() retries the move.
    @Test func commitKeepingPreviousMovesItBeforeRemovingTheJournal() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        let previous = fingerprint(sb.env.previousDir, Self.names)
        let forbidden = try sb.scratch("elsewhere").appendingPathComponent("kept")
        #expect(switcherError { try engine.commit(keepPreviousAt: forbidden) } != nil)
        #expect(engine.journalPresent)                                     // retained for a retry
        #expect(fingerprint(sb.env.previousDir, Self.names) == previous)  // still there, never half-deleted
        #expect(!exists(forbidden))
        #expect(text(sb.env.claudeCookies) == "new-cookies")

        // Recorded destination inside the store: the retry through resolvePending() keeps the copy.
        let keep = sb.env.displacedDir.appendingPathComponent("kept-1")
        try engine.setKeepPrevious(keep)
        #expect(try engine.resolvePending() == .committed)
        #expect(!engine.journalPresent && !exists(sb.env.previousDir))
        #expect(fingerprint(keep, Self.names) == previous)
    }

    /// Without a destination the journal goes first, then previous/ is discarded.
    @Test func commitWithoutKeepingDiscardsPrevious() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        try engine.commit()
        #expect(!engine.journalPresent && !exists(sb.env.previousDir))
        #expect(try engine.resolvePending() == nil)
    }

    /// An orphaned previous/ (no journal) may be the only copy of a sign-in: install keeps it aside.
    @Test func installKeepsAnOrphanedPreviousAside() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try sb.fs.createDirectory(sb.env.previousDir)
        try sb.fs.write(Data("orphan".utf8), to: sb.env.previousDir.appendingPathComponent("Cookies"))
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        let kept = try FileManager.default.contentsOfDirectory(atPath: sb.env.displacedDir.path)
        #expect(kept.count == 1 && kept[0].hasPrefix("orphan-"))
        #expect(text(sb.env.displacedDir.appendingPathComponent(kept[0]).appendingPathComponent("Cookies")) == "orphan")
    }

    @Test func journalPresentCountsUnreadableJournals() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        #expect(!engine.journalPresent)
        try sb.fs.createDirectory(sb.env.storeDir)
        try sb.fs.write(Data("{garbage".utf8), to: sb.env.journalFile)
        #expect(engine.journalPresent && engine.journalIsUnreadable() && engine.pendingJournal() == nil)
        guard case .swapFailed = switcherError({ try engine.resolvePending() }) else {
            Issue.record("an unreadable journal must stop automatic recovery"); return
        }
        #expect(engine.journalPresent)
    }

    @Test func journalIsWrittenBeforeEachNextItem() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let seen = JournalLog()
        let env = sb.env
        let engine = SwapEngine(env: env, fs: sb.fs, isClaudeRunning: {
            let j = fileData(env.journalFile).flatMap { try? JSONDecoder().decode(SwapEngine.Journal.self, from: $0) }
            seen.append(j?.applied.count ?? -1)
            // Between items every applied entry is already marked done and the run is still "installing".
            if let j, j.state != "installing" || !j.applied.allSatisfy(\.done) { seen.append(-100) }
            return false
        })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names)
        // Checked before each of the 5 names; config.json, Cookies, -journal, -wal were applied in turn.
        #expect(seen.values == [0, 1, 2, 3, 4])
    }

    /// Files are never swapped back under a running Claude: the journal is kept until Claude is gone again.
    @Test func claudeStartingMidSwapKeepsTheJournalUntilClaudeStops() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let claude = ClaudeFlag()
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { claude.check() })
        try prepare(sb, engine: engine)
        let before = fingerprint(sb.env.claudeUserData, Self.names)
        claude.startAfter(3) // Claude appears before the third item
        let err = switcherError { try engine.install(names: Self.names) }
        // Distinct, accurate error: nothing was rolled back yet, recovery waits for Claude to quit.
        #expect(err == .swapInterrupted)
        let journal = try #require(engine.pendingJournal())
        #expect(journal.state == "installing")
        #expect(journal.applied.map(\.name) == ["config.json", "Cookies"])
        #expect(text(sb.env.claudeCookies) == "new-cookies") // left as is while Claude runs
        #expect(switcherError { try engine.resolvePending() } == .claudeStartedDuringSwap)
        #expect(engine.pendingJournal() == journal)

        claude.stop()
        #expect(try engine.resolvePending() == .rolledBack)
        #expect(fingerprint(sb.env.claudeUserData, Self.names) == before)
        #expect(!engine.journalPresent && !exists(sb.env.previousDir) && !exists(sb.env.stagingDir))
    }

    @Test func forbiddenItemFailsAndRollsBack() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try sb.fs.write(Data("evil".utf8), to: sb.env.stagingDir.appendingPathComponent("Preferences"))
        let before = fingerprint(sb.env.claudeUserData, Self.names + ["Preferences"])
        let err = switcherError { try engine.install(names: Self.names + ["Preferences"]) }
        guard case .swapFailed = err else { Issue.record("expected swapFailed, got \(String(describing: err))"); return }
        #expect(fingerprint(sb.env.claudeUserData, Self.names + ["Preferences"]) == before)
        #expect(engine.pendingJournal() == nil)
    }

    @Test func staleInstalledJournalIsCommittedBeforeANewInstall() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: Self.names) // fully applied, then the run died before commit
        let installed = fingerprint(sb.env.claudeUserData, Self.names)

        let staging = try engine.prepareStaging() // settles the old journal first: "installed" → committed
        #expect(engine.pendingJournal() == nil)
        #expect(!exists(sb.env.previousDir))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? ["?"]).isEmpty)
        #expect(fingerprint(sb.env.claudeUserData, Self.names) == installed)
        try sb.fs.write(Data("third-config".utf8), to: staging.appendingPathComponent("config.json"))
        try sb.fs.write(Data("third-cookies".utf8), to: staging.appendingPathComponent("Cookies"))
        try engine.install(names: Self.names)
        #expect(text(sb.env.claudeConfigJSON) == "third-config")
        #expect(text(sb.env.claudeCookies) == "third-cookies")
        // Rolling back the new install returns to the committed state, not to the one before it.
        try engine.rollback()
        #expect(fingerprint(sb.env.claudeUserData, Self.names) == installed)
    }

    @Test func installRefusesWhilePreviousJournalIsPending() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let engine = SwapEngine(env: sb.env, fs: sb.fs, isClaudeRunning: { false })
        try prepare(sb, engine: engine)
        try engine.install(names: [SnapshotItems.config])
        let journal = try #require(engine.pendingJournal())
        let live = fingerprint(sb.env.claudeUserData, Self.names)
        let previous = fingerprint(sb.env.previousDir, Self.names)
        let err = switcherError { try engine.install(names: Self.names) }
        guard case .swapFailed = err else { Issue.record("expected swapFailed, got \(String(describing: err))"); return }
        // No implicit rollback: live files, rollback material and the journal are exactly as they were.
        #expect(fingerprint(sb.env.claudeUserData, Self.names) == live)
        #expect(fingerprint(sb.env.previousDir, Self.names) == previous)
        #expect(engine.pendingJournal() == journal)
    }

    @Test func directoriesSwapAsUnits() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = SafeFS(env: sb.env, allowUIGroup: true)
        let engine = SwapEngine(env: sb.env, fs: fs, isClaudeRunning: { false })
        try sb.write("old", to: sb.env.claudeUserData.appendingPathComponent("Local Storage/leveldb/1.log"))
        let staging = try engine.prepareStaging()
        try fs.createDirectory(staging.appendingPathComponent("Local Storage/leveldb"))
        try fs.write(Data("new".utf8), to: staging.appendingPathComponent("Local Storage/leveldb/2.log"))
        try engine.install(names: ["Local Storage"])
        #expect(exists(sb.env.claudeUserData.appendingPathComponent("Local Storage/leveldb/2.log")))
        #expect(!exists(sb.env.claudeUserData.appendingPathComponent("Local Storage/leveldb/1.log")))
        try engine.rollback()
        #expect(exists(sb.env.claudeUserData.appendingPathComponent("Local Storage/leveldb/1.log")))
        #expect(!exists(sb.env.claudeUserData.appendingPathComponent("Local Storage/leveldb/2.log")))
    }
}

final class JournalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func append(_ v: Int) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}
