import CryptoKit
import Darwin
import Foundation

public struct SuggestionLogRoot: Equatable, Sendable {
    public let provider: UsageProvider
    public let accountRef: String
    public let directory: URL

    public init(provider: UsageProvider, accountRef: String, directory: URL) {
        self.provider = provider
        self.accountRef = accountRef
        self.directory = directory
    }
}

public struct SuggestionLogUsage: Codable, Equatable, Sendable {
    public let day: String
    public let provider: UsageProvider
    public let accountRef: String
    public let model: String
    public let effort: String?
    public let turns: Int
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cachedCreationTokens: Int64?
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let toolVersion: String?
    public let lastUsedAt: Date?
    /// True when the session log itself shows a subscription sign-in (a Codex `plan_type`);
    /// nil when the log carries no sign-in marker.
    public let subscription: Bool?

    public init(day: String, provider: UsageProvider, accountRef: String, model: String,
                effort: String?, turns: Int, inputTokens: Int64, cachedInputTokens: Int64,
                cachedCreationTokens: Int64 = 0,
                outputTokens: Int64, reasoningTokens: Int64, toolVersion: String?,
                lastUsedAt: Date? = nil, subscription: Bool? = nil) {
        self.day = day
        self.provider = provider
        self.accountRef = accountRef
        self.model = model
        self.effort = effort
        self.turns = turns
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cachedCreationTokens = cachedCreationTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.toolVersion = toolVersion
        self.lastUsedAt = lastUsedAt
        self.subscription = subscription
    }
}

public struct SuggestionLogSummary: Sendable {
    public struct Hint: Equatable, Sendable {
        public let model: String
        public let effort: String?
    }

    public static func matchingHint(for accountRef: String?,
                                    in hints: [String: Hint]) -> Hint? {
        guard let accountRef, !accountRef.isEmpty else { return nil }
        return hints[accountRef]
    }

    public static func recentEffort(for accountRef: String?,
                                    in hints: [String: Hint]) -> String? {
        matchingHint(for: accountRef, in: hints)?.effort
    }

    private struct UsageKey: Hashable {
        let accountRef: String
        let model: String
        let effort: String?
    }

    private struct EffortKey: Hashable {
        let accountRef: String
        let effort: String?
    }

    public static func recent(_ records: [SuggestionLogUsage], now: Date) -> [String: Hint] {
        let today = SuggestionRetention.utcDay(now)
        let firstDay = SuggestionRetention.utcDay(now.addingTimeInterval(-24 * 60 * 60))
        var effortCounts: [EffortKey: Int] = [:]
        var modelCounts: [UsageKey: Int] = [:]
        for record in records where record.turns > 0
            && record.day >= firstDay && record.day <= today
            && !record.accountRef.isEmpty && !record.model.isEmpty {
            let effortKey = EffortKey(accountRef: record.accountRef, effort: record.effort)
            let modelKey = UsageKey(accountRef: record.accountRef, model: record.model, effort: record.effort)
            effortCounts[effortKey] = saturatingAdd(effortCounts[effortKey, default: 0], record.turns)
            modelCounts[modelKey] = saturatingAdd(modelCounts[modelKey, default: 0], record.turns)
        }

        var bestEffort: [String: (effort: String?, turns: Int)] = [:]
        for (key, turns) in effortCounts {
            guard let current = bestEffort[key.accountRef] else {
                bestEffort[key.accountRef] = (key.effort, turns)
                continue
            }
            if turns > current.turns
                || (turns == current.turns && (key.effort ?? "") < (current.effort ?? "")) {
                bestEffort[key.accountRef] = (key.effort, turns)
            }
        }

        var bestModel: [String: (key: UsageKey, turns: Int)] = [:]
        for (key, turns) in modelCounts where bestEffort[key.accountRef]?.effort == key.effort {
            guard let current = bestModel[key.accountRef] else {
                bestModel[key.accountRef] = (key, turns)
                continue
            }
            if turns > current.turns || (turns == current.turns && key.model < current.key.model) {
                bestModel[key.accountRef] = (key, turns)
            }
        }
        return bestModel.mapValues { Hint(model: $0.key.model, effort: $0.key.effort) }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

public struct SuggestionLogPass: Equatable, Sendable {
    public let records: [SuggestionLogUsage]
    public let bytesRead: Int
    /// Bytes of eligible log files this pass left unread (the read budget ran out).
    public let pendingBytes: Int
    /// The accounts whose logs still have unread bytes.
    public let pendingAccounts: Set<APIKeyAccountKey>
    /// The UTC day this reader first read logs into the current store, when known.
    public let firstPassDay: String?
    /// The pass could not complete: stored spend is partial and the estimator must not call it final.
    public let failed: Bool

    public init(records: [SuggestionLogUsage], bytesRead: Int, pendingBytes: Int = 0,
                pendingAccounts: Set<APIKeyAccountKey> = [], firstPassDay: String? = nil,
                failed: Bool = false) {
        self.failed = failed
        self.records = records
        self.bytesRead = bytesRead
        self.pendingBytes = pendingBytes
        self.pendingAccounts = pendingAccounts
        self.firstPassDay = firstPassDay
    }

    /// The first day the stored usage is complete from. The first pass reads whole every log file
    /// changed in the 14 days before it, so everything from 13 days before that pass is covered.
    public static func coverageStartDay(firstPassDay: String?) -> String? {
        guard let firstPassDay, let date = SuggestionRetention.date(utcDay: firstPassDay) else { return nil }
        return SuggestionRetention.utcDay(date.addingTimeInterval(-13 * 86_400))
    }
}

public final class SuggestionLogReader: @unchecked Sendable {
    public static let maximumLineBytes = 1_048_576
    public static let maximumReadBytes = 32 * 1_048_576
    public static let maximumFileAge: TimeInterval = 14 * 24 * 60 * 60
    /// A cursor is dropped this long after its file was last eligible. Longer than the 35 days
    /// the spend estimate looks back, so a file read again later cannot be counted twice inside it.
    static let cursorRetention: TimeInterval = 45 * 24 * 60 * 60
    static let maximumCursorFileBytes = 4 * 1_048_576
    private static let pendingMessageIdleTime: TimeInterval = 10 * 60

    private struct PendingClaudeMessage: Codable {
        let idHash: String
        let model: String
        let effort: String?
        let toolVersion: String?
        let timestamp: Date
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadInputTokens: Int64
        let cacheCreationInputTokens: Int64
    }

    private struct Cursor: Codable {
        var inode: UInt64
        var offset: UInt64
        var discardingLongLine = false
        var codexModel: String?
        var codexEffort: String?
        var codexToolVersion: String?
        var codexSubscription: Bool?
        var claudePending: PendingClaudeMessage?
        /// When the file was last among the eligible files of a pass.
        var lastSeenAt: Date?
    }

    private struct FileCursorState: Codable {
        var cursors: [String: Cursor]
        var firstPassDay: String?
    }

    private enum CursorLoad {
        case missing
        case loaded(FileCursorState)
        /// Present but too large or not decodable.
        case unreadable
        /// The read stalled; nothing is known about the file.
        case stalled
    }

    private struct Unread {
        var bytes: UInt64
        let account: APIKeyAccountKey
    }

    private struct LogFile {
        let url: URL
        let root: SuggestionLogRoot
        let modifiedAt: Date
    }

    private struct FileInfo {
        let inode: UInt64
        let size: UInt64
        let modifiedAt: Date
    }

    private struct UsageKey: Hashable {
        let day: String
        let provider: UsageProvider
        let accountRef: String
        let model: String
        let effort: String?
        let toolVersion: String?
        let subscription: Bool?
    }

    private struct Totals {
        var turns = 0
        var inputTokens: Int64 = 0
        var cachedInputTokens: Int64 = 0
        var cachedCreationTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var reasoningTokens: Int64 = 0
        var lastUsedAt: Date?

        mutating func add(_ usage: ParsedUsage) {
            turns += 1
            inputTokens = Self.add(inputTokens, usage.inputTokens)
            cachedInputTokens = Self.add(cachedInputTokens, usage.cachedInputTokens)
            cachedCreationTokens = Self.add(cachedCreationTokens, usage.cachedCreationTokens)
            outputTokens = Self.add(outputTokens, usage.outputTokens)
            reasoningTokens = Self.add(reasoningTokens, usage.reasoningTokens)
            lastUsedAt = max(lastUsedAt ?? usage.occurredAt, usage.occurredAt)
        }

        private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }
    }

    private struct ParsedUsage {
        let day: String
        let occurredAt: Date
        let provider: UsageProvider
        let accountRef: String
        let model: String
        let effort: String?
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let cachedCreationTokens: Int64
        let outputTokens: Int64
        let reasoningTokens: Int64
        let toolVersion: String?
        var subscription: Bool? = nil
    }

    private struct ClaudeLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int64?
                let output_tokens: Int64?
                let cache_read_input_tokens: Int64?
                let cache_creation_input_tokens: Int64?
            }

            let id: String?
            let model: String?
            let usage: Usage?
        }

        let type: String?
        let timestamp: String?
        let effort: String?
        let perTurnEffort: String?
        let version: String?
        let message: Message?
    }

    private struct CodexLine: Decodable {
        struct Payload: Decodable {
            struct CollaborationMode: Decodable {
                struct Settings: Decodable {
                    let model: String?
                    let reasoning_effort: String?
                }
                let settings: Settings?
            }

            struct Info: Decodable {
                struct TokenUsage: Decodable {
                    let input_tokens: Int64?
                    let cached_input_tokens: Int64?
                    let output_tokens: Int64?
                    let reasoning_output_tokens: Int64?
                }
                let last_token_usage: TokenUsage?
            }

            struct RateLimits: Decodable {
                let plan_type: String?
            }

            let type: String?
            let model: String?
            let effort: String?
            let collaboration_mode: CollaborationMode?
            let info: Info?
            let cli_version: String?
            let rate_limits: RateLimits?
        }

        let type: String?
        let timestamp: String?
        let payload: Payload?
    }

    private let directory: URL
    private let cursorFile: URL
    private let fs: SafeFS
    private let boundedReader: BoundedReader
    private let accountReferences: SuggestionAccountReference
    private let usageStore: SuggestionLogUsageStore
    private let catalog: SuggestionCatalog?
    private let readBudget: Int
    private let lock = NSLock()
    /// Test seam: runs before the cursor file is written, so a test can make that write fail.
    var cursorSaveFault: (@Sendable () throws -> Void)?

    public init(env: SwitcherEnvironment, fs: SafeFS, catalog: SuggestionCatalog?,
                reader: BoundedReader = .shared, readBudget: Int = SuggestionLogReader.maximumReadBytes) {
        self.readBudget = readBudget
        directory = env.storeDir.appendingPathComponent("suggestion", isDirectory: true)
        cursorFile = directory.appendingPathComponent("log-cursors.json")
        self.fs = fs
        boundedReader = reader
        accountReferences = SuggestionAccountReference(env: env, fs: fs)
        usageStore = SuggestionLogUsageStore(directory: directory, fs: fs, reader: reader)
        self.catalog = catalog
    }

    public func accountRefKey(for rawAccountRef: String) -> String? {
        accountReferences.key(for: rawAccountRef)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        accountReferences.reset()
    }

    /// - Parameter priorityAccountRefs: root account refs whose files are read before the others
    ///   (the accounts a spend estimate depends on).
    public func read(roots: [SuggestionLogRoot], now: Date = Date(),
                     priorityAccountRefs: Set<String> = []) -> SuggestionLogPass {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled else { return SuggestionLogPass(records: [], bytesRead: 0, failed: true) }
        do { try fs.createDirectory(directory) } catch {
            return SuggestionLogPass(records: [], bytesRead: 0, failed: true)
        }
        SuggestionRetention.prune(directory: directory, fs: fs, now: now, reader: boundedReader)
        var state: FileCursorState
        switch loadCursors() {
        case .missing: state = FileCursorState(cursors: [:], firstPassDay: SuggestionRetention.utcDay(now))
        case .loaded(let loaded): state = loaded
        case .stalled: return SuggestionLogPass(records: [], bytesRead: 0, failed: true)
        case .unreadable:
            // Offsets are lost, so what was already counted is unknown: set the cursor file aside,
            // drop the stored usage and let the next pass count everything once from the start.
            // If the file cannot be set aside nothing is removed: the pass is skipped and tried again.
            guard (try? fs.move(cursorFile, to: directory.appendingPathComponent(
                "log-cursors.json.unreadable-\(Int(now.timeIntervalSince1970))"))) != nil
            else { return SuggestionLogPass(records: [], bytesRead: 0, failed: true) }
            usageStore.removeAll()
            return SuggestionLogPass(records: [], bytesRead: 0, failed: true)
        }
        var cursors = state.cursors
        let files = eligibleFiles(roots: roots, now: now, priorityAccountRefs: priorityAccountRefs)
        var remaining = readBudget
        var totalRead = 0
        var totals: [UsageKey: Totals] = [:]
        var unread: [String: Unread] = [:]

        for file in files {
            guard !Task.isCancelled,
                  let pathKey = Self.pathKey(file.url.path),
                  let accountRef = accountReferences.key(for: file.root.accountRef),
                  let info = Self.fileInfo(file.url) else { continue }
            var cursor = cursors[pathKey] ?? Cursor(inode: info.inode, offset: 0)
            if cursor.inode != info.inode || info.size < cursor.offset {
                cursor = Cursor(inode: info.inode, offset: 0)
            }
            cursor.lastSeenAt = now
            let unreadKey = "\(pathKey)\u{0}\(accountRef)"
            unread[unreadKey] = Unread(bytes: info.size - cursor.offset,
                account: APIKeyAccountKey(provider: file.root.provider, accountKey: accountRef))
            guard cursor.offset < info.size else {
                if file.root.provider == .claude,
                   now.timeIntervalSince(info.modifiedAt) > Self.pendingMessageIdleTime,
                   let pending = cursor.claudePending {
                    accumulate(claudeUsage(from: pending, accountRef: accountRef), into: &totals)
                    cursor.claudePending = nil
                }
                cursors[pathKey] = cursor
                continue
            }

            guard remaining > 0 else {
                cursors[pathKey] = cursor
                continue
            }
            let requested = Int(min(info.size - cursor.offset, UInt64(remaining)))
            guard requested > 0, let data = Self.read(file.url, offset: cursor.offset, count: requested) else {
                cursors[pathKey] = cursor
                continue
            }
            totalRead += data.count
            remaining -= data.count
            let parsed: [ParsedUsage]
            let nextCursor: Cursor
            switch file.root.provider {
            case .claude:
                (nextCursor, parsed) = processClaude(
                    data, cursor: cursor, accountRef: accountRef,
                    finalizePending: now.timeIntervalSince(info.modifiedAt) > Self.pendingMessageIdleTime)
            case .codex:
                (nextCursor, parsed) = processCodex(
                    data, cursor: cursor, accountRef: accountRef,
                    now: now)
            // Cursor, Devin, Gemini, Antigravity and OpenCode have no readers because their formats are unverified.
            default:
                continue
            }
            cursors[pathKey] = nextCursor
            // Read to the end: whatever is left is an unfinished last line, not a backlog.
            let reachedEnd = UInt64(data.count) == info.size - cursor.offset
            unread[unreadKey]?.bytes = reachedEnd || info.size <= nextCursor.offset ? 0 : info.size - nextCursor.offset
            for parsedUsage in parsed {
                accumulate(parsedUsage, into: &totals)
            }
        }

        let records = totals.map { key, value in
            SuggestionLogUsage(day: key.day, provider: key.provider, accountRef: key.accountRef,
                               model: key.model, effort: key.effort, turns: value.turns,
                               inputTokens: value.inputTokens, cachedInputTokens: value.cachedInputTokens,
                               cachedCreationTokens: value.cachedCreationTokens,
                               outputTokens: value.outputTokens, reasoningTokens: value.reasoningTokens,
                               toolVersion: key.toolVersion, lastUsedAt: value.lastUsedAt,
                               subscription: key.subscription)
        }.sorted {
            ($0.day, $0.provider.rawValue, $0.accountRef, $0.model, $0.effort ?? "", $0.toolVersion ?? "")
                < ($1.day, $1.provider.rawValue, $1.accountRef, $1.model, $1.effort ?? "", $1.toolVersion ?? "")
        }

        guard !Task.isCancelled else { return SuggestionLogPass(records: [], bytesRead: totalRead, failed: true) }
        // Records and cursors go together: if either write fails, neither is kept and the next pass
        // reads the same bytes again.
        guard let appended = usageStore.append(records) else {
            return SuggestionLogPass(records: [], bytesRead: 0, firstPassDay: state.firstPassDay, failed: true)
        }
        // Old cursor files have no `lastSeenAt`; their clock starts now.
        state.cursors = cursors.compactMapValues { cursor in
            var kept = cursor
            if kept.lastSeenAt == nil { kept.lastSeenAt = now }
            return now.timeIntervalSince(kept.lastSeenAt ?? now) > Self.cursorRetention ? nil : kept
        }
        do { try saveCursors(state) } catch {
            SuggestionStorage.rollBack(appended, fs: fs)
            return SuggestionLogPass(records: [], bytesRead: 0, firstPassDay: state.firstPassDay, failed: true)
        }
        let pending = unread.values.filter { $0.bytes > 0 }
        return SuggestionLogPass(
            records: records, bytesRead: totalRead,
            pendingBytes: Int(clamping: pending.reduce(UInt64(0)) { $0 &+ $1.bytes }),
            pendingAccounts: Set(pending.map(\.account)), firstPassDay: state.firstPassDay)
    }

    public func recentSummary(now: Date = Date()) -> [String: SuggestionLogSummary.Hint] {
        SuggestionLogSummary.recent(usageStore.recentRecords(now: now), now: now)
    }

    public func recentRecords(now: Date = Date(), days: Int = 2) -> [SuggestionLogUsage] {
        usageStore.recentRecords(now: now, days: days)
    }

    private func loadCursors() -> CursorLoad {
        var attributes = stat()
        guard lstat(cursorFile.path, &attributes) == 0 else { return errno == ENOENT ? .missing : .stalled }
        // Only what is certain counts as unreadable: not a regular file, too large, or not decodable.
        // A read that merely failed this time is retried on the next pass.
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= off_t(Self.maximumCursorFileBytes)
        else { return .unreadable }
        switch boundedReader.read(atPath: cursorFile.path, using: { path in
            BoundedReader.readBounded(path, limit: Self.maximumCursorFileBytes + 1, allowBinary: true)
        }) {
        case .timedOut, .unreadable: return .stalled
        case .data(let data):
            guard let state = try? JSONDecoder().decode(FileCursorState.self, from: data) else { return .unreadable }
            return .loaded(state)
        }
    }

    private func saveCursors(_ state: FileCursorState) throws {
        try cursorSaveFault?()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.write(try encoder.encode(state), to: cursorFile)
    }

    private func eligibleFiles(roots: [SuggestionLogRoot], now: Date,
                               priorityAccountRefs: Set<String>) -> [LogFile] {
        var files: [LogFile] = []
        var seen = Set<String>()
        for root in roots where root.provider == .claude || root.provider == .codex {
            switch root.provider {
            case .claude:
                let projects = root.directory.appendingPathComponent("projects", isDirectory: true)
                guard Self.isDirectory(projects) else { continue }
                let projectDirectories = (try? FileManager.default.contentsOfDirectory(
                    at: projects, includingPropertiesForKeys: nil)) ?? []
                for project in projectDirectories where Self.isDirectory(project) {
                    let candidates = (try? FileManager.default.contentsOfDirectory(
                        at: project, includingPropertiesForKeys: nil)) ?? []
                    for candidate in candidates where candidate.lastPathComponent.hasSuffix(".jsonl") {
                        add(candidate, root: root, now: now, seen: &seen, into: &files)
                    }
                }
            case .codex:
                let sessions = root.directory.appendingPathComponent("sessions", isDirectory: true)
                guard Self.isDirectory(sessions),
                      let enumerator = FileManager.default.enumerator(
                        at: sessions, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]) else { continue }
                for case let candidate as URL in enumerator {
                    var attributes = stat()
                    if lstat(candidate.path, &attributes) == 0,
                       (attributes.st_mode & S_IFMT) == S_IFLNK {
                        enumerator.skipDescendants()
                        continue
                    }
                    let name = candidate.lastPathComponent
                    guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                    add(candidate, root: root, now: now, seen: &seen, into: &files)
                }
            default:
                continue
            }
        }
        // Accounts a spend estimate depends on first, then newest first, so a backlog is worked
        // off where it matters most.
        return files.sorted { lhs, rhs in
            let lhsPriority = priorityAccountRefs.contains(lhs.root.accountRef)
            let rhsPriority = priorityAccountRefs.contains(rhs.root.accountRef)
            if lhsPriority != rhsPriority { return lhsPriority }
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.path == rhs.url.path
                ? lhs.root.accountRef < rhs.root.accountRef
                : lhs.url.path < rhs.url.path
        }
    }

    private func add(_ url: URL, root: SuggestionLogRoot, now: Date,
                     seen: inout Set<String>, into files: inout [LogFile]) {
        guard let info = Self.fileInfo(url) else { return }
        let age = now.timeIntervalSince(info.modifiedAt)
        guard age >= 0, age <= Self.maximumFileAge else { return }
        let unique = "\(url.path)\u{0}\(root.provider.rawValue)\u{0}\(root.accountRef)"
        guard seen.insert(unique).inserted else { return }
        files.append(LogFile(url: url, root: root, modifiedAt: info.modifiedAt))
    }

    private func processClaude(_ data: Data, cursor: Cursor, accountRef: String,
                               finalizePending: Bool) -> (Cursor, [ParsedUsage]) {
        let (lines, next) = completeLines(data, cursor: cursor)
        let decoder = JSONDecoder()
        var pending = cursor.claudePending
        var finalized: [ParsedUsage] = []
        var anonymous: [ParsedUsage] = []

        for line in lines {
            guard let decoded = try? decoder.decode(ClaudeLine.self, from: line),
                  decoded.type == "assistant",
                  let message = decoded.message else { continue }
            let idHash = message.id.flatMap { nonEmpty($0) == nil ? nil : Self.sha256Hex($0) }
            if let idHash, let existingPending = pending, existingPending.idHash != idHash {
                finalized.append(claudeUsage(from: existingPending, accountRef: accountRef))
                pending = nil
            }
            guard
                  let timestamp = decoded.timestamp,
                  let date = parseTimestamp(timestamp),
                  let rawModel = nonEmpty(message.model),
                  let usage = message.usage else { continue }
            let tokens = [usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens,
                          usage.cache_creation_input_tokens]
            guard tokens.contains(where: { $0 != nil }),
                  tokens.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { continue }
            let messageFields = PendingClaudeMessage(
                idHash: idHash ?? "",
                model: safeModel(rawModel),
                effort: safeEffort(decoded.effort ?? decoded.perTurnEffort),
                toolVersion: safeToolVersion(decoded.version),
                timestamp: date,
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheReadInputTokens: usage.cache_read_input_tokens ?? 0,
                cacheCreationInputTokens: usage.cache_creation_input_tokens ?? 0)
            if idHash != nil {
                pending = messageFields
            } else {
                anonymous.append(claudeUsage(from: messageFields, accountRef: accountRef))
            }
        }
        if finalizePending, let pendingToFinalize = pending {
            finalized.append(claudeUsage(from: pendingToFinalize, accountRef: accountRef))
            pending = nil
        }
        var updated = next
        updated.claudePending = pending
        return (updated, anonymous + finalized)
    }

    private func claudeUsage(from pending: PendingClaudeMessage,
                             accountRef: String) -> ParsedUsage {
        ParsedUsage(
            day: SuggestionRetention.utcDay(pending.timestamp), occurredAt: pending.timestamp, provider: .claude,
            accountRef: accountRef, model: pending.model, effort: pending.effort,
            inputTokens: pending.inputTokens,
            cachedInputTokens: pending.cacheReadInputTokens,
            cachedCreationTokens: pending.cacheCreationInputTokens,
            outputTokens: pending.outputTokens, reasoningTokens: 0,
            toolVersion: pending.toolVersion)
    }

    private func accumulate(_ parsedUsage: ParsedUsage,
                            into totals: inout [UsageKey: Totals]) {
        let key = UsageKey(day: parsedUsage.day, provider: parsedUsage.provider,
                           accountRef: parsedUsage.accountRef, model: parsedUsage.model,
                           effort: parsedUsage.effort, toolVersion: parsedUsage.toolVersion,
                           subscription: parsedUsage.subscription)
        totals[key, default: Totals()].add(parsedUsage)
    }

    private func processCodex(_ data: Data, cursor: Cursor, accountRef: String,
                              now: Date) -> (Cursor, [ParsedUsage]) {
        let (lines, next) = completeLines(data, cursor: cursor)
        let decoder = JSONDecoder()
        var model = cursor.codexModel
        var effort = cursor.codexEffort
        var version = cursor.codexToolVersion
        var subscription = cursor.codexSubscription
        var usages: [ParsedUsage] = []

        for line in lines {
            guard let decoded = try? decoder.decode(CodexLine.self, from: line),
                  let type = decoded.type, let payload = decoded.payload else { continue }
            switch type {
            case "turn_context":
                let rawModel = nonEmpty(payload.model)
                    ?? nonEmpty(payload.collaboration_mode?.settings?.model)
                let rawEffort = nonEmpty(payload.effort)
                    ?? nonEmpty(payload.collaboration_mode?.settings?.reasoning_effort)
                model = rawModel.map(safeModel)
                effort = safeEffort(rawEffort)
            case "session_meta":
                version = safeToolVersion(payload.cli_version)
            case "event_msg" where payload.type == "token_count":
                // Codex writes the ChatGPT plan into every rate-limit block; an API-key session has none.
                if nonEmpty(payload.rate_limits?.plan_type) != nil { subscription = true }
                guard let timestamp = decoded.timestamp,
                      let date = parseTimestamp(timestamp),
                      (0...Self.maximumFileAge).contains(now.timeIntervalSince(date)),
                      let currentModel = model,
                      let usage = payload.info?.last_token_usage else { continue }
                let tokens = [usage.input_tokens, usage.cached_input_tokens, usage.output_tokens,
                              usage.reasoning_output_tokens]
                guard tokens.contains(where: { $0 != nil }),
                      tokens.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { continue }
                usages.append(ParsedUsage(
                    day: SuggestionRetention.utcDay(date), occurredAt: date, provider: .codex, accountRef: accountRef,
                    model: currentModel, effort: effort,
                    inputTokens: usage.input_tokens ?? 0,
                    cachedInputTokens: usage.cached_input_tokens ?? 0,
                    cachedCreationTokens: 0,
                    outputTokens: usage.output_tokens ?? 0,
                    reasoningTokens: usage.reasoning_output_tokens ?? 0,
                    toolVersion: version))
            default:
                continue
            }
        }
        var updated = next
        updated.codexModel = model
        updated.codexEffort = effort
        updated.codexToolVersion = version
        updated.codexSubscription = subscription
        if subscription == true {
            for index in usages.indices { usages[index].subscription = true }
        }
        return (updated, usages)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func completeLines(_ data: Data, cursor: Cursor) -> ([Data], Cursor) {
        var start = 0
        var discarding = cursor.discardingLongLine
        if discarding {
            guard let newline = data.firstIndex(of: 10) else {
                return ([], Cursor(inode: cursor.inode, offset: cursor.offset + UInt64(data.count),
                                   discardingLongLine: true))
            }
            start = newline + 1
            discarding = false
        }
        let remainder = data.dropFirst(start)
        guard let lastNewline = remainder.lastIndex(of: 10) else {
            if remainder.count > Self.maximumLineBytes {
                return ([], Cursor(inode: cursor.inode, offset: cursor.offset + UInt64(data.count),
                                   discardingLongLine: true))
            }
            return ([], Cursor(inode: cursor.inode, offset: cursor.offset + UInt64(start),
                               discardingLongLine: discarding))
        }

        let completeCount = remainder.distance(from: remainder.startIndex, to: lastNewline) + 1
        var lines: [Data] = []
        var lineStart = remainder.startIndex
        var index = remainder.startIndex
        while index <= lastNewline {
            if remainder[index] == 10 {
                let lineCount = remainder.distance(from: lineStart, to: index)
                if lineCount <= Self.maximumLineBytes {
                    lines.append(Data(remainder[lineStart..<index]))
                }
                lineStart = remainder.index(after: index)
            }
            if index == lastNewline { break }
            index = remainder.index(after: index)
        }
        let trailingCount = remainder.count - completeCount
        let discardTail = trailingCount > Self.maximumLineBytes
        let offset = discardTail
            ? cursor.offset + UInt64(data.count)
            : cursor.offset + UInt64(start + completeCount)
        return (lines, Cursor(inode: cursor.inode, offset: offset,
                              discardingLongLine: discardTail))
    }

    private func safeModel(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = normalized.lowercased().hasPrefix("models/")
            ? String(normalized.dropFirst("models/".count)) : normalized
        if let match = catalog?.models.first(where: {
            $0.model.caseInsensitiveCompare(withoutPrefix) == .orderedSame
                || $0.key.caseInsensitiveCompare(withoutPrefix) == .orderedSame
        }) {
            return match.key
        }
        return UsageSnapshot.maskedString(normalized)
    }

    private func safeEffort(_ raw: String?) -> String? {
        guard let value = nonEmpty(raw)?.lowercased(),
              ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(value) else {
            return nil
        }
        return value
    }

    private func safeToolVersion(_ raw: String?) -> String? {
        guard let value = nonEmpty(raw) else { return nil }
        return String(UsageSnapshot.maskedString(value).prefix(128))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private static func pathKey(_ path: String) -> String? {
        sha256Hex(path)
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFDIR
    }

    private static func fileInfo(_ url: URL) -> FileInfo? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0 else { return nil }
        let modifiedAt = Date(timeIntervalSince1970:
            TimeInterval(attributes.st_mtimespec.tv_sec)
                + TimeInterval(attributes.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileInfo(inode: UInt64(attributes.st_ino), size: UInt64(attributes.st_size),
                        modifiedAt: modifiedAt)
    }

    private static func read(_ url: URL, offset: UInt64, count: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0 else { return nil }
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var total = 0
            while total < bytes.count {
                let result = pread(descriptor, base.advanced(by: total), bytes.count - total,
                                   off_t(offset) + off_t(total))
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { break }
                total += result
            }
            return total
        }
        guard readCount > 0 else { return nil }
        data.removeSubrange(readCount..<data.count)
        return data
    }
}

private final class SuggestionLogUsageStore {
    private let directory: URL
    private let fs: SafeFS
    private let reader: BoundedReader

    init(directory: URL, fs: SafeFS, reader: BoundedReader) {
        self.directory = directory
        self.fs = fs
        self.reader = reader
    }

    /// What was appended, for undoing it; nil when a write failed (and what was written is undone).
    func append(_ records: [SuggestionLogUsage]) -> [SuggestionStorage.Appended]? {
        guard !records.isEmpty else { return [] }
        let grouped = Dictionary(grouping: records, by: \.day)
        var appended: [SuggestionStorage.Appended] = []
        do {
            try fs.createDirectory(directory)
            for (day, values) in grouped {
                if let entry = try SuggestionStorage.appendLines(
                    values.sorted { ($0.accountRef, $0.model, $0.effort ?? "")
                        < ($1.accountRef, $1.model, $1.effort ?? "") },
                    component: "log-usage", day: day, directory: directory, fs: fs) {
                    appended.append(entry)
                }
            }
            return appended
        } catch {
            SuggestionStorage.rollBack(appended, fs: fs)
            return nil
        }
    }

    /// Removes every stored usage file, current and archived.
    func removeAll() {
        let archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
        for folder in [directory, archiveDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where Self.day(in: file.lastPathComponent) != nil {
                try? fs.remove(file)
            }
        }
    }

    func recentRecords(now: Date, days: Int = 2) -> [SuggestionLogUsage] {
        let dayCount = min(max(days, 1), 35)
        let today = SuggestionRetention.utcDay(now)
        let firstDay = SuggestionRetention.utcDay(now.addingTimeInterval(-Double(dayCount - 1) * 86_400))
        let archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
        let files = ([directory, archiveDirectory]).flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        var remaining = SuggestionLogReader.maximumReadBytes
        let candidates = files.compactMap { file -> (URL, String)? in
            guard let day = Self.day(in: file.lastPathComponent),
                  day >= firstDay && day <= today else { return nil }
            return (file, day)
        }.sorted {
            $0.1 == $1.1
                ? Self.part(in: $0.0.lastPathComponent) > Self.part(in: $1.0.lastPathComponent)
                : $0.1 > $1.1
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [SuggestionLogUsage] = []
        for (file, _) in candidates where remaining > 0 {
            guard let info = SuggestionLogReaderFileInfo.read(file),
                  info.size <= UInt64(remaining),
                  case let .data(stored) = reader.read(atPath: file.path, using: { path in
                    FileManager.default.contents(atPath: path)
                  }) else { continue }
            let data: Data
            if file.pathExtension == "zlib" {
                guard let decoded = try? (stored as NSData).decompressed(using: .zlib) as Data,
                      decoded.count <= remaining else { continue }
                data = decoded
            } else {
                data = stored
            }
            guard data.count <= remaining else { continue }
            remaining -= data.count
            guard let lastNewline = data.lastIndex(of: 10) else { continue }
            var start = data.startIndex
            var index = data.startIndex
            while index <= lastNewline {
                if data[index] == 10 {
                    let range = start..<index
                    if range.count <= SuggestionStorage.maximumLineBytes,
                       let record = try? decoder.decode(SuggestionLogUsage.self, from: Data(data[range])) {
                        records.append(record)
                    }
                    start = data.index(after: index)
                }
                if index == lastNewline { break }
                index = data.index(after: index)
            }
        }
        return records
    }

    private static func day(in filename: String) -> String? {
        guard let range = filename.range(of: #"^log-usage-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:-[0-9]+)?\.jsonl(?:\.zlib)?$"#,
                                         options: .regularExpression) else { return nil }
        let matched = String(filename[range])
        let prefix = "log-usage-"
        let suffix = matched.firstIndex(of: ".") ?? matched.endIndex
        let stem = matched[prefix.endIndex..<suffix]
        return String(stem.prefix(10))
    }

    private static func part(in filename: String) -> Int {
        guard let match = filename.range(of: #"^log-usage-[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]+)\.jsonl(?:\.zlib)?$"#,
                                         options: .regularExpression),
              let numberRange = filename[match].range(of: #"-([0-9]+)\.jsonl"#,
                                                      options: .regularExpression),
              let digits = filename[match][numberRange].split(separator: ".").first?.dropFirst(),
              let part = Int(digits) else { return 1 }
        return part
    }
}

private struct SuggestionLogReaderFileInfo {
    let size: UInt64

    static func read(_ url: URL) -> SuggestionLogReaderFileInfo? {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0 else { return nil }
        return SuggestionLogReaderFileInfo(size: UInt64(attributes.st_size))
    }
}
