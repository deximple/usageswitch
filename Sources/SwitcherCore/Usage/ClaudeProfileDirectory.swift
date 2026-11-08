import Darwin
import Foundation

public enum ClaudeProfileDirectory {
    struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    /// Accepts only a canonical, user-owned profile directory outside app-owned
    /// and default Claude data, with a regular identity config file.
    public static func validate(path: String, home: URL, excludedRoots: [URL]) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var directory = stat()
        guard lstat(path, &directory) == 0,
              (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == getuid(),
              (directory.st_mode & 0o022) == 0,
              realpathValue(path) == path
        else { return nil }

        let configPath = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".claude.json").path
        var config = stat()
        guard lstat(configPath, &config) == 0,
              (config.st_mode & S_IFMT) == S_IFREG
        else { return nil }

        let requiredRoots = [
            home.appendingPathComponent(".claude", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
        ] + excludedRoots
        for root in requiredRoots {
            let rootPath = realpathValue(root.path) ?? root.standardizedFileURL.path
            guard !contains(path, rootPath), !contains(rootPath, path) else { return nil }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func identity(at url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileIdentity(device: value.st_dev, inode: value.st_ino)
    }

    public static func matchesIdentity(at profile: URL, accountUuid: String, orgUuid: String) -> Bool {
        let path = profile.appendingPathComponent(".claude.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= 4 * 1_048_576
        else { return false }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { return false }
            if count == 0 { break }
            guard data.count <= 4 * 1_048_576 - count else { return false }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = object["oauthAccount"] as? [String: Any],
              let actualAccount = oauthAccount["accountUuid"] as? String,
              let actualOrg = oauthAccount["organizationUuid"] as? String
        else { return false }
        return actualAccount == accountUuid && actualOrg == orgUuid
    }

    static func realpathValue(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 })
            .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
