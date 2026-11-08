import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion log reader")
struct SuggestionLogReaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func environment(_ root: URL) -> SwitcherEnvironment {
        SwitcherEnvironment(home: root, claudeAppURL: root.appendingPathComponent("Claude.app"),
            claudeUserData: root.appendingPathComponent("Claude"),
            claudeLogsDir: root.appendingPathComponent("Logs"),
            launchAgentsDir: root.appendingPathComponent("Agents"),
            storeDir: root.appendingPathComponent("store"))
    }

    private func claudeRoot(_ root: URL, accountRef: String = "cli") throws -> SuggestionLogRoot {
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        let project = config.appendingPathComponent("projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return SuggestionLogRoot(provider: .claude, accountRef: accountRef, directory: config)
    }

    private func codexRoot(_ root: URL, accountRef: String = "standard") throws -> SuggestionLogRoot {
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let session = home.appendingPathComponent("sessions/2027/01", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return SuggestionLogRoot(provider: .codex, accountRef: accountRef, directory: home)
    }

    private func write(_ text: String, to url: URL, modifiedAt: Date? = nil) throws {
        try Data(text.utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func timestamp(_ date: Date? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date ?? now)
    }

    private func claudeLine(id: String, input: Int, timestamp: String? = nil) -> String {
        let at = timestamp ?? self.timestamp()
        return #"{"type":"assistant","timestamp":"\#(at)","effort":"high","version":"1.2","message":{"id":"\#(id)","model":"claude-fable-5-1","usage":{"input_tokens":\#(input),"output_tokens":7,"cache_read_input_tokens":2,"cache_creation_input_tokens":3}},"content":[{"text":"jay.song@example.com sk-ant-FAKE /Users/jay/private"}],"cwd":"/Users/jay/private"}"#
    }

    private func reader(_ root: URL, catalog: SuggestionCatalog? = nil) -> SuggestionLogReader {
        let env = environment(root)
        return SuggestionLogReader(env: env, fs: SafeFS(env: env), catalog: catalog)
    }

    @Test("Claude deduplicates by message ID, keeps only the last scalar record, and persists no content")
    func claudeDedupeAndPrivacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root, accountRef: "jay.song@example.com")
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        let fixture = """
        {"type":"user","content":[{"text":"jay.song@example.com sk-ant-FAKE /Users/jay/private"}],"cwd":"/Users/jay/private"}
        \(claudeLine(id: "message-id-private", input: 10))
        \(claudeLine(id: "message-id-private", input: 20))
        {malformed json
        """
        try write(fixture + "\n", to: file, modifiedAt: now)

        let logReader = reader(root)
        let pass = logReader.read(roots: [logRoot], now: now)
        #expect(pass.records.count == 1)
        let record = try #require(pass.records.first)
        #expect(record.turns == 1)
        #expect(record.inputTokens == 20)
        #expect(record.cachedInputTokens == 5)
        #expect(record.outputTokens == 7)
        #expect(record.effort == "high")
        #expect(record.provider == .claude)
        #expect(record.accountRef.hasPrefix("acct-"))

        let directory = environment(root).storeDir.appendingPathComponent("suggestion")
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for persistedFile in contents {
            let text = String(decoding: try Data(contentsOf: persistedFile), as: UTF8.self)
            #expect(!text.contains("jay.song@example.com"))
            #expect(!text.contains("sk-ant-FAKE"))
            #expect(!text.contains("/Users/jay/private"))
            #expect(!text.contains("message-id-private"))
            #expect(!text.contains(file.path))
        }
        let cursorText = try String(contentsOf: directory.appendingPathComponent("log-cursors.json"),
                                    encoding: .utf8)
        #expect(!cursorText.contains(file.path))
        let cursorObject = try #require(JSONSerialization.jsonObject(with: Data(cursorText.utf8))
            as? [String: [String: Any]])
        let cursorKeys = try #require(cursorObject["cursors"]?.keys)
        #expect(cursorKeys.count == 1)
        #expect(cursorKeys.first?.count == 64)
        #expect(cursorKeys.first?.allSatisfy(\.isHexDigit) == true)
    }

    @Test("cursor resumes without rereading consumed lines and retains a partial tail")
    func cursorResumeAndPartialTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        let first = claudeLine(id: "first", input: 10)
        let partial = #"{"type":"assistant","timestamp":"\#(timestamp())","effort":"medium","version":"1.0","message":{"id":"partial","model":"claude-fable-5-1","usage":{"input_tokens":30"#
        try write(first + "\n" + partial, to: file, modifiedAt: now)
        let logReader = reader(root)
        let initial = logReader.read(roots: [logRoot], now: now)
        #expect(initial.records.map(\.inputTokens) == [10])

        let partialAgain = logReader.read(roots: [logRoot], now: now)
        #expect(partialAgain.records.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#","output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let resumed = logReader.read(roots: [logRoot], now: now)
        #expect(resumed.records.map(\.inputTokens) == [30])

        let noChanges = logReader.read(roots: [logRoot], now: now)
        #expect(noChanges.records.isEmpty)
        #expect(noChanges.bytesRead == 0)
    }

    @Test("inode replacement restarts its cursor at zero")
    func inodeRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "old", input: 1) + "\n", to: file, modifiedAt: now)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.first?.inputTokens == 1)

        let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement.jsonl")
        try write(claudeLine(id: "new", input: 9) + "\n", to: replacement, modifiedAt: now)
        #expect(rename(replacement.path, file.path) == 0)
        #expect(logReader.read(roots: [logRoot], now: now).records.first?.inputTokens == 9)
    }

    @Test("total read budget is eight MiB and files older than fourteen days are skipped")
    func boundsAndAgeFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        var oversized = Data()
        for _ in 0..<9 {
            oversized.append(Data(repeating: 120, count: SuggestionLogReader.maximumLineBytes + 1))
            oversized.append(10)
        }
        try oversized.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let bounded = reader(root).read(roots: [logRoot], now: now)
        #expect(bounded.bytesRead == SuggestionLogReader.maximumReadBytes)
        #expect(bounded.records.isEmpty)

        let oldRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: oldRoot) }
        let oldLogRoot = try claudeRoot(oldRoot)
        let oldFile = oldLogRoot.directory.appendingPathComponent("projects/project/old.jsonl")
        try write(claudeLine(id: "old", input: 5) + "\n", to: oldFile,
                  modifiedAt: now.addingTimeInterval(-15 * 24 * 60 * 60))
        let oldPass = reader(oldRoot).read(roots: [oldLogRoot], now: now)
        #expect(oldPass.bytesRead == 0)
        #expect(oldPass.records.isEmpty)
    }

    @Test("Codex token counts use the latest preceding turn context and skip earlier events")
    func codexAttributionAndFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try codexRoot(root, accountRef: "codex-profile")
        let file = logRoot.directory.appendingPathComponent("sessions/2027/01/rollout-one.jsonl")
        let fixture = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999}}}}
        {"type":"session_meta","payload":{"cli_version":"0.99"}}
        {"type":"turn_context","payload":{"collaboration_mode":{"settings":{"model":"gpt-5","reasoning_effort":"high"}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":25,"output_tokens":40,"reasoning_output_tokens":15}}},"response_item":{"text":"jay.song@example.com sk-ant-FAKE"},"cwd":"/Users/jay/private"}
        {"type":"turn_context","payload":{"model":"gpt-4.1","effort":"medium"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":8}}}}
        """
        try write(fixture + "\n", to: file, modifiedAt: now)
        let pass = reader(root).read(roots: [logRoot], now: now)
        #expect(pass.records.count == 2)
        let first = try #require(pass.records.first { $0.model == "gpt-5" })
        #expect(first.effort == "high")
        #expect(first.turns == 1)
        #expect(first.inputTokens == 200)
        #expect(first.cachedInputTokens == 25)
        #expect(first.reasoningTokens == 15)
        #expect(first.toolVersion == "0.99")
        let second = try #require(pass.records.first { $0.model == "gpt-4.1" })
        #expect(second.effort == "medium")
        #expect(second.inputTokens == 50)
        #expect(!pass.records.contains { $0.inputTokens == 999 })
    }

    @Test("Codex turn context is carried across incremental reads without storing a path")
    func codexContextResumesAcrossPasses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try codexRoot(root, accountRef: "codex-profile")
        let file = logRoot.directory.appendingPathComponent("sessions/2027/01/rollout-resume.jsonl")
        let prefix = """
        {"type":"session_meta","payload":{"cli_version":"1.0"}}
        {"type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}
        """
        try write(prefix + "\n", to: file, modifiedAt: now)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.isEmpty)

        let event = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":73,"output_tokens":9}}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let resumed = logReader.read(roots: [logRoot], now: now)
        let record = try #require(resumed.records.first)
        #expect(record.model == "gpt-5")
        #expect(record.effort == "high")
        #expect(record.toolVersion == "1.0")
        #expect(record.inputTokens == 73)
    }

    @Test("log files, cursor file, and suggestion directory have owner-only permissions")
    func permissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "mode", input: 12) + "\n", to: file, modifiedAt: now)
        let env = environment(root)
        let fs = SafeFS(env: env)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        try fs.createDirectory(directory)
        let firstPart = directory.appendingPathComponent(
            "log-usage-\(SuggestionRetention.utcDay(now)).jsonl")
        try Data(repeating: 120, count: 1_048_577).write(to: firstPart)
        _ = chmod(firstPart.path, 0o600)
        let pass = reader(root).read(roots: [logRoot], now: now)
        #expect(pass.records.count == 1)
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let cursorMode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("log-cursors.json").path)[.posixPermissions] as? NSNumber
        let logFile = directory.appendingPathComponent(
            "log-usage-\(SuggestionRetention.utcDay(now))-2.jsonl")
        let usageMode = try FileManager.default.attributesOfItem(atPath: logFile.path)[.posixPermissions] as? NSNumber
        #expect(dirMode?.intValue == 0o700)
        #expect(cursorMode?.intValue == 0o600)
        #expect(usageMode?.intValue == 0o600)
    }

    @Test("recent summary selects the most-used effort and unknown accounts have no hint")
    func recentSummary() {
        let account = "acct-0123456789abcdef"
        let day = SuggestionRetention.utcDay(now)
        let records = [
            SuggestionLogUsage(day: day, provider: .codex, accountRef: account, model: "openai/gpt-5",
                               effort: "high", turns: 2, inputTokens: 0, cachedInputTokens: 0,
                               outputTokens: 0, reasoningTokens: 0, toolVersion: nil),
            SuggestionLogUsage(day: day, provider: .codex, accountRef: account, model: "openai/gpt-5",
                               effort: "low", turns: 3, inputTokens: 0, cachedInputTokens: 0,
                               outputTokens: 0, reasoningTokens: 0, toolVersion: nil),
            SuggestionLogUsage(day: "2027-01-13", provider: .codex, accountRef: account,
                               model: "openai/old", effort: "max", turns: 100,
                               inputTokens: 0, cachedInputTokens: 0, outputTokens: 0,
                               reasoningTokens: 0, toolVersion: nil),
        ]
        let hints = SuggestionLogSummary.recent(records, now: now)
        #expect(hints[account] == SuggestionLogSummary.Hint(model: "openai/gpt-5", effort: "low"))
        #expect(SuggestionLogSummary.matchingHint(for: "acct-unknown", in: hints) == nil)
        #expect(SuggestionLogSummary.matchingHint(for: nil, in: hints) == nil)
        #expect(SuggestionLogSummary.recentEffort(for: "acct-unknown", in: hints) == nil)
    }
}
