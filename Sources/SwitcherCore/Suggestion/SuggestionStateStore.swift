import Darwin
import Foundation

public enum SuggestionStateEvent: Codable, Equatable, Sendable {
    case delta(SuggestionDelta)
    case reset(SuggestionResetEvent)
    case modeChanged(from: SuggestionMode, to: SuggestionMode,
                     snapshot: [SuggestionUsageSnapshot], at: Date)
    case taskChanged(from: Double, to: Double, source: SuggestionTaskChangeSource,
                     snapshot: [SuggestionUsageSnapshot], at: Date)
    case suggestionShown(candidate: SuggestionCandidate, at: Date)
    case suggestionAccepted(observed: Bool, at: Date)
    case suggestionDismissed(at: Date)
    case overrideStarted(at: Date)
    case overrideEnded(at: Date)
    case notificationEligible(rule: String, at: Date)
    case appGap(from: Date, to: Date)

    private enum CodingKeys: String, CodingKey {
        case type, delta, reset, from, to, source, snapshot, candidate, observed, at, rule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "delta": self = .delta(try container.decode(SuggestionDelta.self, forKey: .delta))
        case "reset": self = .reset(try container.decode(SuggestionResetEvent.self, forKey: .reset))
        case "modeChanged":
            self = .modeChanged(
                from: try container.decode(SuggestionMode.self, forKey: .from),
                to: try container.decode(SuggestionMode.self, forKey: .to),
                snapshot: try container.decode([SuggestionUsageSnapshot].self, forKey: .snapshot),
                at: try container.decode(Date.self, forKey: .at))
        case "taskChanged":
            self = .taskChanged(
                from: try container.decode(Double.self, forKey: .from),
                to: try container.decode(Double.self, forKey: .to),
                source: try container.decode(SuggestionTaskChangeSource.self, forKey: .source),
                snapshot: try container.decode([SuggestionUsageSnapshot].self, forKey: .snapshot),
                at: try container.decode(Date.self, forKey: .at))
        case "suggestionShown":
            self = .suggestionShown(candidate: try container.decode(SuggestionCandidate.self, forKey: .candidate),
                                    at: try container.decode(Date.self, forKey: .at))
        case "suggestionAccepted":
            self = .suggestionAccepted(observed: try container.decode(Bool.self, forKey: .observed),
                                       at: try container.decode(Date.self, forKey: .at))
        case "suggestionDismissed": self = .suggestionDismissed(at: try container.decode(Date.self, forKey: .at))
        case "overrideStarted": self = .overrideStarted(at: try container.decode(Date.self, forKey: .at))
        case "overrideEnded": self = .overrideEnded(at: try container.decode(Date.self, forKey: .at))
        case "notificationEligible":
            self = .notificationEligible(rule: try container.decode(String.self, forKey: .rule),
                                         at: try container.decode(Date.self, forKey: .at))
        case "appGap":
            self = .appGap(from: try container.decode(Date.self, forKey: .from),
                           to: try container.decode(Date.self, forKey: .to))
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
        case .modeChanged(let from, let to, let snapshot, let at):
            try container.encode("modeChanged", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(snapshot, forKey: .snapshot)
            try container.encode(at, forKey: .at)
        case .taskChanged(let from, let to, let source, let snapshot, let at):
            try container.encode("taskChanged", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(source, forKey: .source)
            try container.encode(snapshot, forKey: .snapshot)
            try container.encode(at, forKey: .at)
        case .suggestionShown(let candidate, let at):
            try container.encode("suggestionShown", forKey: .type)
            try container.encode(candidate, forKey: .candidate)
            try container.encode(at, forKey: .at)
        case .suggestionAccepted(let observed, let at):
            try container.encode("suggestionAccepted", forKey: .type)
            try container.encode(observed, forKey: .observed)
            try container.encode(at, forKey: .at)
        case .suggestionDismissed(let at):
            try container.encode("suggestionDismissed", forKey: .type)
            try container.encode(at, forKey: .at)
        case .overrideStarted(let at):
            try container.encode("overrideStarted", forKey: .type)
            try container.encode(at, forKey: .at)
        case .overrideEnded(let at):
            try container.encode("overrideEnded", forKey: .type)
            try container.encode(at, forKey: .at)
        case .notificationEligible(let rule, let at):
            try container.encode("notificationEligible", forKey: .type)
            try container.encode(rule, forKey: .rule)
            try container.encode(at, forKey: .at)
        case .appGap(let from, let to):
            try container.encode("appGap", forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        }
    }
}

public final class SuggestionStateStore: @unchecked Sendable {
    private static let maxSnapshotBytes = 1_048_576
    private static let maxSnapshotKeys = 512
    private static let appGapThreshold: TimeInterval = 15 * 60
    private static let observedAcceptanceWindow: TimeInterval = 30 * 60
    private let directory: URL
    private let lastObservationsFile: URL
    private let heartbeatFile: URL
    private let shownFile: URL
    private let fs: SafeFS
    private let reader: BoundedReader
    private let accountReferences: SuggestionAccountReference
    private let lock = NSLock()
    private var loaded = false
    private var last: [String: SuggestionObservation] = [:]
    private var identityKeys: [String: String] = [:]
    private var minimumGeneration = 0
    private var heartbeatLoaded = false
    private var lastActiveAt: Date?
    private var shownLoaded = false
    private var shownState: ShownState?

    private struct ShownState: Codable {
        let candidate: SuggestionCandidate
        let at: Date
        var accepted: Bool
    }

    public init(env: SwitcherEnvironment, fs: SafeFS, reader: BoundedReader = .shared) {
        directory = env.storeDir.appendingPathComponent("suggestion", isDirectory: true)
        lastObservationsFile = directory.appendingPathComponent("last-observations.json")
        heartbeatFile = directory.appendingPathComponent("last-active-at.json")
        shownFile = directory.appendingPathComponent("last-shown.json")
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

    public func accountKey(for accountRef: String) -> String? {
        accountReferences.key(for: accountRef)
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
        loadHeartbeat()
        let gapFrom = lastActiveAt.flatMap {
            now.timeIntervalSince($0) > Self.appGapThreshold ? $0 : nil
        }
        do {
            try fs.createDirectory(directory)
            if let gapFrom {
                try appendEvent(.appGap(from: gapFrom, to: now), now: now)
            }
            try writeDate(now, to: heartbeatFile)
            lastActiveAt = now
            heartbeatLoaded = true
        } catch {
            return
        }
        let result = SuggestionStateTracker().track(
            previous: last, previousIdentityKeys: identityKeys, fresh: fresh,
            appGap: gapFrom != nil,
            accountRefKey: { [accountReferences] provider, rawRef in
                accountReferences.key(for: rawRef)
            })
        let observations = result.observations
        do {
            let date = SuggestionRetention.utcDay(now)
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
            if !observations.isEmpty {
                limitSnapshot()
                try writeLastObservations()
            }
            SuggestionRetention.prune(directory: directory, fs: fs, now: now)
        } catch {
            return
        }
    }

    public func recordEvent(_ event: SuggestionStateEvent, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fs.createDirectory(directory)
            try appendEvent(event, now: now)
            SuggestionRetention.prune(directory: directory, fs: fs, now: now)
        } catch {
            return
        }
    }

    public func recordEventAfterSettingsSave(_ event: SuggestionStateEvent,
                                             succeeded: Bool, now: Date = Date()) {
        guard succeeded else { return }
        recordEvent(event, now: now)
    }

    @discardableResult
    public func recordSuggestionShown(_ candidate: SuggestionCandidate, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadShown()
        if let shownState,
           shownState.candidate.hasSameIdentity(as: candidate),
           now >= shownState.at,
           now.timeIntervalSince(shownState.at) < Self.observedAcceptanceWindow {
            return false
        }
        do {
            try fs.createDirectory(directory)
            try appendEvent(.suggestionShown(candidate: candidate, at: now), now: now)
            SuggestionRetention.prune(directory: directory, fs: fs, now: now)
            let state = ShownState(candidate: candidate, at: now, accepted: false)
            try write(state, to: shownFile)
            shownState = state
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func recordObservedAcceptance(candidate: SuggestionCandidate, observedAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadShown()
        guard var state = shownState,
              state.candidate.matchesUsage(provider: candidate.provider,
                  accountKey: candidate.accountKey, model: candidate.model ?? "",
                  effort: candidate.effort),
              candidate.model != nil, !state.accepted,
              observedAt >= state.at,
              observedAt.timeIntervalSince(state.at) <= Self.observedAcceptanceWindow else { return false }
        do {
            try fs.createDirectory(directory)
            try appendEvent(.suggestionAccepted(observed: true, at: observedAt), now: observedAt)
            state.accepted = true
            try write(state, to: shownFile)
            shownState = state
            return true
        } catch {
            return false
        }
    }

    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        try fs.remove(directory)
        try fs.createDirectory(directory)
        try accountReferences.rotateSalt()
        last.removeAll()
        identityKeys.removeAll()
        loaded = true
        lastActiveAt = nil
        heartbeatLoaded = true
        shownState = nil
        shownLoaded = true
    }

    private func appendEvent(_ event: SuggestionStateEvent, now: Date) throws {
        try SuggestionStorage.appendLines([event], component: "events",
            day: SuggestionRetention.utcDay(now), directory: directory, fs: fs)
    }

    private func loadHeartbeat() {
        guard !heartbeatLoaded else { return }
        heartbeatLoaded = true
        lastActiveAt = readDate(from: heartbeatFile)
    }

    private func loadShown() {
        guard !shownLoaded else { return }
        shownLoaded = true
        guard case let .data(data) = reader.read(atPath: shownFile.path, using: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 4096 else { return nil }
            return FileManager.default.contents(atPath: path)
        }) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        shownState = try? decoder.decode(ShownState.self, from: data)
    }

    private func readDate(from file: URL) -> Date? {
        guard case let .data(data) = reader.read(atPath: file.path, using: { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 64 else { return nil }
            return FileManager.default.contents(atPath: path)
        }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Date.self, from: data)
    }

    private func writeDate(_ date: Date, to file: URL) throws {
        try write(date, to: file)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try fs.write(encoder.encode(value), to: file)
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
