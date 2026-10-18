import CryptoKit
import Foundation

/// Journaled, item-by-item replacement of Claude userData items using `renamex_np(RENAME_SWAP)`.
/// The journal entry for an item is written *before* the item is touched (write-ahead), together with a
/// digest of the staged content, so recovery can tell exactly how far an interrupted run got.
/// The replaced live items land in `previous/` so a failed switch can be rolled back exactly.
public struct SwapEngine: Sendable {
    public struct Journal: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case swapped, created, removed }
        public struct Item: Codable, Equatable, Sendable {
            public let name: String
            public let kind: Kind
            /// Set once every filesystem step for this item has completed.
            public var done: Bool
            /// Digest of the staged (incoming) content, recorded before the item is touched.
            public let stagedDigest: String?
            /// Digest of the original live content, recorded before the item is touched. Lets a resumed
            /// rollback recognise an item it already restored even after Claude rewrote the swapped-in copy.
            public let originalDigest: String?

            public init(name: String, kind: Kind, done: Bool, stagedDigest: String?, originalDigest: String? = nil) {
                self.name = name
                self.kind = kind
                self.done = done
                self.stagedDigest = stagedDigest
                self.originalDigest = originalDigest
            }

            /// Journals written before `done`/`stagedDigest` existed decode with conservative defaults.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                kind = try c.decode(Kind.self, forKey: .kind)
                done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? true
                stagedDigest = try c.decodeIfPresent(String.self, forKey: .stagedDigest)
                originalDigest = try c.decodeIfPresent(String.self, forKey: .originalDigest)
            }
        }
        /// "installing" while items are being applied, "installed" once all are.
        public var state: String
        public var applied: [Item]
        /// Where `previous/` must be kept on commit (the only copy of a sign-in that could not be saved).
        /// Persisted before Claude is relaunched so a crash during verification cannot lose it.
        public var keepPreviousAt: String? = nil
    }

    public enum Resolution: String, Sendable { case rolledBack = "rolled_back", committed }

    let env: SwitcherEnvironment
    let fs: SafeFS
    let isClaudeRunning: @Sendable () -> Bool

    public init(env: SwitcherEnvironment, fs: SafeFS, isClaudeRunning: @escaping @Sendable () -> Bool) {
        self.env = env
        self.fs = fs
        self.isClaudeRunning = isClaudeRunning
    }

    /// Any journal file at all (readable or not): the live files may be mid-swap.
    public var journalPresent: Bool { FileManager.default.fileExists(atPath: env.journalFile.path) }

    /// A journal file exists but cannot be read: never discard `previous/` in that state.
    public func journalIsUnreadable() -> Bool {
        FileManager.default.fileExists(atPath: env.journalFile.path) && pendingJournal() == nil
    }

    public func pendingJournal() -> Journal? {
        guard let data = FileManager.default.contents(atPath: env.journalFile.path) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private func save(_ j: Journal) throws {
        try fs.write(try JSONEncoder().encode(j), to: env.journalFile)
    }

    /// Settles a journal left by an interrupted run. Must only be called while Claude is not running.
    /// A fully applied ("installed") journal is accepted as-is; a partial one is rolled back.
    @discardableResult
    public func resolvePending() throws -> Resolution? {
        guard !journalIsUnreadable() else {
            throw SwitcherError.swapFailed(L10n.t(.reasonJournalCorrupt))
        }
        guard let journal = pendingJournal() else { return nil }
        if journal.state == "installed" {
            try commit()
            return .committed
        }
        try rollback()
        return .rolledBack
    }

    /// Records, inside the pending journal, that `previous/` must be kept at `destination` on commit.
    public func setKeepPrevious(_ destination: URL?) throws {
        guard let destination, var journal = pendingJournal() else { return }
        journal.keepPreviousAt = destination.path
        try save(journal)
    }

    /// Fresh, empty staging directory. Settles any interrupted run first, because its recovery may need
    /// the files it left in staging.
    public func prepareStaging() throws -> URL {
        try resolvePending()
        try fs.createDirectory(env.storeDir)
        try fs.remove(env.stagingDir)
        try fs.createDirectory(env.stagingDir)
        return env.stagingDir
    }

    /// Installs staged items over the live ones. `names` are processed in order; a name present live but not
    /// staged is moved aside (stale SQLite sidecars). On any error everything applied so far is rolled back.
    public func install(names: [String]) throws {
        guard pendingJournal() == nil else { throw SwitcherError.swapFailed(L10n.t(.reasonJournalPending)) }
        if Self.exists(env.previousDir) {
            // An orphaned previous/ (journal already gone) may be the only copy of a sign-in: keep it aside.
            try fs.createDirectory(env.displacedDir)
            try fs.move(env.previousDir, to: env.displacedDir.appendingPathComponent("orphan-\(UUID().uuidString)"))
        }
        try fs.createDirectory(env.previousDir)
        var journal = Journal(state: "installing", applied: [])
        try save(journal)
        do {
            for name in names {
                guard !isClaudeRunning() else { throw SwitcherError.claudeStartedDuringSwap }
                let live = env.claudeUserData.appendingPathComponent(name)
                let staged = env.stagingDir.appendingPathComponent(name)
                let prev = env.previousDir.appendingPathComponent(name)
                let kind: Journal.Kind
                switch (Self.exists(staged), Self.exists(live)) {
                case (true, true): kind = .swapped
                case (true, false): kind = .created
                case (false, true): kind = .removed
                case (false, false): continue
                }
                journal.applied.append(.init(
                    name: name, kind: kind, done: false,
                    stagedDigest: kind == .removed ? nil : try Self.digest(staged),
                    originalDigest: kind == .created ? nil : try Self.digest(live)))
                try save(journal)
                switch kind {
                case .swapped:
                    try fs.swap(staged, live)
                    try fs.move(staged, to: prev)
                case .created:
                    try fs.move(staged, to: live)
                case .removed:
                    try fs.move(live, to: prev)
                }
                journal.applied[journal.applied.count - 1].done = true
                try save(journal)
            }
            journal.state = "installed"
            try save(journal)
        } catch {
            do { try rollback() } catch SwitcherError.claudeStartedDuringSwap {
                // Claude is running on partly swapped files; the journal is kept until it quits.
                throw SwitcherError.swapInterrupted
            } catch {
                throw SwitcherError.swapFailed(L10n.t(.reasonSwapAndRollbackFailed, String(describing: error)))
            }
            if let e = error as? SwitcherError, e == .claudeStartedDuringSwap { throw e }
            throw SwitcherError.swapFailed(L10n.t(.reasonRolledBack, String(describing: error)))
        }
    }

    /// Undoes the journaled items in reverse order, restoring the exact previous live files. Items whose
    /// entry was written but whose steps did not all complete are inspected on disk.
    public func rollback() throws {
        guard let journal = pendingJournal() else { return }
        guard !isClaudeRunning() else { throw SwitcherError.claudeStartedDuringSwap }
        try markForRollback()
        for item in journal.applied.reversed() {
            guard !isClaudeRunning() else { throw SwitcherError.claudeStartedDuringSwap }
            let live = env.claudeUserData.appendingPathComponent(item.name)
            let staged = env.stagingDir.appendingPathComponent(item.name)
            let prev = env.previousDir.appendingPathComponent(item.name)
            switch item.kind {
            case .swapped:
                if Self.exists(prev) {
                    if try !alreadyRestored(live: live, prev: prev, item) { try fs.swap(prev, live) }
                    try fs.remove(prev)
                } else if Self.exists(staged), try stagingHoldsOriginal(staged: staged, live: live, item) {
                    // Swapped but not yet moved aside.
                    try fs.swap(staged, live)
                }
            case .created:
                if Self.exists(live) && (item.done || !Self.exists(staged)) { try fs.remove(live) }
            case .removed:
                if Self.exists(prev) { try fs.move(prev, to: live) }
            }
        }
        try fs.remove(env.journalFile)
        try fs.remove(env.previousDir)
        try fs.remove(env.stagingDir)
    }

    /// Marks the pending install as being undone, so an interrupted or failed rollback is resumed by
    /// `resolvePending()` instead of being committed half-undone.
    public func markForRollback() throws {
        guard var journal = pendingJournal(), journal.state != "installing" else { return }
        journal.state = "installing"
        try save(journal)
    }

    /// With `previous/<item>` present: has an interrupted rollback already put the original back into live?
    /// Uses the original digest (robust even after Claude rewrote the swapped-in copy); older journals fall
    /// back to "previous/ holds the staged copy".
    private func alreadyRestored(live: URL, prev: URL, _ item: Journal.Item) throws -> Bool {
        if let original = item.originalDigest { return try Self.digest(live) == original }
        return try Self.digest(prev) == item.stagedDigest
    }

    /// With `previous/<item>` absent: did the swap happen (staging now holds the original) but not the move?
    private func stagingHoldsOriginal(staged: URL, live: URL, _ item: Journal.Item) throws -> Bool {
        if let original = item.originalDigest {
            return try Self.digest(staged) == original && Self.digest(live) != original
        }
        return try Self.digest(staged) != item.stagedDigest
    }

    /// Accepts the installed state. The journal goes first (point of no return); then the previous copies are
    /// discarded, or kept at `keepPreviousAt` when they are the only copy of a sign-in that could not be saved.
    public func commit(keepPreviousAt destination: URL? = nil) throws {
        let keep = destination ?? pendingJournal()?.keepPreviousAt.map { URL(fileURLWithPath: $0) }
        if let keep {
            // Move first: if it fails the journal remains and a later resolvePending() retries the move.
            if Self.exists(env.previousDir) {
                try fs.createDirectory(keep.deletingLastPathComponent())
                try fs.move(env.previousDir, to: keep)
            }
            try fs.remove(env.journalFile)
        } else {
            try fs.remove(env.journalFile)
            try fs.remove(env.previousDir)
        }
        try fs.remove(env.stagingDir)
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// SHA-256 over a file, or over a directory's relative paths and file contents (sorted).
    static func digest(_ url: URL) throws -> String {
        var hasher = SHA256()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "" }
        if isDir.boolValue {
            let entries = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? []).sorted()
            for rel in entries {
                hasher.update(data: Data(rel.utf8))
                if let data = FileManager.default.contents(atPath: url.appendingPathComponent(rel).path) {
                    hasher.update(data: data)
                }
            }
        } else {
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw SwitcherError.io(L10n.t(.reasonReadFailed, url.lastPathComponent))
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
