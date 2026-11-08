import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion state")
struct SuggestionStateTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let reset = Date(timeIntervalSince1970: 1_700_010_000)

    private func usage(_ percent: Double, at: Date, resetsAt: Date? = nil,
                       duration: Int? = 300, identity: String? = "identity",
                       state: UsageState = .ok, accountRef: String = "a",
                       toolVersion: String? = "1.2") -> AccountUsage {
        AccountUsage(id: "codex:a", provider: .codex, accountRef: accountRef, label: "private@example.com",
                     plan: "private-plan", windows: [
                        UsageWindow(scope: nil, durationMinutes: duration,
                                    usedPercent: percent, resetsAt: resetsAt)
                     ], state: state, readAt: at, toolVersion: toolVersion, identityKey: identity)
    }

    @Test("window key includes kind, duration, and scope")
    func windowKey() {
        #expect(Observation.windowKey(for: UsageWindow(
            scope: "model", durationMinutes: 300, usedPercent: 10, resetsAt: nil)) == "session:300:model")
        #expect(Observation.windowKey(for: UsageWindow(
            durationMinutes: nil, usedPercent: 10, resetsAt: nil)) == "other:?:*")
        #expect(SuggestionStateTracker.key(provider: .codex, accountRef: "acct-0123456789abcdef",
                                           windowKey: "session:300:*")
            == "codex\u{1f}acct-0123456789abcdef\u{1f}session:300:*")
    }

    @Test("continuous observations produce a delta; gaps and duration changes start segments")
    func continuity() {
        let windowKey = "session:300:*"
        let previous = SuggestionObservation(at: start, accountRef: "a", provider: .codex,
            windowKey: windowKey, usedPercent: 20, resetsAt: reset, source: .collector, toolVersion: nil)
        let key = SuggestionStateTracker.key(provider: .codex, accountRef: "a", windowKey: windowKey)
        let tracker = SuggestionStateTracker()
        let fresh = [usage(30, at: start.addingTimeInterval(120), resetsAt: reset)]
        let continuous = tracker.track(previous: [key: previous], previousIdentityKeys: [key: "identity"], fresh: fresh)
        #expect(continuous.deltas.count == 1 && continuous.deltas[0].usedDelta == 10)

        let gap = tracker.track(previous: [key: previous], previousIdentityKeys: [key: "identity"],
                                fresh: [usage(30, at: start.addingTimeInterval(601), resetsAt: reset)])
        #expect(gap.deltas.isEmpty)
        let changed = tracker.track(previous: [key: previous], previousIdentityKeys: [key: "identity"],
                                    fresh: [usage(30, at: start.addingTimeInterval(120),
                                                  resetsAt: reset, duration: 1440)])
        #expect(changed.deltas.isEmpty)
    }

    @Test("hard and soft resets are distinguished")
    func resets() {
        let windowKey = "session:300:*"
        let previous = SuggestionObservation(at: start, accountRef: "a", provider: .codex,
            windowKey: windowKey, usedPercent: 80, resetsAt: reset, source: .collector, toolVersion: nil)
        let key = SuggestionStateTracker.key(provider: .codex, accountRef: "a", windowKey: windowKey)
        let tracker = SuggestionStateTracker()
        let hard = tracker.track(previous: [key: previous], previousIdentityKeys: [key: "identity"],
            fresh: [usage(5, at: reset.addingTimeInterval(10), resetsAt: reset.addingTimeInterval(300))])
        #expect(hard.resets.first?.kind == .hard && hard.deltas.isEmpty)
        let soft = tracker.track(previous: [key: previous], previousIdentityKeys: [key: "identity"],
            fresh: [usage(5, at: start.addingTimeInterval(120), resetsAt: reset)])
        #expect(soft.resets.first?.kind == .soft && soft.deltas.isEmpty)
    }

    @Test("non-ok readings are ignored")
    func ignoresNonOK() {
        let result = SuggestionStateTracker().track(previous: [:], previousIdentityKeys: [:],
            fresh: [usage(40, at: start, state: .failed(.network))])
        #expect(result.observations.isEmpty && result.deltas.isEmpty && result.resets.isEmpty)
    }

    private func environment(_ root: URL) -> SwitcherEnvironment {
        SwitcherEnvironment(home: root, claudeAppURL: root.appendingPathComponent("Claude.app"),
            claudeUserData: root.appendingPathComponent("Claude"),
            claudeLogsDir: root.appendingPathComponent("Logs"),
            launchAgentsDir: root.appendingPathComponent("Agents"),
            storeDir: root.appendingPathComponent("store"))
    }

    @Test("JSONL reloads observations with owner-only permissions and no label or identity")
    func storeRoundtripPrivacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let row = usage(42, at: start, resetsAt: reset, accountRef: "jay.song@example.com",
                        toolVersion: "cli.user@example.com")
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        store.record([row], now: start)
        store.record([usage(47, at: start.addingTimeInterval(120), resetsAt: reset,
                           accountRef: "jay.song@example.com", toolVersion: "cli.user@example.com")],
                     now: start.addingTimeInterval(120))
        let directory = env.storeDir.appendingPathComponent("suggestion")
        let file = directory.appendingPathComponent("observations-2023-11-14.jsonl")
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("private-plan") == false)
        #expect(text.contains("private@example.com") == false)
        #expect(text.contains("jay.song@example.com") == false)
        #expect(text.contains("cli.user@example.com") == false)
        #expect(text.contains(UsageSnapshot.maskedString("cli.user@example.com")))
        #expect(text.contains("identity") == false)
        let reloaded = SuggestionStateStore(env: env, fs: SafeFS(env: env)).loadLastObservations()
        let accountRefKey = try #require(SuggestionAccountReference(
            env: env, fs: SafeFS(env: env)).key(for: "jay.song@example.com"))
        let key = SuggestionStateTracker.key(provider: .codex, accountRef: accountRefKey,
                                             windowKey: "session:300:*")
        #expect(reloaded[key]?.accountRef == accountRefKey)
        #expect(reloaded[key]?.usedPercent == 47)
        let eventFile = directory.appendingPathComponent("events-2023-11-14.jsonl")
        let eventText = try String(contentsOf: eventFile, encoding: .utf8)
        #expect(eventText.contains("jay.song@example.com") == false)
        #expect(eventText.contains("cli.user@example.com") == false)
        #expect(eventText.contains(accountRefKey))
        let eventLine = try #require(eventText.split(separator: "\n").last)
        let decoded = try JSONDecoder().decode(SuggestionStateEvent.self, from: Data(eventLine.utf8))
        if case .delta(let delta) = decoded {
            #expect(delta.usedDelta == 5)
        } else {
            Issue.record("Expected a delta event")
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let snapshotMode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("last-observations.json").path)[.posixPermissions] as? NSNumber
        let saltMode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("salt").path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
        #expect(snapshotMode?.intValue == 0o600)
        #expect(saltMode?.intValue == 0o600)
    }

    @Test("a store write failure is contained")
    func writeFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        try FileManager.default.createDirectory(at: env.storeDir, withIntermediateDirectories: true)
        try Data("block".utf8).write(to: env.storeDir.appendingPathComponent("suggestion"))
        SuggestionStateStore(env: env, fs: SafeFS(env: env)).record([usage(20, at: start)], now: start)
        #expect(!FileManager.default.fileExists(atPath:
            env.storeDir.appendingPathComponent("suggestion/observations-2023-11-14.jsonl").path))
    }

    @Test("account references use stable, distinct HMAC keys and never persist raw identifiers")
    func stableOpaqueAccountReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let firstRef = "app:11111111-1111-4111-8111-111111111111__aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let secondRef = "app:22222222-2222-4222-8222-222222222222__bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let firstKey = try #require(SuggestionAccountReference(
            env: env, fs: SafeFS(env: env)).key(for: firstRef))
        let secondKey = try #require(SuggestionAccountReference(
            env: env, fs: SafeFS(env: env)).key(for: secondRef))
        #expect(firstKey.hasPrefix("acct-") && firstKey.count == 21)
        #expect(secondKey.hasPrefix("acct-") && secondKey.count == 21)
        #expect(firstKey != secondKey)

        SuggestionStateStore(env: env, fs: SafeFS(env: env)).record([
            usage(20, at: start, resetsAt: reset, accountRef: firstRef),
            usage(30, at: start, resetsAt: reset, accountRef: secondRef),
        ], now: start)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(firstRef))
            #expect(!text.contains(secondRef))
        }

        let reloaded = SuggestionStateStore(env: env, fs: SafeFS(env: env)).loadLastObservations()
        #expect(Set(reloaded.values.map(\.accountRef)) == Set([firstKey, secondKey]))
        #expect(SuggestionAccountReference(env: env, fs: SafeFS(env: env)).key(for: firstRef) == firstKey)
    }

    @Test("latest-observation snapshot is capped at 512 account-window keys")
    func snapshotKeyLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let rows = (0..<513).map {
            usage(Double($0 % 90), at: start, resetsAt: reset, accountRef: "account-\($0)")
        }
        SuggestionStateStore(env: env, fs: SafeFS(env: env)).record(rows, now: start)
        let loaded = SuggestionStateStore(env: env, fs: SafeFS(env: env)).loadLastObservations()
        #expect(loaded.count == 512)
    }

    @Test("latest-observation snapshot reloads despite oversized daily JSONL and across dates")
    func boundedSnapshotReloadAndDateChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let store = SuggestionStateStore(env: env, fs: fs)
        store.record([usage(20, at: start, resetsAt: reset, accountRef: "one")], now: start)
        store.record([usage(30, at: start.addingTimeInterval(86_400),
                            resetsAt: reset, accountRef: "two")],
                     now: start.addingTimeInterval(86_400))
        let directory = env.storeDir.appendingPathComponent("suggestion")
        let today = directory.appendingPathComponent("observations-2023-11-15.jsonl")
        try Data(repeating: 120, count: 1_048_577).write(to: today)

        let loaded = SuggestionStateStore(env: env, fs: fs).loadLastObservations()
        #expect(loaded.count == 2)
        #expect(Set(loaded.values.map(\.usedPercent)) == Set([20, 30]))
        #expect(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("observations-2023-11-14.jsonl").path))
    }

    @Test("daily JSONL rotates over one MiB and expires archives older than 180 days")
    func rotationAndRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let fs = SafeFS(env: env)
        let store = SuggestionStateStore(env: env, fs: fs)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        try fs.createDirectory(directory)
        try Data(repeating: 120, count: 1_048_577)
            .write(to: directory.appendingPathComponent("observations-2023-11-14.jsonl"))
        try Data(repeating: 120, count: 1_048_577)
            .write(to: directory.appendingPathComponent("events-2023-11-14.jsonl"))
        try Data("old\n".utf8).write(to: directory.appendingPathComponent("log-usage-2023-01-01.jsonl"))
        let next = start.addingTimeInterval(120)
        store.record([usage(20, at: start, resetsAt: reset)], now: start)
        store.record([usage(25, at: next, resetsAt: reset)], now: next)
        #expect(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("observations-2023-11-14-2.jsonl").path))
        #expect(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("events-2023-11-14-2.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("log-usage-2023-01-01.jsonl").path))

        let oldFile = directory.appendingPathComponent("events-2023-01-01.jsonl")
        try Data("later old file\n".utf8).write(to: oldFile)
        SuggestionRetention.prune(directory: directory, fs: fs, now: start.addingTimeInterval(60))
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        SuggestionRetention.prune(directory: directory, fs: fs,
                                  now: start.addingTimeInterval(86_400))
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    }

    @Test("stale refresh generations cannot record rows after profile or consent changes")
    func staleGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        store.invalidateBefore(2)
        store.record([usage(20, at: start)], now: start, generation: 1)
        #expect(!FileManager.default.fileExists(atPath:
            env.storeDir.appendingPathComponent("suggestion").path))
    }

    @Test("flush preserves the minimum accepted generation")
    func flushKeepsGenerationFloor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = environment(root)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        store.invalidateBefore(5)
        try store.flush()
        store.record([usage(20, at: start)], now: start, generation: 3)

        let directory = env.storeDir.appendingPathComponent("suggestion")
        #expect(!FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("observations-2023-11-14.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("events-2023-11-14.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("last-observations.json").path))
    }
}
