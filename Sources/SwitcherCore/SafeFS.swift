import Darwin
import Foundation

/// The single write gateway (design D6). Every mutation of the filesystem made by the switcher
/// goes through here; anything outside the allowlist throws `SwitcherError.forbiddenWrite`.
public struct SafeFS: Sendable {
    public let storeDir: URL
    public let claudeUserData: URL
    /// Item names directly under Claude's userData that may be replaced.
    public let allowedUserDataItems: Set<String>
    /// Test seam: fires after every mutation with "op path" — nil in production (audit B-13).
    let afterOperation: (@Sendable (String) -> Void)?

    public init(env: SwitcherEnvironment, allowUIGroup: Bool = false,
                afterOperation: (@Sendable (String) -> Void)? = nil) {
        storeDir = env.storeDir.standardizedFileURL
        claudeUserData = env.claudeUserData.standardizedFileURL
        var items = Set(SnapshotItems.cookieGroup)
        items.insert(SnapshotItems.config)
        if allowUIGroup { items.formUnion(SnapshotItems.uiGroup) }
        allowedUserDataItems = items
        self.afterOperation = afterOperation
    }

    // MARK: - Policy

    public func isAllowed(_ url: URL) -> Bool {
        let path = Self.normalized(url)
        if path == Self.normalized(storeDir) || path.hasPrefix(Self.normalized(storeDir) + "/") {
            return true
        }
        let parent = Self.normalized(url.deletingLastPathComponent())
        if parent == Self.normalized(claudeUserData) {
            // The item itself must not be a symlink that resolves somewhere else.
            return allowedUserDataItems.contains(url.lastPathComponent) && path == parent + "/" + url.lastPathComponent
        }
        return false
    }

    public func check(_ url: URL) throws {
        guard isAllowed(url) else { throw SwitcherError.forbiddenWrite(url.path) }
    }

    /// Resolves `..` and symlinks of existing ancestors so a crafted path cannot escape the allowlist.
    static func normalized(_ url: URL) -> String {
        var current = url.standardizedFileURL
        var trailing: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) && current.path != "/" {
            trailing.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }
        var resolved = current.resolvingSymlinksInPath()
        for component in trailing { resolved.appendPathComponent(component) }
        let path = resolved.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - Operations

    public func createDirectory(_ url: URL) throws {
        try check(url)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = chmod(url.path, 0o700)
        } catch { throw SwitcherError.io("mkdir \(url.lastPathComponent): \(error.localizedDescription)") }
        afterOperation?("createDirectory \(url.path)")
    }

    public func write(_ data: Data, to url: URL, permissions: Int16 = 0o600) throws {
        try check(url)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try check(tmp)
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
            _ = chmod(tmp.path, mode_t(permissions))
            if rename(tmp.path, url.path) != 0 { throw SwitcherError.io("rename: \(String(cString: strerror(errno)))") }
        } catch let e as SwitcherError {
            try? FileManager.default.removeItem(at: tmp)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SwitcherError.io("write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        afterOperation?("write \(url.path)")
    }

    /// Copies a file or directory. Destination must be allowed; source is only read.
    public func copy(_ src: URL, to dst: URL) throws {
        try check(dst)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
            try restrictPermissions(dst)
        } catch let e as SwitcherError { throw e } catch {
            throw SwitcherError.io("copy \(src.lastPathComponent): \(error.localizedDescription)")
        }
        afterOperation?("copy \(src.path) \(dst.path)")
    }

    public func move(_ src: URL, to dst: URL) throws {
        try check(src)
        try check(dst)
        if rename(src.path, dst.path) != 0 {
            throw SwitcherError.io("move \(src.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        afterOperation?("move \(src.path) \(dst.path)")
    }

    /// Atomically exchanges two existing paths on the same volume (files or directories).
    public func swap(_ a: URL, _ b: URL) throws {
        try check(a)
        try check(b)
        if renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) != 0 {
            throw SwitcherError.io("swap \(a.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        afterOperation?("swap \(a.path) \(b.path)")
    }

    public func remove(_ url: URL) throws {
        try check(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            throw SwitcherError.io("remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
        afterOperation?("remove \(url.path)")
    }

    /// Owner-only permissions for everything inside the switcher store.
    public func restrictPermissions(_ url: URL) throws {
        try check(url)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        _ = chmod(url.path, isDir.boolValue ? 0o700 : 0o600)
        guard isDir.boolValue, let e = FileManager.default.enumerator(atPath: url.path) else { return }
        for case let rel as String in e {
            let child = url.appendingPathComponent(rel)
            var st = stat()
            // lstat + skip symlinks: chmod(2) would follow a link out of the store.
            guard lstat(child.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
            _ = chmod(child.path, (st.st_mode & S_IFMT) == S_IFDIR ? 0o700 : 0o600)
        }
        afterOperation?("restrictPermissions \(url.path)")
    }
}
