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
    private static let markerName = "derived-last-computed-day"
    private static let maxArchiveBytes = 64 * 1_048_576
    private static let filename = try? NSRegularExpression(
        pattern: #"^(observations|events|log-usage)-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:-([0-9]+))?\.jsonl$"#)
    private static let archiveFilename = try? NSRegularExpression(
        pattern: #"^(observations|events|log-usage)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.jsonl(?:\.zlib)?$"#)

    struct DerivedRecord: Codable, Equatable {
        let provider: UsageProvider
        let accountKey: String
        let windowKey: String
        let medianBurnRatePerHour: Double?
        let p90BurnRatePerHour: Double?
        let shownCount: Int
        let acceptedObservedCount: Int
        let acceptedExplicitCount: Int
        let dismissedCount: Int
        let acceptanceRate: Double
    }

    private struct DerivedFile: Codable {
        let generatedAt: Date
        let records: [DerivedRecord]
    }

    private struct MetricKey: Hashable {
        let provider: UsageProvider
        let accountKey: String
        let windowKey: String
    }

    private struct Counts {
        var shown = 0
        var observed = 0
        var explicit = 0
        var dismissed = 0
    }

    static func prune(directory: URL, fs: SafeFS, now: Date,
                      reader: BoundedReader = .shared) {
        lock.lock()
        defer { lock.unlock() }
        do { try fs.createDirectory(directory) } catch { return }
        archiveRawFiles(directory: directory, fs: fs, now: now)
        compressArchives(directory: directory, fs: fs, now: now)
        expireArchives(directory: directory, fs: fs, now: now)
        recomputeDerived(directory: directory, fs: fs, now: now, reader: reader)
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

    private static func recomputeDerived(directory: URL, fs: SafeFS, now: Date,
                                        reader: BoundedReader) {
        let today = utcDay(now)
        let marker = directory.appendingPathComponent(markerName)
        if let data = boundedData(marker, maximum: 32, reader: reader),
           String(data: data, encoding: .utf8) == today { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let firstDay = utcDay(now.addingTimeInterval(-13 * 86_400))
        let eventFiles = files.filter { file in
            guard let match = filename?.firstMatch(
                in: file.lastPathComponent, range: NSRange(file.lastPathComponent.startIndex..., in: file.lastPathComponent)),
                  let componentRange = Range(match.range(at: 1), in: file.lastPathComponent),
                  let dayRange = Range(match.range(at: 2), in: file.lastPathComponent) else { return false }
            return file.lastPathComponent[componentRange] == "events"
                && file.lastPathComponent[dayRange] >= firstDay
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var totalBytes = 0
        var rates: [MetricKey: [Double]] = [:]
        var counts: [MetricKey: Counts] = [:]
        var latestCandidate: MetricKey?
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in eventFiles {
            guard let data = readBounded(file, fs: fs, maximum: maxArchiveBytes - totalBytes) else { return }
            totalBytes += data.count
            for line in data.split(separator: 10, omittingEmptySubsequences: true)
                where line.count <= SuggestionStorage.maximumLineBytes {
                guard let event = try? decoder.decode(
                    SuggestionStateEvent.self, from: Data(line)) else { continue }
                switch event {
                case .delta(let delta):
                    guard let provider = delta.provider, delta.seconds > 0,
                          delta.usedDelta.isFinite else { continue }
                    let key = MetricKey(provider: provider, accountKey: delta.accountRef,
                                        windowKey: delta.windowKey)
                    let rate = delta.usedDelta * 3_600 / delta.seconds
                    guard rate.isFinite else { continue }
                    rates[key, default: []].append(rate)
                case .suggestionShown(let candidate, _):
                    let key = MetricKey(provider: candidate.provider, accountKey: candidate.accountKey,
                                        windowKey: "*")
                    counts[key, default: Counts()].shown += 1
                    latestCandidate = key
                case .suggestionAccepted(let observed, _):
                    guard let latestCandidate else { continue }
                    if observed { counts[latestCandidate, default: Counts()].observed += 1 }
                    else { counts[latestCandidate, default: Counts()].explicit += 1 }
                case .suggestionDismissed:
                    guard let latestCandidate else { continue }
                    counts[latestCandidate, default: Counts()].dismissed += 1
                default:
                    continue
                }
            }
        }
        let keys = Set(rates.keys).union(counts.keys).sorted {
            if $0.provider.rawValue != $1.provider.rawValue { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.accountKey != $1.accountKey { return $0.accountKey < $1.accountKey }
            return $0.windowKey < $1.windowKey
        }
        let records = keys.prefix(512).map { key -> DerivedRecord in
            let values = (rates[key] ?? []).sorted()
            let count = counts[key] ?? Counts()
            let accepted = count.observed + count.explicit
            let median: Double?
            if values.isEmpty { median = nil }
            else if values.count.isMultiple(of: 2) {
                median = (values[values.count / 2 - 1] + values[values.count / 2]) / 2
            } else {
                median = values[values.count / 2]
            }
            let p90 = values.isEmpty ? nil : values[max(0, Int(ceil(Double(values.count) * 0.9)) - 1)]
            return DerivedRecord(provider: key.provider, accountKey: key.accountKey,
                windowKey: key.windowKey, medianBurnRatePerHour: median, p90BurnRatePerHour: p90,
                shownCount: count.shown, acceptedObservedCount: count.observed,
                acceptedExplicitCount: count.explicit, dismissedCount: count.dismissed,
                acceptanceRate: count.shown == 0 ? 0 : Double(accepted) / Double(count.shown))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try fs.write(encoder.encode(DerivedFile(generatedAt: now, records: records)),
                         to: directory.appendingPathComponent("derived.json"))
            try fs.write(Data(today.utf8), to: marker)
        } catch {
            return
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

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
