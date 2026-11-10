import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion lifecycle")
struct SuggestionLifecycleTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func environment(_ root: URL) -> SwitcherEnvironment {
        SwitcherEnvironment(home: root, claudeAppURL: root.appendingPathComponent("Claude.app"),
            claudeUserData: root.appendingPathComponent("Claude"),
            claudeLogsDir: root.appendingPathComponent("Logs"),
            launchAgentsDir: root.appendingPathComponent("Agents"),
            storeDir: root.appendingPathComponent("store"))
    }

    private func usage(_ percent: Double, at: Date, accountRef: String = "person@example.com") -> AccountUsage {
        AccountUsage(id: "codex:account", provider: .codex, accountRef: accountRef,
            label: "Person <person@example.com>", plan: nil,
            windows: [UsageWindow(durationMinutes: 300, usedPercent: percent,
                                  resetsAt: at.addingTimeInterval(3_600))],
            state: .ok, readAt: at, toolVersion: nil, identityKey: "identity")
    }

    private func candidate(_ accountKey: String = "acct-0123456789abcdef",
                           model: String? = "openai/test", effort: String? = "high") -> SuggestionCandidate {
        SuggestionCandidate(provider: .codex, accountKey: accountKey,
                            model: model, effort: effort)
    }

    private func eventFiles(in directory: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    @Test("old delta and reset events still decode and new events round-trip")
    func eventCodingCompatibility() throws {
        let oldDelta = Data(#"{"type":"delta","delta":{"windowKey":"session:300:*","accountRef":"acct-0123456789abcdef","from":10,"to":20,"usedDelta":10,"seconds":600}}"#.utf8)
        let oldReset = Data(#"{"type":"reset","reset":{"windowKey":"weekly:10080:*","accountRef":"acct-0123456789abcdef","at":1700000000,"kind":"soft","before":90,"after":10,"expectedAt":1700000000}}"#.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SuggestionStateEvent.self, from: oldDelta)
            == .delta(SuggestionDelta(windowKey: "session:300:*",
                accountRef: "acct-0123456789abcdef", from: 10, to: 20,
                usedDelta: 10, seconds: 600)))
        #expect(try decoder.decode(SuggestionStateEvent.self, from: oldReset)
            == .reset(SuggestionResetEvent(windowKey: "weekly:10080:*",
                accountRef: "acct-0123456789abcdef", at: start, kind: .soft,
                before: 90, after: 10, expectedAt: start)))

        let snapshot = SuggestionUsageSnapshot(provider: .codex, accountKey: "acct-0123456789abcdef",
            windowKey: "session:300:*", usedPercent: 40, resetsAt: start)
        let events: [SuggestionStateEvent] = [
            .modeChanged(from: .balanced, to: .focus, snapshot: [snapshot], at: start),
            .taskChanged(from: 0.5, to: 0.8, source: .declared, snapshot: [snapshot], at: start),
            .taskChanged(from: 0.8, to: 0.4, source: .override, snapshot: [snapshot], at: start),
            .reset(SuggestionResetEvent(windowKey: "weekly:10080:*",
                accountRef: "acct-0123456789abcdef", at: start, kind: .soft,
                before: 90, after: 10, expectedAt: start)),
            .suggestionShown(candidate: candidate(), at: start),
            .suggestionShown(candidate: SuggestionCandidate(provider: .claude,
                accountKey: "acct-0123456789abcdef", model: nil, effort: nil), at: start),
            .suggestionAccepted(observed: true, at: start),
            .suggestionAccepted(observed: false, at: start),
            .suggestionDismissed(at: start),
            .overrideStarted(at: start),
            .overrideEnded(at: start),
            .notificationEligible(rule: "window-near-limit", at: start),
            .appGap(from: start, to: start.addingTimeInterval(1_000)),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for event in events {
            let data = try encoder.encode(event)
            let decoded = try JSONDecoder.iso8601.decode(SuggestionStateEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    @Test("mode and task events are gated on successful settings saves")
    func settingsSaveGate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        let file = env.storeDir.appendingPathComponent("suggestion/events-\(SuggestionRetention.utcDay(start)).jsonl")
        let mode = SuggestionStateEvent.modeChanged(from: .balanced, to: .focus, snapshot: [], at: start)
        store.recordEventAfterSettingsSave(mode, succeeded: false, now: start)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.recordEventAfterSettingsSave(mode, succeeded: true, now: start)
        store.recordEventAfterSettingsSave(
            .taskChanged(from: 0.5, to: 0.7, source: .declared, snapshot: [], at: start),
            succeeded: true, now: start)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("modeChanged") })
        #expect(lines.contains { $0.contains("taskChanged") })
    }

    @Test("shown candidates dedupe by identity and observed acceptance is limited to 30 minutes")
    func shownAndAcceptance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        #expect(store.recordSuggestionShown(candidate(), now: start))
        #expect(!store.recordSuggestionShown(candidate(), now: start.addingTimeInterval(1)))
        #expect(store.recordSuggestionShown(candidate(model: "openai/other"),
                                              now: start.addingTimeInterval(2)))
        #expect(store.recordSuggestionShown(candidate(), now: start.addingTimeInterval(3)))
        #expect(store.recordObservedAcceptance(candidate: candidate(),
                                               observedAt: start.addingTimeInterval(30 * 60)))
        #expect(!store.recordObservedAcceptance(candidate: candidate(),
                                                observedAt: start.addingTimeInterval(30 * 60 + 1)))

        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherStore = SuggestionStateStore(env: environment(otherRoot), fs: SafeFS(env: environment(otherRoot)))
        #expect(otherStore.recordSuggestionShown(candidate(), now: start))
        #expect(!otherStore.recordObservedAcceptance(candidate: candidate(),
            observedAt: start.addingTimeInterval(30 * 60 + 1)))
    }

    @Test("same candidate can be shown again after the acceptance window")
    func repeatShownAfterAcceptanceWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))

        #expect(store.recordSuggestionShown(candidate(), now: start))
        #expect(!store.recordSuggestionShown(candidate(), now: start.addingTimeInterval(29 * 60)))
        #expect(store.recordSuggestionShown(candidate(), now: start.addingTimeInterval(31 * 60)))
        #expect(store.recordObservedAcceptance(candidate: candidate(),
            observedAt: start.addingTimeInterval(41 * 60)))

        let file = env.storeDir.appendingPathComponent(
            "suggestion/events-\(SuggestionRetention.utcDay(start)).jsonl")
        let events = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONDecoder.iso8601.decode(SuggestionStateEvent.self, from: Data($0.utf8)) }
        #expect(events.filter { if case .suggestionShown = $0 { return true }; return false }.count == 2)
        #expect(events.contains {
            guard case .suggestionAccepted(observed: true, at: let acceptedAt) = $0 else { return false }
            return acceptedAt == start.addingTimeInterval(41 * 60)
        })
    }

    @Test("app gaps are recorded and prevent tracker deltas across the gap")
    func appGapHandling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        store.record([usage(20, at: start)], now: start)
        let later = start.addingTimeInterval(16 * 60)
        store.record([usage(35, at: later)], now: later)
        let file = env.storeDir.appendingPathComponent(
            "suggestion/events-\(SuggestionRetention.utcDay(start)).jsonl")
        let events = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONDecoder.iso8601.decode(SuggestionStateEvent.self, from: Data($0.utf8)) }
        #expect(events.contains { if case .appGap(let from, let to) = $0 {
            return from == start && to == later
        }; return false })
        #expect(!events.contains { if case .delta = $0 { return true }; return false })

        let previous = SuggestionStateTracker().track(previous: [:], previousIdentityKeys: [:],
            fresh: [usage(20, at: start)]).observations
        let prior = try #require(previous.first)
        let windowKey = "session:300:*"
        let stateKey = SuggestionStateTracker.key(provider: .codex, accountRef: prior.accountRef,
                                                  windowKey: windowKey)
        let tracked = SuggestionStateTracker().track(
            previous: [stateKey: prior],
            previousIdentityKeys: [stateKey: "identity"],
            fresh: [usage(35, at: later)], appGap: true)
        #expect(tracked.deltas.isEmpty)
    }

    @Test("retention archives after 14 days, compresses after 30, expires after 180, and is idempotent")
    func retentionLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        try fs.createDirectory(directory)
        let day = SuggestionRetention.utcDay(start)
        let first = directory.appendingPathComponent("events-\(day).jsonl")
        let second = directory.appendingPathComponent("events-\(day)-2.jsonl")
        try fs.write(Data("first\n".utf8), to: first)
        try fs.write(Data("second\n".utf8), to: second)

        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(13 * 86_400))
        #expect(FileManager.default.fileExists(atPath: first.path))
        let archiveDirectory = directory.appendingPathComponent("archive")
        let archive = archiveDirectory.appendingPathComponent("events-\(day).jsonl")
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(15 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try String(contentsOf: archive, encoding: .utf8) == "first\nsecond\n")

        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(31 * 86_400))
        let compressed = archive.appendingPathExtension("zlib")
        let packed = try Data(contentsOf: compressed)
        #expect(try (packed as NSData).decompressed(using: .zlib) as Data == Data("first\nsecond\n".utf8))
        try fs.write(Data("late\n".utf8), to: directory.appendingPathComponent("events-\(day)-3.jsonl"))
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(31 * 86_400))
        let updatedPacked = try Data(contentsOf: compressed)
        #expect(try (updatedPacked as NSData).decompressed(using: .zlib) as Data
            == Data("first\nsecond\nlate\n".utf8))
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(31 * 86_400))
        #expect(FileManager.default.fileExists(atPath: compressed.path))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(181 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: compressed.path))
    }

    @Test("a crash after the archive write leaves the archive intact and removes old parts on retry")
    func archiveCrashRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        let archiveDirectory = directory.appendingPathComponent("archive")
        try fs.createDirectory(archiveDirectory)
        let day = SuggestionRetention.utcDay(start)
        let raw = directory.appendingPathComponent("events-\(day).jsonl")
        let archive = archiveDirectory.appendingPathComponent("events-\(day).jsonl")
        try fs.write(Data("complete archive\n".utf8), to: archive)
        try fs.write(Data("new part\n".utf8), to: raw)
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(15 * 86_400))
        #expect(try String(contentsOf: archive, encoding: .utf8) == "complete archive\nnew part\n")
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        let secondPart = directory.appendingPathComponent("events-\(day)-2.jsonl")
        try fs.write(Data("crash tail\n".utf8), to: secondPart)
        try fs.write(Data("complete archive\nnew part\ncrash tail\n".utf8), to: archive)
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(15 * 86_400))
        #expect(try String(contentsOf: archive, encoding: .utf8)
            == "complete archive\nnew part\ncrash tail\n")
        #expect(!FileManager.default.fileExists(atPath: secondPart.path))
    }

    @Test("flush removes learning artifacts and rotates account-reference salt")
    func flushAndSaltRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let store = SuggestionStateStore(env: env, fs: fs)
        try fs.createDirectory(env.storeDir)
        let sibling = env.storeDir.appendingPathComponent("unrelated-state.json")
        try fs.write(Data("leave-me".utf8), to: sibling)
        let accountRef = "person@example.com"
        let oldKey = try #require(store.accountKey(for: accountRef))
        store.record([usage(25, at: start)], now: start)
        #expect(store.recordSuggestionShown(candidate(oldKey), now: start))
        let directory = env.storeDir.appendingPathComponent("suggestion")
        try fs.write(Data("cursor".utf8), to: directory.appendingPathComponent("log-cursors.json"))
        try fs.createDirectory(directory.appendingPathComponent("archive"))
        try fs.write(Data("archive".utf8),
                     to: directory.appendingPathComponent("archive/events-\(SuggestionRetention.utcDay(start)).jsonl"))
        let settings = SwitcherSettings(suggestionMode: .focus, suggestionTask: 0.77)
        try fs.write(JSONEncoder().encode(settings), to: env.settingsFile)

        try store.flush()
        #expect(store.loadLastObservations().isEmpty)
        #expect(try Data(contentsOf: sibling) == Data("leave-me".utf8))
        #expect(!store.recordObservedAcceptance(candidate: candidate(oldKey), observedAt: start))
        #expect(try #require(store.accountKey(for: accountRef)) != oldKey)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("derived.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("last-observations.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("log-cursors.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("last-active-at.json").path))
        #expect(!FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("events-\(SuggestionRetention.utcDay(start)).jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive").path))
        let savedSettings = try JSONDecoder().decode(SwitcherSettings.self,
            from: Data(contentsOf: env.settingsFile))
        #expect(savedSettings.suggestionMode == .focus)
        #expect(savedSettings.suggestionTask == 0.77)
    }

    @Test("privacy scan of all Suggestion files excludes labels, emails, and raw account references")
    func privacyScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let store = SuggestionStateStore(env: env, fs: fs)
        let rawAccountRef = "private-account-reference-42"
        store.record([usage(20, at: start, accountRef: rawAccountRef)], now: start)
        let key = try #require(store.accountKey(for: rawAccountRef))
        store.recordEvent(.modeChanged(from: .balanced, to: .focus,
            snapshot: [SuggestionUsageSnapshot(provider: .codex, accountKey: key,
                windowKey: "session:300:*", usedPercent: 20, resetsAt: start)], at: start), now: start)
        let files = try eventFiles(in: root)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let bytes = try Data(contentsOf: file)
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(!text.contains("person@example.com"))
            #expect(!text.contains("Person <"))
            #expect(!text.contains(rawAccountRef))
        }
    }

    @Test("quiet signal appears only when enabled, collapsed, and the candidate differs")
    func quietSignalPredicate() {
        #expect(SwitcherSettings().effectiveSuggestionQuietSignal)
        #expect(SuggestionQuietSignal.shouldShow(enabled: true, guideExpanded: false,
            topCandidateID: "candidate", activeCandidateID: "active"))
        #expect(!SuggestionQuietSignal.shouldShow(enabled: false, guideExpanded: false,
            topCandidateID: "candidate", activeCandidateID: "active"))
        #expect(!SuggestionQuietSignal.shouldShow(enabled: true, guideExpanded: true,
            topCandidateID: "candidate", activeCandidateID: "active"))
        #expect(!SuggestionQuietSignal.shouldShow(enabled: true, guideExpanded: false,
            topCandidateID: "active", activeCandidateID: "active"))
        #expect(SuggestionQuietSignal.shouldShow(enabled: true, guideExpanded: false,
            topCandidateID: "candidate", activeCandidateID: nil))
        #expect(!SuggestionQuietSignal.shouldShow(enabled: true, guideExpanded: false,
            topCandidateID: nil, activeCandidateID: nil))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
