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
        \(claudeLine(id: "message-id-next", input: 30))
        {malformed json
        """
        try write(fixture + "\n", to: file, modifiedAt: now)

        let logReader = reader(root)
        let pass = logReader.read(roots: [logRoot], now: now)
        #expect(pass.records.count == 1)
        let record = try #require(pass.records.first)
        #expect(record.turns == 1)
        #expect(record.inputTokens == 20)
        #expect(record.cachedInputTokens == 2)
        #expect(record.cachedCreationTokens == 3)
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
            #expect(!text.contains("message-id-next"))
            #expect(!text.contains(file.path))
        }
        let cursorText = try String(contentsOf: directory.appendingPathComponent("log-cursors.json"),
                                    encoding: .utf8)
        #expect(!cursorText.contains(file.path))
        let cursorObject = try #require(JSONSerialization.jsonObject(with: Data(cursorText.utf8))
            as? [String: Any])
        #expect(Set(cursorObject.keys) == ["cursors", "firstPassDay"])
        let cursorKeys = try #require((cursorObject["cursors"] as? [String: Any])?.keys)
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
        let first = claudeLine(id: "partial", input: 10)
        let partial = #"{"type":"assistant","timestamp":"\#(timestamp())","effort":"medium","version":"1.0","message":{"id":"partial","model":"claude-fable-5-1","usage":{"input_tokens":30"#
        try write(first + "\n" + partial, to: file, modifiedAt: now)
        let logReader = reader(root)
        let initial = logReader.read(roots: [logRoot], now: now)
        #expect(initial.records.isEmpty)

        let partialAgain = logReader.read(roots: [logRoot], now: now)
        #expect(partialAgain.records.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#","output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.write(contentsOf: Data((claudeLine(id: "end", input: 40) + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let resumed = logReader.read(roots: [logRoot], now: now)
        #expect(resumed.records.map(\.inputTokens) == [30])

        let noChanges = logReader.read(roots: [logRoot], now: now)
        #expect(noChanges.records.isEmpty)
        #expect(noChanges.bytesRead == 0)
    }

    @Test("flush resets log-reader state and the next read writes no pre-flush data")
    func flushResetsLogReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "pre-flush", input: 10) + "\n", to: file,
                  modifiedAt: now.addingTimeInterval(-11 * 60))

        let env = environment(root)
        let fs = SafeFS(env: env)
        let logReader = SuggestionLogReader(env: env, fs: fs, catalog: nil)
        #expect(logReader.read(roots: [logRoot], now: now).records.first?.inputTokens == 10)
        let oldAccountKey = try #require(logReader.accountRefKey(for: "person@example.com"))
        let store = SuggestionStateStore(env: env, fs: fs)
        try store.flush()

        logReader.reset()
        let newAccountKey = try #require(logReader.accountRefKey(for: "person@example.com"))
        #expect(newAccountKey != oldAccountKey)
        #expect(logReader.read(roots: [], now: now).records.isEmpty)
        #expect(logReader.recentRecords(now: now).isEmpty)

        let cursorFile = env.storeDir.appendingPathComponent("suggestion/log-cursors.json")
        let cursorData = try Data(contentsOf: cursorFile)
        let cursorState = try #require(JSONSerialization.jsonObject(with: cursorData)
            as? [String: Any])
        #expect((cursorState["cursors"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Claude messages spanning passes retain only the final usage")
    func claudeMessageAcrossPasses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "message-id-split", input: 10) + "\n",
                  to: file, modifiedAt: now)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.isEmpty)

        let append = claudeLine(id: "message-id-split", input: 20) + "\n"
            + claudeLine(id: "message-id-next", input: 30) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(append.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let pass = logReader.read(roots: [logRoot], now: now)
        #expect(pass.records.count == 1)
        #expect(pass.records.first?.turns == 1)
        #expect(pass.records.first?.inputTokens == 20)

        let cursor = try String(contentsOf: environment(root).storeDir
            .appendingPathComponent("suggestion/log-cursors.json"), encoding: .utf8)
        #expect(!cursor.contains("message-id-split"))
        #expect(!cursor.contains("message-id-next"))
    }

    @Test("idle Claude messages are finalized after ten minutes")
    func claudeIdleMessageFinalizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "idle-message", input: 42) + "\n", to: file,
                  modifiedAt: now.addingTimeInterval(-11 * 60))

        let pass = reader(root).read(roots: [logRoot], now: now)
        #expect(pass.records.count == 1)
        #expect(pass.records.first?.turns == 1)
        #expect(pass.records.first?.inputTokens == 42)
    }

    @Test("inode replacement restarts its cursor at zero")
    func inodeRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "old", input: 1) + "\n"
                  + claudeLine(id: "old-next", input: 2) + "\n",
                  to: file, modifiedAt: now)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.first?.inputTokens == 1)

        let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement.jsonl")
        try write(claudeLine(id: "new", input: 9) + "\n"
                  + claudeLine(id: "new-next", input: 10) + "\n",
                  to: replacement, modifiedAt: now)
        #expect(rename(replacement.path, file.path) == 0)
        #expect(logReader.read(roots: [logRoot], now: now).records.first?.inputTokens == 9)
    }

    // MARK: - Cursors, order and completeness (audit A-08)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func cursorFile(_ root: URL) -> URL {
        environment(root).storeDir.appendingPathComponent("suggestion/log-cursors.json")
    }

    private func suggestionFiles(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: environment(root).storeDir.appendingPathComponent("suggestion").path)) ?? []).sorted()
    }

    private func usageLogBytes(_ root: URL) -> Int {
        let directory = environment(root).storeDir.appendingPathComponent("suggestion")
        return suggestionFiles(root).filter { $0.hasPrefix("log-usage-") }.reduce(0) { total, name in
            total + (((try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path))?[.size] as? Int) ?? 0)
        }
    }

    /// One finished Claude turn in its own session file (old enough to be finalized at once).
    private func finishedSession(_ logRoot: SuggestionLogRoot, name: String, id: String, input: Int,
                                 modifiedAt: Date? = nil) throws {
        try write(claudeLine(id: id, input: input) + "\n",
                  to: logRoot.directory.appendingPathComponent("projects/project/\(name).jsonl"),
                  modifiedAt: modifiedAt ?? now.addingTimeInterval(-11 * 60))
    }

    @Test func cursorsOfFilesNotSeenForFortyFiveDaysArePruned() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "old", id: "old", input: 10, modifiedAt: now.addingTimeInterval(-3600))
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.count == 1)
        func cursorCount() throws -> Int {
            let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cursorFile(root))) as? [String: Any])
            return (state["cursors"] as? [String: Any])?.count ?? -1
        }
        #expect(try cursorCount() == 1)
        // 44 days later the file is too old to be read again but its cursor is still remembered.
        _ = logReader.read(roots: [logRoot], now: now.addingTimeInterval(44 * 86_400))
        #expect(try cursorCount() == 1)
        _ = logReader.read(roots: [logRoot], now: now.addingTimeInterval(46 * 86_400))
        #expect(try cursorCount() == 0)
    }

    @Test func anUnreadableCursorFileSkipsThePassAndRebuildsWithoutDoubleCounting() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "one", id: "one", input: 10)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.map(\.inputTokens) == [10])
        try Data("{broken".utf8).write(to: cursorFile(root))

        let skipped = logReader.read(roots: [logRoot], now: now)
        #expect(skipped.records.isEmpty && skipped.bytesRead == 0)
        #expect(suggestionFiles(root).contains { $0.hasPrefix("log-cursors.json.unreadable-") })
        #expect(!suggestionFiles(root).contains("log-cursors.json"))
        #expect(usageLogBytes(root) == 0)
        #expect(logReader.recentRecords(now: now).isEmpty)

        let rebuilt = logReader.read(roots: [logRoot], now: now)
        #expect(rebuilt.records.map(\.inputTokens) == [10])
        #expect(logReader.recentRecords(now: now).map(\.inputTokens) == [10]) // counted once
    }

    @Test func anUnfinishedLastLineIsNotABacklog() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/crashed.jsonl")
        try write(claudeLine(id: "done", input: 10) + "\n" + #"{"type":"assistant","mess"#, to: file,
                  modifiedAt: now.addingTimeInterval(-11 * 60))
        let logReader = reader(root)
        for _ in 0..<2 {
            let pass = logReader.read(roots: [logRoot], now: now)
            #expect(pass.pendingBytes == 0)
            #expect(pass.pendingAccounts.isEmpty)
        }
    }

    @Test func aCursorPathThatIsNotAFileIsSetAsideOnce() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "one", id: "one", input: 10)
        try FileManager.default.createDirectory(at: cursorFile(root), withIntermediateDirectories: true)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.isEmpty)
        #expect(logReader.read(roots: [logRoot], now: now).records.map(\.inputTokens) == [10])
    }

    @Test func aMissingCursorFileIsAFreshStart() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "one", id: "one", input: 10)
        let pass = reader(root).read(roots: [logRoot], now: now)
        #expect(pass.records.map(\.inputTokens) == [10])
        #expect(!suggestionFiles(root).contains { $0.contains("unreadable") })
        #expect(pass.firstPassDay == SuggestionRetention.utcDay(now))
        // The first-pass day is remembered, not moved by later passes.
        let later = reader(root).read(roots: [logRoot], now: now.addingTimeInterval(3 * 86_400))
        #expect(later.firstPassDay == SuggestionRetention.utcDay(now))
    }

    @Test func aFailedCursorSaveRollsTheAppendedRecordsBack() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "one", id: "one", input: 10)
        let logReader = reader(root)
        #expect(logReader.read(roots: [logRoot], now: now).records.count == 1)
        let before = usageLogBytes(root)
        #expect(before > 0)

        try finishedSession(logRoot, name: "two", id: "two", input: 20)
        logReader.cursorSaveFault = { throw SwitcherError.io("injected") }
        let failed = logReader.read(roots: [logRoot], now: now)
        #expect(failed.records.isEmpty)
        #expect(usageLogBytes(root) == before)

        logReader.cursorSaveFault = nil
        #expect(logReader.read(roots: [logRoot], now: now).records.map(\.inputTokens) == [20])
        #expect(logReader.recentRecords(now: now).map(\.inputTokens).sorted() == [10, 20])
    }

    @Test func filesOfPriorityAccountsAreReadFirst() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let claude = try claudeRoot(root)
        for index in 0..<8 {
            try finishedSession(claude, name: "a-session-\(index)", id: "claude-\(index)", input: 10 + index, modifiedAt: now)
        }
        let codex = try codexRoot(root, accountRef: "api-key-home")
        let rollout = """
        {"type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"output_tokens":40}}}}
        """
        try write(rollout + "\n", to: codex.directory.appendingPathComponent("sessions/2027/01/rollout-one.jsonl"),
                  modifiedAt: now.addingTimeInterval(-3600))
        let env = environment(root)
        // A budget that fits the Codex file but not much else.
        let small = SuggestionLogReader(env: env, fs: SafeFS(env: env), catalog: nil, readBudget: 512)
        let pass = small.read(roots: [claude, codex], now: now, priorityAccountRefs: ["api-key-home"])
        #expect(pass.records.contains { $0.provider == .codex && $0.inputTokens == 200 })
        #expect(pass.pendingBytes > 0)
        let codexKey = try #require(small.accountRefKey(for: "api-key-home"))
        let claudeKey = try #require(small.accountRefKey(for: "cli"))
        #expect(!pass.pendingAccounts.contains(APIKeyAccountKey(provider: .codex, accountKey: codexKey)))
        #expect(pass.pendingAccounts.contains(APIKeyAccountKey(provider: .claude, accountKey: claudeKey)))
    }

    @Test func newerFilesAreReadBeforeOlderOnes() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "a-older", id: "older", input: 11, modifiedAt: now.addingTimeInterval(-2 * 86_400))
        try finishedSession(logRoot, name: "z-newer", id: "newer", input: 22, modifiedAt: now.addingTimeInterval(-3600))
        let lineBytes = (claudeLine(id: "newer", input: 22) + "\n").utf8.count
        let env = environment(root)
        let small = SuggestionLogReader(env: env, fs: SafeFS(env: env), catalog: nil, readBudget: lineBytes)
        #expect(small.read(roots: [logRoot], now: now).records.map(\.inputTokens) == [22])
        #expect(small.read(roots: [logRoot], now: now).records.map(\.inputTokens) == [11])
    }

    @Test func aPassReportsWhatIsStillUnread() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        try finishedSession(logRoot, name: "one", id: "one", input: 10)
        try finishedSession(logRoot, name: "two", id: "two", input: 20)
        let lineBytes = (claudeLine(id: "one", input: 10) + "\n").utf8.count
        let env = environment(root)
        let small = SuggestionLogReader(env: env, fs: SafeFS(env: env), catalog: nil, readBudget: lineBytes)
        let first = small.read(roots: [logRoot], now: now)
        #expect(first.bytesRead == lineBytes)
        #expect(first.pendingBytes == lineBytes)
        let second = small.read(roots: [logRoot], now: now)
        #expect(second.pendingBytes == 0)
        #expect(second.pendingAccounts.isEmpty)
    }

    @Test("total read budget is 32 MiB and files older than fourteen days are skipped")
    func boundsAndAgeFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        // Only the size matters here: a sparse file of zeros is one over-long line.
        #expect(SuggestionLogReader.maximumReadBytes == 32 * 1_048_576)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SuggestionLogReader.maximumReadBytes) + 1_048_576)
        try handle.close()
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
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999}}}}
        {"type":"session_meta","payload":{"cli_version":"0.99"}}
        {"type":"turn_context","payload":{"collaboration_mode":{"settings":{"model":"gpt-5","reasoning_effort":"high"}}}}
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":25,"output_tokens":40,"reasoning_output_tokens":15}}},"response_item":{"text":"jay.song@example.com sk-ant-FAKE"},"cwd":"/Users/jay/private"}
        {"type":"turn_context","payload":{"model":"gpt-4.1","effort":"medium"}}
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":8}}}}
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

    @Test("Codex sessions with a ChatGPT plan are marked subscription and stay separate from unmarked ones")
    func codexSubscriptionMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try codexRoot(root, accountRef: "codex-profile")
        let plan = logRoot.directory.appendingPathComponent("sessions/2027/01/rollout-plan.jsonl")
        let apiKey = logRoot.directory.appendingPathComponent("sessions/2027/01/rollout-api.jsonl")
        let context = #"{"type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}"#
        let planFixture = """
        \(context)
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10}},"rate_limits":null}}
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":3.5}}}}
        """
        let apiFixture = """
        \(context)
        {"type":"event_msg","timestamp":"\(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40}},"rate_limits":null}}
        """
        try write(planFixture + "\n", to: plan, modifiedAt: now)
        try write(apiFixture + "\n", to: apiKey, modifiedAt: now)
        let logReader = reader(root)
        let pass = logReader.read(roots: [logRoot], now: now)
        #expect(pass.records.count == 2)
        let marked = try #require(pass.records.first { $0.subscription == true })
        #expect(marked.inputTokens == 30)
        #expect(marked.turns == 2)
        let unmarked = try #require(pass.records.first { $0.subscription == nil })
        #expect(unmarked.inputTokens == 40)

        let later = #"{"type":"event_msg","timestamp":"\#(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5}},"rate_limits":null}}"#
        try write(planFixture + "\n" + later + "\n", to: plan, modifiedAt: now)
        let second = logReader.read(roots: [logRoot], now: now)
        let resumed = try #require(second.records.first { $0.inputTokens == 5 })
        #expect(resumed.subscription == true)
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

        let event = #"{"type":"event_msg","timestamp":"\#(timestamp())","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":73,"output_tokens":9}}}}"#
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

    @Test("Codex event timestamps set each usage day and exclude old or missing timestamps")
    func codexEventDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try codexRoot(root)
        let file = logRoot.directory.appendingPathComponent("sessions/2027/01/rollout-dates.jsonl")
        let old = timestamp(now.addingTimeInterval(-20 * 24 * 60 * 60))
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let fixture = """
        {"type":"turn_context","payload":{"model":"gpt-5","effort":"high"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999}}}}
        {"type":"event_msg","timestamp":"\(old)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":888}}}}
        {"type":"event_msg","timestamp":"\(timestamp(recent))","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":73}}}}
        """
        try write(fixture + "\n", to: file, modifiedAt: now)
        let pass = reader(root).read(roots: [logRoot], now: now)
        let record = try #require(pass.records.first)
        #expect(pass.records.count == 1)
        #expect(record.day == SuggestionRetention.utcDay(recent))
        #expect(record.inputTokens == 73)
    }

    @Test("log files, cursor file, and suggestion directory have owner-only permissions")
    func permissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logRoot = try claudeRoot(root)
        let file = logRoot.directory.appendingPathComponent("projects/project/session.jsonl")
        try write(claudeLine(id: "mode", input: 12) + "\n"
                  + claudeLine(id: "mode-next", input: 13) + "\n",
                  to: file, modifiedAt: now)
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

    @Test("recent summary totals effort across models and unknown accounts have no hint")
    func recentSummary() {
        let account = "acct-0123456789abcdef"
        let day = SuggestionRetention.utcDay(now)
        let records = [
            SuggestionLogUsage(day: day, provider: .codex, accountRef: account, model: "openai/gpt-5",
                               effort: "high", turns: 3, inputTokens: 0, cachedInputTokens: 0,
                               outputTokens: 0, reasoningTokens: 0, toolVersion: nil),
            SuggestionLogUsage(day: day, provider: .codex, accountRef: account, model: "openai/gpt-5",
                               effort: "medium", turns: 4, inputTokens: 0, cachedInputTokens: 0,
                               outputTokens: 0, reasoningTokens: 0, toolVersion: nil),
            SuggestionLogUsage(day: day, provider: .codex, accountRef: account, model: "openai/gpt-4",
                               effort: "high", turns: 3, inputTokens: 0, cachedInputTokens: 0,
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
        #expect(hints[account] == SuggestionLogSummary.Hint(model: "openai/gpt-4", effort: "high"))
        #expect(SuggestionLogSummary.matchingHint(for: "acct-unknown", in: hints) == nil)
        #expect(SuggestionLogSummary.matchingHint(for: nil, in: hints) == nil)
        #expect(SuggestionLogSummary.recentEffort(for: "acct-unknown", in: hints) == nil)
    }
}
