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

    public func rotateSalt() throws {
        Self.saltLock.lock()
        defer { Self.saltLock.unlock() }
        try fs.createDirectory(directory)
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try fs.write(salt, to: saltFile)
        cachedSalt = salt
    }

    func reset() {
        Self.saltLock.lock()
        defer { Self.saltLock.unlock() }
        cachedSalt = nil
    }

    private func loadOrCreateSalt() -> Data? {
        Self.saltLock.lock()
        defer { Self.saltLock.unlock() }
        if let cachedSalt { return cachedSalt }
        do { try fs.createDirectory(directory) } catch { return nil }

        var attributes = stat()
        if lstat(saltFile.path, &attributes) == 0 {
            if (attributes.st_mode & S_IFMT) == S_IFREG,
               attributes.st_uid == getuid(),
               attributes.st_size == 32,
               (attributes.st_mode & 0o077) == 0 {
                let descriptor = open(saltFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard descriptor >= 0 else { return nil }
                defer { close(descriptor) }
                var data = Data(count: 32)
                let count = data.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count == 32 { cachedSalt = data; return data }
            }
            // An unreadable or malformed salt means the learning files can't be trusted:
            // reset the folder and reseed below instead of failing every read forever (audit D-4).
            try? fs.remove(directory)
            do { try fs.createDirectory(directory) } catch { return nil }
        } else if errno != ENOENT {
            return nil
        }

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

    /// A file `appendLines` wrote to and its size before the write, for undoing the append.
    struct Appended {
        let file: URL
        let previousSize: off_t
    }

    /// Cuts each file back to the size it had before `appendLines` wrote to it.
    static func rollBack(_ appended: [Appended], fs: SafeFS) {
        for entry in appended {
            guard (try? fs.check(entry.file)) != nil else { continue }
            _ = truncate(entry.file.path, entry.previousSize)
        }
    }

    @discardableResult
    static func appendLines<T: Encodable>(_ values: [T], component: String, day: String,
                                          directory: URL, fs: SafeFS,
                                          maxLineBytes: Int = maximumLineBytes) throws -> Appended? {
        guard !values.isEmpty else { return nil }
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
        guard !data.isEmpty else { return nil }

        let file = try nextFile(component: component, day: day, directory: directory, fs: fs)
        try fs.check(file)
        let descriptor = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SwitcherError.io("open suggestion log") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SwitcherError.io("chmod suggestion log") }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw SwitcherError.io("stat suggestion log") }
        let appended = Appended(file: file, previousSize: before.st_size)
        do { try write(data, to: descriptor) } catch {
            rollBack([appended], fs: fs)
            throw error
        }
        return appended
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
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
    private static let maxArchiveBytes = 64 * 1_048_576
    private static let filename = try? NSRegularExpression(
        pattern: #"^(observations|events|log-usage)-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:-([0-9]+))?\.jsonl$"#)
    private static let archiveFilename = try? NSRegularExpression(
        pattern: #"^(observations|events|log-usage)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.jsonl(?:\.zlib)?$"#)


    static func prune(directory: URL, fs: SafeFS, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        do { try fs.createDirectory(directory) } catch { return }
        archiveRawFiles(directory: directory, fs: fs, now: now)
        compressArchives(directory: directory, fs: fs, now: now)
        expireArchives(directory: directory, fs: fs, now: now)
    }

    private static func archiveRawFiles(directory: URL, fs: SafeFS, now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        var groups: [String: [(part: Int, url: URL)]] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard let match = filename?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let componentRange = Range(match.range(at: 1), in: name),
                  let dayRange = Range(match.range(at: 2), in: name) else { continue }
            let component = String(name[componentRange])
            let day = String(name[dayRange])
            guard age(of: day, at: now) > 14 * 86_400 else { continue }
            let part: Int
            if let range = Range(match.range(at: 3), in: name), let parsed = Int(name[range]) {
                part = parsed
            } else {
                part = 1
            }
            groups["\(component)-\(day)", default: []].append((part, file))
        }

        let archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
        guard !groups.isEmpty else { return }
        do { try fs.createDirectory(archiveDirectory) } catch { return }
        for (stem, parts) in groups {
            let archive = archiveDirectory.appendingPathComponent(stem + ".jsonl")
            let compressedArchive = archive.appendingPathExtension("zlib")
            var combined: Data
            if let existing = readBounded(archive, fs: fs, maximum: maxArchiveBytes) {
                combined = existing
            } else if let packed = readBounded(compressedArchive, fs: fs, maximum: maxArchiveBytes),
                      let existing = try? (packed as NSData).decompressed(using: .zlib) as Data,
                      existing.count <= maxArchiveBytes {
                combined = existing
            } else if FileManager.default.fileExists(atPath: archive.path)
                        || FileManager.default.fileExists(atPath: compressedArchive.path) {
                continue
            } else {
                combined = Data()
            }

            for part in parts.sorted(by: { $0.part < $1.part }) {
                guard let data = readBounded(part.url, fs: fs,
                                             maximum: maxArchiveBytes - combined.count) else { break }
                if combined.count >= data.count,
                   combined.suffix(data.count).elementsEqual(data) {
                    do { try fs.remove(part.url) } catch { break }
                    continue
                }
                var updated = combined
                updated.append(data)
                do {
                    try fs.write(updated, to: archive)
                    combined = updated
                    try fs.remove(part.url)
                } catch {
                    break
                }
            }
        }
    }

    private static func compressArchives(directory: URL, fs: SafeFS, now: Date) {
        let archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jsonl" {
            guard let day = archiveDay(file.lastPathComponent),
                  age(of: day, at: now) > 30 * 86_400 else { continue }
            let compressed = archiveDirectory.appendingPathComponent(file.lastPathComponent + ".zlib")
            guard let data = readBounded(file, fs: fs, maximum: maxArchiveBytes) else { continue }
            if let existingPacked = readBounded(compressed, fs: fs, maximum: maxArchiveBytes),
               let existing = try? (existingPacked as NSData).decompressed(using: .zlib) as Data,
               existing == data {
                try? fs.remove(file)
                continue
            }
            guard let packed = try? (data as NSData).compressed(using: .zlib) else { continue }
            do {
                try fs.write(packed as Data, to: compressed)
                try fs.remove(file)
            } catch {
                continue
            }
        }
    }

    private static func expireArchives(directory: URL, fs: SafeFS, now: Date) {
        let archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard let day = archiveDay(file.lastPathComponent),
                  age(of: day, at: now) > 180 * 86_400 else { continue }
            try? fs.remove(file)
        }
    }


    private static func readBounded(_ file: URL, fs: SafeFS, maximum: Int) -> Data? {
        guard maximum >= 0, (try? fs.check(file)) != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size >= 0, size <= maximum else { return nil }
        return try? Data(contentsOf: file, options: [.mappedIfSafe])
    }

    private static func boundedData(_ file: URL, maximum: Int, reader: BoundedReader) -> Data? {
        guard case let .data(data) = reader.read(atPath: file.path, using: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 <= maximum else { return nil }
            return FileManager.default.contents(atPath: path)
        }) else { return nil }
        return data
    }

    private static func archiveDay(_ name: String) -> String? {
        guard let match = archiveFilename?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 2), in: name) else { return nil }
        return String(name[range])
    }

    private static func age(of day: String, at now: Date) -> TimeInterval {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return 0 }
        return max(0, now.timeIntervalSince(date))
    }

    /// The start of a `yyyy-MM-dd` UTC day, or nil when the text is not one.
    static func date(utcDay day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return day.count == 10 ? formatter.date(from: day) : nil
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
