import CryptoKit
import Foundation

public struct SnapshotManifest: Codable, Equatable, Sendable {
    public struct FileEntry: Codable, Equatable, Sendable {
        public let name: String
        public let sha256: String
        public let size: Int
    }

    public let identity: AccountIdentity
    public let generation: Int
    public let capturedAt: Date
    public let claudeVersion: String?
    public let cookieMeta: CookieJar.Meta
    public let session: CookieJar.SessionInfo?
    public let files: [FileEntry]
}

public struct Snapshot: Equatable, Sendable {
    public let dir: URL
    public let manifest: SnapshotManifest
}

/// Stores one encrypted-as-is copy of Claude's cookie jar per account+org, keeping the newest
/// `keepGenerations` generations. Token caches are never stored (design D3).
public struct SnapshotStore: Sendable {
    let env: SwitcherEnvironment
    let fs: SafeFS
    public var keepGenerations = 2

    public init(env: SwitcherEnvironment, fs: SafeFS) {
        self.env = env
        self.fs = fs
    }

    static let manifestName = "manifest.json"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Snapshot directory for an identity. Non-UUID ids (which would become path components) are mapped to
    /// a directory that never exists, so nothing outside `snapshots/` can be read or written through them.
    func identityDir(_ identity: AccountIdentity) -> URL {
        guard ClaudeLog.isUUID(identity.accountUuid), ClaudeLog.isUUID(identity.orgUuid) else {
            return env.snapshotsDir.appendingPathComponent("invalid-identity", isDirectory: true)
        }
        return env.snapshotsDir.appendingPathComponent(identity.key, isDirectory: true)
    }

    static let reloginMarker = "relogin-required"

    /// Records that Claude rejected this generation's sign-in (design D5-2), so it shows as "재로그인 필요".
    public func markNeedsRelogin(_ identity: AccountIdentity) {
        guard let latest = latest(for: identity) else { return }
        try? fs.write(Data("1".utf8), to: latest.dir.appendingPathComponent(Self.reloginMarker))
    }

    public func needsRelogin(_ snapshot: Snapshot) -> Bool {
        FileManager.default.fileExists(atPath: snapshot.dir.appendingPathComponent(Self.reloginMarker).path)
    }

    /// A newest generation that is intact, not rejected by Claude and whose sessionKey has not expired.
    public func hasUsableSnapshot(for identity: AccountIdentity, now: Date) -> Bool {
        guard let snap = latest(for: identity), (try? verify(snap)) != nil, !needsRelogin(snap),
              let session = snap.manifest.session else { return false }
        return session.isValid(at: now)
    }

    /// Removes the token caches from a config.json kept in the store (displaced copies, original backup).
    public func stripTokenCaches(inConfigAt url: URL) {
        guard let data = FileManager.default.contents(atPath: url.path),
              (try? ClaudeConfig(data: data))?.hasTokenCache == true,
              let stripped = try? ClaudeConfig.strippingTokenCaches(data) else { return }
        try? fs.write(stripped, to: url)
    }

    /// Older original backups kept Claude's token caches; strip them in place.
    public func sanitizeOriginalBackup() {
        guard let backup = originalBackup() else { return }
        stripTokenCaches(inConfigAt: backup.appendingPathComponent(SnapshotItems.config))
    }

    public func generations(for identity: AccountIdentity) -> [Snapshot] {
        Self.generations(in: identityDir(identity))
    }

    /// Generations stored in one identity folder, newest first.
    static func generations(in dir: URL) -> [Snapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Snapshot? in
            guard name.hasPrefix("gen-"), Int(name.dropFirst(4)) != nil else { return nil }
            let genDir = dir.appendingPathComponent(name, isDirectory: true)
            guard let data = FileManager.default.contents(atPath: genDir.appendingPathComponent(Self.manifestName).path),
                  let manifest = try? Self.decoder.decode(SnapshotManifest.self, from: data) else { return nil }
            return Snapshot(dir: genDir, manifest: manifest)
        }.sorted { $0.manifest.generation > $1.manifest.generation }
    }

    public func latest(for identity: AccountIdentity) -> Snapshot? { generations(for: identity).first }

    /// Identities that have at least one saved generation (taken from their newest manifest). A folder whose
    /// manifest names a different identity is ignored, so a row can never point at another account's folder.
    public func savedIdentities() -> [AccountIdentity] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.snapshotsDir.path)) ?? []
        return names.sorted().compactMap { name -> AccountIdentity? in
            guard let probe = Self.identity(ofFolder: name),
                  let identity = latest(for: probe)?.manifest.identity, identity.key == name else { return nil }
            return identity
        }
    }

    /// `<account-uuid>__<org-uuid>` → a bare identity; nil for anything else.
    static func identity(ofFolder name: String) -> AccountIdentity? {
        let parts = name.components(separatedBy: "__")
        guard parts.count == 2, ClaudeLog.isUUID(parts[0]), ClaudeLog.isUUID(parts[1]) else { return nil }
        return AccountIdentity(accountUuid: parts[0], orgUuid: parts[1], email: nil, displayName: nil)
    }

    /// Deletes every saved generation of `identity` from this Mac (the account itself is untouched).
    public func remove(_ identity: AccountIdentity) throws {
        let dir = identityDir(identity)
        guard dir.lastPathComponent != "invalid-identity" else { return }
        try fs.remove(dir)
    }

    public struct LegacyImportResult: Equatable, Sendable {
        public let imported: Int
        /// Copies that failed with an I/O error; they are retried on the next run.
        public let failed: Int
    }

    /// One-time copy of the personal 1.0 build's saved sign-ins into this app's store (never moves or deletes
    /// them). Each identity is copied under a temporary name and renamed into place only once it checks out;
    /// copies that don't are dropped. Every settled folder (imported, already here, rejected) is recorded, so a
    /// retry after an I/O failure only copies what is still missing and never brings back a sign-in the user
    /// removed in between. The completion marker is written once nothing failed.
    @discardableResult
    public func importLegacySnapshotsIfNeeded() -> LegacyImportResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: env.legacyImportMarker.path),
              env.hasSeparateLegacyStore,
              let names = try? fm.contentsOfDirectory(atPath: env.legacySnapshotsDir.path) else {
            return LegacyImportResult(imported: 0, failed: 0)
        }
        // An unreadable record fails closed: importing blindly could bring back sign-ins the user removed.
        guard let recorded = loadHandledLegacyFolders() else { return LegacyImportResult(imported: 0, failed: 1) }
        var handled = recorded
        var imported = 0
        var failed = 0
        for name in names.sorted() where Self.identity(ofFolder: name) != nil && !handled.contains(name) {
            let source = env.legacySnapshotsDir.appendingPathComponent(name, isDirectory: true)
            let target = env.snapshotsDir.appendingPathComponent(name, isDirectory: true)
            // Already saved here, or not a real folder in the 1.0 store (a symlink is never followed): settled.
            guard Self.generations(in: target).isEmpty, Self.isRealDirectory(source) else {
                handled.insert(name)
                continue
            }
            let temp = env.snapshotsDir.appendingPathComponent(".import-\(name)", isDirectory: true)
            do {
                try fs.createDirectory(env.snapshotsDir)
                try fs.copy(source, to: temp)
                if isImportable(temp, folder: name) {
                    try fs.remove(target)   // an empty leftover of a failed capture holds nothing to keep
                    try fs.move(temp, to: target)
                    imported += 1
                } else {
                    try fs.remove(temp)
                }
                handled.insert(name)
            } catch {
                failed += 1
                try? fs.remove(temp)
            }
        }
        // The record is written every time (before the marker), so even a lost marker can't resurrect anything.
        do {
            try saveHandledLegacyFolders(handled)
            if failed == 0 { try fs.write(Data("\(imported)".utf8), to: env.legacyImportMarker) }
        } catch {
            failed += 1
        }
        return LegacyImportResult(imported: imported, failed: failed)
    }

    /// nil when the record exists but can't be read.
    func loadHandledLegacyFolders() -> Set<String>? {
        guard FileManager.default.fileExists(atPath: env.legacyImportHandled.path) else { return [] }
        guard let data = FileManager.default.contents(atPath: env.legacyImportHandled.path),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(names)
    }

    func saveHandledLegacyFolders(_ names: Set<String>) throws {
        try fs.createDirectory(env.storeDir)
        try fs.write(try JSONEncoder().encode(names.sorted()), to: env.legacyImportHandled)
    }

    /// Records a 1.0 identity folder as settled while the import is unfinished (no-op once it is complete).
    public func markLegacyFolderHandled(_ name: String) throws {
        guard env.hasSeparateLegacyStore, !FileManager.default.fileExists(atPath: env.legacyImportMarker.path) else { return }
        guard var handled = loadHandledLegacyFolders() else { throw SwitcherError.io(L10n.t(.reasonReadFailed, env.legacyImportHandled.lastPathComponent)) }
        handled.insert(name)
        try saveHandledLegacyFolders(handled)
    }

    /// A directory itself, not a symbolic link to one (lstat).
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A copied identity folder is kept only if it holds no symbolic links, every generation's manifest names
    /// this identity, and the newest generation matches its digests.
    func isImportable(_ dir: URL, folder: String) -> Bool {
        guard !Self.containsSymlink(dir) else { return false }
        let generations = Self.generations(in: dir)
        guard let newest = generations.first,
              generations.allSatisfy({ $0.manifest.identity.key == folder }) else { return false }
        return (try? verify(newest)) != nil
    }

    static func containsSymlink(_ dir: URL) -> Bool {
        let key: URLResourceKey = .isSymbolicLinkKey
        if (try? dir.resourceValues(forKeys: [key]))?.isSymbolicLink == true { return true }
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [key]) else { return true }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [key]))?.isSymbolicLink == true {
            return true
        }
        return false
    }

    /// Copies the cookie group out of `userData` (Claude must be fully quit) into a new generation.
    public func capture(from userData: URL, identity: AccountIdentity, claudeVersion: String?, now: Date = Date()) throws -> Snapshot {
        let next = (generations(for: identity).first?.manifest.generation ?? 0) + 1
        let base = identityDir(identity)
        let dir = base.appendingPathComponent("gen-\(next)", isDirectory: true)
        let partial = base.appendingPathComponent(".gen-\(next)-partial-\(UUID().uuidString)", isDirectory: true)
        try fs.createDirectory(env.storeDir)
        try fs.createDirectory(env.snapshotsDir)
        try fs.createDirectory(base)
        try fs.createDirectory(partial)
        do {
            var entries: [SnapshotManifest.FileEntry] = []
            for name in SnapshotItems.cookieGroup {
                let src = userData.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                let dst = partial.appendingPathComponent(name)
                try fs.copy(src, to: dst)
                entries.append(try Self.entry(for: dst))
            }
            let cookies = partial.appendingPathComponent("Cookies")
            guard FileManager.default.fileExists(atPath: cookies.path) else {
                throw SwitcherError.io(L10n.t(.reasonCookiesMissing))
            }
            let manifest = SnapshotManifest(
                identity: identity, generation: next, capturedAt: now, claudeVersion: claudeVersion,
                cookieMeta: try CookieJar.meta(of: cookies), session: try CookieJar.sessionInfo(of: cookies),
                files: entries)
            try fs.write(try Self.encoder.encode(manifest), to: partial.appendingPathComponent(Self.manifestName))
            try fs.move(partial, to: dir)
            try prune(identity)
            return Snapshot(dir: dir, manifest: manifest)
        } catch {
            try? fs.remove(partial)
            throw error
        }
    }

    func prune(_ identity: AccountIdentity) throws {
        for old in generations(for: identity).dropFirst(keepGenerations) { try fs.remove(old.dir) }
    }

    /// Re-hashes every file; throws if anything is missing or altered.
    public func verify(_ snapshot: Snapshot) throws {
        guard snapshot.manifest.files.contains(where: { $0.name == "Cookies" }) else {
            throw SwitcherError.snapshotCorrupt(L10n.t(.reasonFileMissing, "Cookies"))
        }
        for f in snapshot.manifest.files {
            let url = snapshot.dir.appendingPathComponent(f.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SwitcherError.snapshotCorrupt(L10n.t(.reasonFileMissing, f.name))
            }
            let actual = try Self.entry(for: url)
            guard actual.sha256 == f.sha256, actual.size == f.size else {
                throw SwitcherError.snapshotCorrupt(L10n.t(.reasonHashMismatch, f.name))
            }
        }
    }

    static func entry(for url: URL) throws -> SnapshotManifest.FileEntry {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw SwitcherError.io(L10n.t(.reasonReadFailed, url.lastPathComponent))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SnapshotManifest.FileEntry(name: url.lastPathComponent, sha256: digest, size: data.count)
    }

    // MARK: - One-time original backup (design D6): copy only, never auto-restored.

    public func originalBackup() -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.backupsDir.path)) ?? []
        return names.sorted().first { $0.hasPrefix("original-") }.map { env.backupsDir.appendingPathComponent($0) }
    }

    @discardableResult
    public func makeOriginalBackupIfNeeded(from userData: URL, now: Date = Date()) throws -> URL {
        if let existing = originalBackup() { return existing }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let dir = env.backupsDir.appendingPathComponent("original-\(stamp)", isDirectory: true)
        let partial = env.backupsDir.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try fs.createDirectory(env.storeDir)
        try fs.createDirectory(env.backupsDir)
        try fs.createDirectory(partial)
        let names = SnapshotItems.cookieGroup + [SnapshotItems.config] + SnapshotItems.uiGroup + SnapshotItems.originalBackupExtras
        for name in names {
            let src = userData.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try fs.copy(src, to: partial.appendingPathComponent(name))
            }
        }
        stripTokenCaches(inConfigAt: partial.appendingPathComponent(SnapshotItems.config))
        try fs.move(partial, to: dir)
        return dir
    }
}
