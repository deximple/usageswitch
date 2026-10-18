import Darwin
import Foundation

/// Small JSON files in the store that the app and the CLI may both change: every change is a read-modify-write
/// under an exclusive lock, and a file that can't be read is reported instead of overwritten.
enum LockedStoreFile {
    /// The decoded file; `empty` when it doesn't exist, nil when it exists but can't be read.
    static func load<T: Decodable>(_ file: URL, as type: T.Type, empty: T) -> T? {
        guard FileManager.default.fileExists(atPath: file.path) else { return empty }
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// - Parameter setAsideUnreadable: keep an unreadable file next to the new one (`<name>.unreadable-<time>`) and
    ///   start from `empty`, instead of refusing (for plain preferences, where starting over loses nothing important).
    static func update<T: Codable>(_ file: URL, lock: URL, env: SwitcherEnvironment, fs: SafeFS, empty: T,
                                   isEmpty: (T) -> Bool, setAsideUnreadable: Bool = false,
                                   _ change: (inout T) throws -> Void) throws {
        try fs.createDirectory(env.storeDir)
        try fs.check(lock)
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError.io(L10n.t(.reasonLockOpenFailed)) }
        defer { close(fd) }   // closing the descriptor releases the lock
        guard flock(fd, LOCK_EX) == 0 else { throw SwitcherError.io(L10n.t(.reasonLockOpenFailed)) }
        var loaded = load(file, as: T.self, empty: empty)
        if loaded == nil && setAsideUnreadable {
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.lastPathComponent).unreadable-\(Int(Date().timeIntervalSince1970))")
            try fs.move(file, to: aside)
            loaded = empty
        }
        guard var value = loaded else {
            throw SwitcherError.io(L10n.t(.reasonReadFailed, file.lastPathComponent))
        }
        try change(&value)
        if isEmpty(value) {
            try fs.remove(file)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try fs.write(try encoder.encode(value), to: file)
        }
    }
}
