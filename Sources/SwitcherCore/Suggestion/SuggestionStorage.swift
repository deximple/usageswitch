import CryptoKit
import Darwin
import Foundation

public final class SuggestionAccountReference: @unchecked Sendable {
    private static let saltLock = NSLock()
    private let directory: URL
    private let saltFile: URL
    private let fs: SafeFS
    private var cachedSalt: Data?

    public init(env: SwitcherEnvironment, fs: SafeFS) {
        directory = env.storeDir.appendingPathComponent("suggestion", isDirectory: true)
        saltFile = directory.appendingPathComponent("salt")
        self.fs = fs
    }

    public func key(for accountRef: String) -> String? {
        guard !accountRef.isEmpty, let salt = loadOrCreateSalt() else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(accountRef.utf8), using: SymmetricKey(data: salt))
        return "acct-" + mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrCreateSalt() -> Data? {
        Self.saltLock.lock()
        defer { Self.saltLock.unlock() }
        if let cachedSalt { return cachedSalt }
        do { try fs.createDirectory(directory) } catch { return nil }

        var attributes = stat()
        if lstat(saltFile.path, &attributes) == 0 {
            guard (attributes.st_mode & S_IFMT) == S_IFREG,
                  attributes.st_uid == getuid(),
                  attributes.st_size == 32,
                  (attributes.st_mode & 0o077) == 0 else { return nil }
            let descriptor = open(saltFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var data = Data(count: 32)
            let count = data.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count == 32 else { return nil }
            cachedSalt = data
            return data
        }
        guard errno == ENOENT else { return nil }

        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        do {
            try fs.write(salt, to: saltFile)
            cachedSalt = salt
            return salt
        } catch {
            return nil
        }
    }
}

enum SuggestionStorage {
    static let maximumJSONLBytes = 1_048_576
    static let maximumLineBytes = 16_384

    static func appendLines<T: Encodable>(_ values: [T], component: String, day: String,
                                          directory: URL, fs: SafeFS,
                                          maxLineBytes: Int = maximumLineBytes) throws {
        guard !values.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for value in values {
            let line = try encoder.encode(value)
            guard line.count <= maxLineBytes else { continue }
            data.append(line)
            data.append(10)
        }
        guard !data.isEmpty else { return }

        let file = try nextFile(component: component, day: day, directory: directory, fs: fs)
        try fs.check(file)
        let descriptor = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SwitcherError.io("open suggestion log") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SwitcherError.io("chmod suggestion log") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw SwitcherError.io("append suggestion log") }
                offset += count
            }
        }
    }

    private static func nextFile(component: String, day: String, directory: URL,
                                 fs: SafeFS) throws -> URL {
        var part = 1
        while true {
            let suffix = part == 1 ? "" : "-\(part)"
            let file = directory.appendingPathComponent("\(component)-\(day)\(suffix).jsonl")
            try fs.check(file)
            var attributes = stat()
            if lstat(file.path, &attributes) != 0 {
                if errno == ENOENT { return file }
                throw SwitcherError.io("stat suggestion log")
            }
            guard (attributes.st_mode & S_IFMT) == S_IFREG else {
                throw SwitcherError.io("invalid suggestion log")
            }
            if attributes.st_size <= maximumJSONLBytes { return file }
            part += 1
        }
    }
}

enum SuggestionRetention {
    private static let lock = NSLock()
    private static let markerName = "retention-last-pruned-day"
    private static let filename = try? NSRegularExpression(
        pattern: #"^(?:observations|events|log-usage)-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:-[0-9]+)?\.jsonl$"#)

    static func prune(directory: URL, fs: SafeFS, now: Date,
                      reader: BoundedReader = .shared) {
        lock.lock()
        defer { lock.unlock() }
        do { try fs.createDirectory(directory) } catch { return }
        let today = utcDay(now)
        let marker = directory.appendingPathComponent(markerName)
        if case let .data(data) = reader.read(atPath: marker.path, using: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 32 else { return nil }
            return FileManager.default.contents(atPath: path)
        }), String(data: data, encoding: .utf8) == today {
            return
        }

        let cutoff = utcDay(now.addingTimeInterval(-30 * 24 * 60 * 60))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard let match = filename?.firstMatch(
                in: file.lastPathComponent, range: NSRange(file.lastPathComponent.startIndex..., in: file.lastPathComponent)),
                  let range = Range(match.range(at: 1), in: file.lastPathComponent) else { continue }
            if file.lastPathComponent[range] < cutoff {
                do { try fs.remove(file) } catch { return }
            }
        }
        do { try fs.write(Data(today.utf8), to: marker) } catch { return }
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
