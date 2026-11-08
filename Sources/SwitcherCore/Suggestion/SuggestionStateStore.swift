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
    private static let maxSnapshotBytes = 1_048_576
    private static let maxSnapshotKeys = 512
    private let directory: URL
    private let lastObservationsFile: URL
    private let fs: SafeFS
    private let reader: BoundedReader
    private let accountReferences: SuggestionAccountReference
    private let lock = NSLock()
    private var loaded = false
    private var last: [String: SuggestionObservation] = [:]
    private var identityKeys: [String: String] = [:]
    private var minimumGeneration = 0

    public init(env: SwitcherEnvironment, fs: SafeFS, reader: BoundedReader = .shared) {
        directory = env.storeDir.appendingPathComponent("suggestion", isDirectory: true)
        lastObservationsFile = directory.appendingPathComponent("last-observations.json")
        self.fs = fs
        self.reader = reader
        accountReferences = SuggestionAccountReference(env: env, fs: fs)
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
            previous: last, previousIdentityKeys: identityKeys, fresh: fresh,
            accountRefKey: { [accountReferences] provider, rawRef in
                accountReferences.key(for: rawRef)
            })
        guard !result.observations.isEmpty else { return }
        let observations = result.observations
        do {
            try fs.createDirectory(directory)
            SuggestionRetention.prune(directory: directory, fs: fs, now: now, reader: reader)
            let date = SuggestionRetention.utcDay(now)
            try SuggestionStorage.appendLines(observations, component: "observations",
                                              day: date, directory: directory, fs: fs)
            let events = result.deltas.map(SuggestionStateEvent.delta)
                + result.resets.map(SuggestionStateEvent.reset)
            try SuggestionStorage.appendLines(events, component: "events", day: date,
                                              directory: directory, fs: fs)
            for observation in observations {
                let key = SuggestionStateTracker.key(provider: observation.provider,
                                                     accountRef: observation.accountRef,
                                                     windowKey: observation.windowKey)
                last[key] = observation
                if let identity = fresh.first(where: {
                    $0.provider == observation.provider
                        && accountReferences.key(for: $0.accountRef) == observation.accountRef
                })?.identityKey {
                    identityKeys[key] = identity
                } else {
                    identityKeys.removeValue(forKey: key)
                }
            }
            limitSnapshot()
            try writeLastObservations()
        } catch {
            return
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard case let .data(data) = reader.read(atPath: lastObservationsFile.path, using: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 <= Self.maxSnapshotBytes else { return nil }
            return FileManager.default.contents(atPath: path)
        }) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let observations = try? decoder.decode([SuggestionObservation].self, from: data) else { return }
        for observation in observations.prefix(Self.maxSnapshotKeys) {
            let key = SuggestionStateTracker.key(provider: observation.provider,
                                                 accountRef: observation.accountRef,
                                                 windowKey: observation.windowKey)
            last[key] = observation
        }
    }

    private func limitSnapshot() {
        let ordered = last.sorted {
            $0.value.at == $1.value.at ? $0.key < $1.key : $0.value.at > $1.value.at
        }
        last = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maxSnapshotKeys).map { ($0.key, $0.value) })
        identityKeys = identityKeys.filter { last[$0.key] != nil }
    }

    private func writeLastObservations() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ordered = last.sorted {
            $0.value.at == $1.value.at ? $0.key < $1.key : $0.value.at > $1.value.at
        }.map(\.value)
        var bounded = ordered
        var data = try encoder.encode(bounded)
        while data.count > Self.maxSnapshotBytes, !bounded.isEmpty {
            bounded.removeLast()
            data = try encoder.encode(bounded)
        }
        try fs.write(data, to: lastObservationsFile)
        let retained = Set(bounded.map {
            SuggestionStateTracker.key(provider: $0.provider, accountRef: $0.accountRef,
                                       windowKey: $0.windowKey)
        })
        last = last.filter { retained.contains($0.key) }
        identityKeys = identityKeys.filter { retained.contains($0.key) }
    }
}
