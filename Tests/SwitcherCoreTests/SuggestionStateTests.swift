import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion state")
struct SuggestionStateTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let reset = Date(timeIntervalSince1970: 1_700_010_000)

    private func usage(_ percent: Double, at: Date, resetsAt: Date? = nil,
                       duration: Int? = 300, identity: String? = "identity",
                       state: UsageState = .ok) -> AccountUsage {
        AccountUsage(id: "codex:a", provider: .codex, accountRef: "a", label: "private@example.com",
                     plan: "private-plan", windows: [
                        UsageWindow(scope: nil, durationMinutes: duration,
                                    usedPercent: percent, resetsAt: resetsAt)
                     ], state: state, readAt: at, toolVersion: "1.2", identityKey: identity)
    }

    @Test("window key includes kind, duration, and scope")
    func windowKey() {
        #expect(Observation.windowKey(for: UsageWindow(
            scope: "model", durationMinutes: 300, usedPercent: 10, resetsAt: nil)) == "session:300:model")
        #expect(Observation.windowKey(for: UsageWindow(
            durationMinutes: nil, usedPercent: 10, resetsAt: nil)) == "other:?:*")
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
        let row = usage(42, at: start, resetsAt: reset)
        let store = SuggestionStateStore(env: env, fs: SafeFS(env: env))
        store.record([row], now: start)
        store.record([usage(47, at: start.addingTimeInterval(120), resetsAt: reset)],
                     now: start.addingTimeInterval(120))
        let directory = env.storeDir.appendingPathComponent("suggestion")
        let file = directory.appendingPathComponent("observations-2023-11-14.jsonl")
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("private-plan") == false)
        #expect(text.contains("private@example.com") == false)
        #expect(text.contains("identity") == false)
        #expect(SuggestionStateStore(env: env, fs: SafeFS(env: env))
            .loadLastObservations().values.first?.usedPercent == 47)
        let eventFile = directory.appendingPathComponent("events-2023-11-14.jsonl")
        let eventLine = try #require(try String(contentsOf: eventFile, encoding: .utf8)
            .split(separator: "\n").last)
        let decoded = try JSONDecoder().decode(SuggestionStateEvent.self, from: Data(eventLine.utf8))
        if case .delta(let delta) = decoded {
            #expect(delta.usedDelta == 5)
        } else {
            Issue.record("Expected a delta event")
        }
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
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
}
