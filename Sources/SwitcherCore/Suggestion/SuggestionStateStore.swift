import Darwin
import Foundation

public enum SuggestionStateEvent: Codable, Sendable {
    case delta(SuggestionDelta)
    case reset(SuggestionResetEvent)

    private enum CodingKeys: String, CodingKey { case type, delta, reset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "delta": self = .delta(try container.decode(SuggestionDelta.self, forKey: .delta))
        case "reset": self = .reset(try container.decode(SuggestionResetEvent.self, forKey: .reset))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                         debugDescription: "Unknown suggestion event")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delta(let value):
            try container.encode("delta", forKey: .type)
            try container.encode(value, forKey: .delta)
        case .reset(let value):
            try container.encode("reset", forKey: .type)
            try container.encode(value, forKey: .reset)
        }
    }
}

public final class SuggestionStateStore: @unchecked Sendable {
    private static let maxLineBytes = 16_384
    private static let maxReadBytes = 1_048_576
    private let directory: URL
    private let fs: SafeFS
    private let reader: BoundedReader
    private let lock = NSLock()
    private var loaded = false
    private var last: [String: SuggestionObservation] = [:]
    private var identityKeys: [String: String] = [:]
    private var minimumGeneration = 0

    public init(env: SwitcherEnvironment, fs: SafeFS, reader: BoundedReader = .shared) {
        directory = env.storeDir.appendingPathComponent("suggestion", isDirectory: true)
        self.fs = fs
        self.reader = reader
    }

    public func loadLastObservations() -> [String: SuggestionObservation] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return last
    }

    public func invalidateBefore(_ generation: Int) {
        lock.lock()
        minimumGeneration = max(minimumGeneration, generation)
        lock.unlock()
    }

    public func record(_ fresh: [AccountUsage], now: Date = Date(), generation: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard generation >= minimumGeneration else { return }
        loadIfNeeded()
        let result = SuggestionStateTracker().track(
            previous: last, previousIdentityKeys: identityKeys, fresh: fresh)
        guard !result.observations.isEmpty else { return }
        let observations = result.observations.map {
            SuggestionObservation(
                at: $0.at, accountRef: UsageSnapshot.maskedString($0.accountRef),
                provider: $0.provider, windowKey: $0.windowKey, usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt, source: $0.source,
                toolVersion: $0.toolVersion.map(UsageSnapshot.maskedString))
        }
        do {
            try fs.createDirectory(directory)
            let date = Self.dayString(now)
            try appendLines(observations,
                            to: directory.appendingPathComponent("observations-\(date).jsonl"))
            let events = result.deltas.map(SuggestionStateEvent.delta)
                + result.resets.map(SuggestionStateEvent.reset)
            try appendLines(events, to: directory.appendingPathComponent("events-\(date).jsonl"))
        } catch {
            return
        }
        for observation in observations {
            let key = SuggestionStateTracker.key(provider: observation.provider,
                                                 accountRef: observation.accountRef,
                                                 windowKey: observation.windowKey)
            last[key] = observation
            if let identity = fresh.first(where: {
                UsageSnapshot.maskedString($0.accountRef) == observation.accountRef
                    && $0.provider == observation.provider
            })?.identityKey {
                identityKeys[key] = identity
            } else {
                identityKeys.removeValue(forKey: key)
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let newest = files.filter { $0.lastPathComponent.hasPrefix("observations-")
            && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(14)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in newest {
            guard case let .data(data) = reader.read(atPath: file.path, using: { path in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      (attrs[.size] as? NSNumber)?.intValue ?? 0 <= Self.maxReadBytes else { return nil }
                return FileManager.default.contents(atPath: path)
            }) else { continue }
            for line in data.split(separator: 10) where line.count <= Self.maxLineBytes {
                guard let observation = try? decoder.decode(
                    SuggestionObservation.self, from: Data(line)) else { continue }
                let key = SuggestionStateTracker.key(provider: observation.provider,
                                                     accountRef: observation.accountRef,
                                                     windowKey: observation.windowKey)
                if last[key].map({ $0.at < observation.at }) ?? true { last[key] = observation }
            }
        }
    }

    private func appendLines<T: Encodable>(_ values: [T], to file: URL) throws {
        guard !values.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for value in values {
            let line = try encoder.encode(value)
            guard line.count <= Self.maxLineBytes else { continue }
            data.append(line)
            data.append(10)
        }
        guard !data.isEmpty else { return }
        try fs.check(file)
        let fd = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SwitcherError.io("open suggestion log") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw SwitcherError.io("chmod suggestion log") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw SwitcherError.io("append suggestion log") }
                offset += count
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
