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
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let toolVersion: String?

    public init(day: String, provider: UsageProvider, accountRef: String, model: String,
                effort: String?, turns: Int, inputTokens: Int64, cachedInputTokens: Int64,
                outputTokens: Int64, reasoningTokens: Int64, toolVersion: String?) {
        self.day = day
        self.provider = provider
        self.accountRef = accountRef
        self.model = model
        self.effort = effort
        self.turns = turns
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.toolVersion = toolVersion
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

    public static func recent(_ records: [SuggestionLogUsage], now: Date) -> [String: Hint] {
        let today = SuggestionRetention.utcDay(now)
        let firstDay = SuggestionRetention.utcDay(now.addingTimeInterval(-24 * 60 * 60))
        var counts: [UsageKey: Int] = [:]
        for record in records where record.turns > 0
            && record.day >= firstDay && record.day <= today
            && !record.accountRef.isEmpty && !record.model.isEmpty {
            let key = UsageKey(accountRef: record.accountRef, model: record.model, effort: record.effort)
            counts[key, default: 0] += record.turns
        }

        var best: [String: (key: UsageKey, turns: Int)] = [:]
        for (key, turns) in counts {
            guard let current = best[key.accountRef] else {
                best[key.accountRef] = (key, turns)
                continue
            }
            if turns > current.turns
                || (turns == current.turns
                    && (key.model, key.effort ?? "") < (current.key.model, current.key.effort ?? "")) {
                best[key.accountRef] = (key, turns)
            }
        }
        return best.mapValues { Hint(model: $0.key.model, effort: $0.key.effort) }
    }
}

public struct SuggestionLogPass: Equatable, Sendable {
    public let records: [SuggestionLogUsage]
    public let bytesRead: Int
}

public final class SuggestionLogReader: @unchecked Sendable {
    public static let maximumLineBytes = 1_048_576
    public static let maximumReadBytes = 8 * 1_048_576
    public static let maximumFileAge: TimeInterval = 14 * 24 * 60 * 60

    private struct Cursor: Codable {
        var inode: UInt64
        var offset: UInt64
        var discardingLongLine = false
        var codexModel: String?
        var codexEffort: String?
        var codexToolVersion: String?
    }

    private struct FileCursorState: Codable {
        var cursors: [String: Cursor]
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
    }

    private struct Totals {
        var turns = 0
        var inputTokens: Int64 = 0
        var cachedInputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var reasoningTokens: Int64 = 0

        mutating func add(_ usage: ParsedUsage) {
            turns += 1
            inputTokens = Self.add(inputTokens, usage.inputTokens)
            cachedInputTokens = Self.add(cachedInputTokens, usage.cachedInputTokens)
            outputTokens = Self.add(outputTokens, usage.outputTokens)
            reasoningTokens = Self.add(reasoningTokens, usage.reasoningTokens)
        }

        private static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int64.max : sum
        }
    }

    private struct ParsedUsage {
        let day: String
        let provider: UsageProvider
        let accountRef: String
        let model: String
        let effort: String?
        let inputTokens: Int64
        let cachedInputTokens: Int64
        let outputTokens: Int64
        let reasoningTokens: Int64
        let toolVersion: String?
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

            let type: String?
            let model: String?
            let effort: String?
            let collaboration_mode: CollaborationMode?
            let info: Info?
            let cli_version: String?
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
    private let lock = NSLock()

    public init(env: SwitcherEnvironment, fs: SafeFS, catalog: SuggestionCatalog?,
                reader: BoundedReader = .shared) {
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

    public func read(roots: [SuggestionLogRoot], now: Date = Date()) -> SuggestionLogPass {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled else { return SuggestionLogPass(records: [], bytesRead: 0) }
        do { try fs.createDirectory(directory) } catch {
            return SuggestionLogPass(records: [], bytesRead: 0)
        }
        SuggestionRetention.prune(directory: directory, fs: fs, now: now, reader: boundedReader)
        var cursors = loadCursors()
        let files = eligibleFiles(roots: roots, now: now)
        var remaining = Self.maximumReadBytes
        var totalRead = 0
        var totals: [UsageKey: Totals] = [:]

        for file in files where remaining > 0 {
            guard !Task.isCancelled,
                  let pathKey = Self.pathKey(file.url.path),
                  let accountRef = accountReferences.key(for: file.root.accountRef),
                  let info = Self.fileInfo(file.url) else { continue }
            var cursor = cursors[pathKey] ?? Cursor(inode: info.inode, offset: 0)
            if cursor.inode != info.inode || info.size < cursor.offset {
                cursor = Cursor(inode: info.inode, offset: 0)
            }
            guard cursor.offset < info.size else {
                cursors[pathKey] = cursor
                continue
            }

            let requested = Int(min(info.size - cursor.offset, UInt64(remaining)))
            guard requested > 0, let data = Self.read(file.url, offset: cursor.offset, count: requested) else {
                continue
            }
            totalRead += data.count
            remaining -= data.count
            let parsed: [ParsedUsage]
            let nextCursor: Cursor
            switch file.root.provider {
            case .claude:
                (nextCursor, parsed) = processClaude(
                    data, cursor: cursor, accountRef: accountRef)
            case .codex:
                (nextCursor, parsed) = processCodex(
                    data, cursor: cursor, accountRef: accountRef,
                    now: now)
            // Cursor, Devin, Gemini, Antigravity and OpenCode have no readers because their formats are unverified.
            default:
                continue
            }
            cursors[pathKey] = nextCursor
            for parsedUsage in parsed {
                let key = UsageKey(day: parsedUsage.day, provider: parsedUsage.provider,
                                   accountRef: parsedUsage.accountRef, model: parsedUsage.model,
                                   effort: parsedUsage.effort, toolVersion: parsedUsage.toolVersion)
                totals[key, default: Totals()].add(parsedUsage)
            }
        }

        let records = totals.map { key, value in
            SuggestionLogUsage(day: key.day, provider: key.provider, accountRef: key.accountRef,
                               model: key.model, effort: key.effort, turns: value.turns,
                               inputTokens: value.inputTokens, cachedInputTokens: value.cachedInputTokens,
                               outputTokens: value.outputTokens, reasoningTokens: value.reasoningTokens,
                               toolVersion: key.toolVersion)
        }.sorted {
            ($0.day, $0.provider.rawValue, $0.accountRef, $0.model, $0.effort ?? "", $0.toolVersion ?? "")
                < ($1.day, $1.provider.rawValue, $1.accountRef, $1.model, $1.effort ?? "", $1.toolVersion ?? "")
        }

        guard !Task.isCancelled else { return SuggestionLogPass(records: [], bytesRead: totalRead) }
        guard usageStore.append(records) else {
            return SuggestionLogPass(records: records, bytesRead: totalRead)
        }
        do { try saveCursors(cursors) } catch { }
        return SuggestionLogPass(records: records, bytesRead: totalRead)
    }

    public func recentSummary(now: Date = Date()) -> [String: SuggestionLogSummary.Hint] {
        SuggestionLogSummary.recent(usageStore.recentRecords(now: now), now: now)
    }

    private func loadCursors() -> [String: Cursor] {
        guard case let .data(data) = boundedReader.read(atPath: cursorFile.path, using: { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 4 * 1_048_576 else { return nil }
            return FileManager.default.contents(atPath: path)
        }), let state = try? JSONDecoder().decode(FileCursorState.self, from: data) else { return [:] }
        return state.cursors
    }

    private func saveCursors(_ cursors: [String: Cursor]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.write(try encoder.encode(FileCursorState(cursors: cursors)), to: cursorFile)
    }

    private func eligibleFiles(roots: [SuggestionLogRoot], now: Date) -> [LogFile] {
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
        return files.sorted {
            $0.url.path == $1.url.path
                ? $0.root.accountRef < $1.root.accountRef
                : $0.url.path < $1.url.path
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

    private func processClaude(_ data: Data, cursor: Cursor,
                               accountRef: String) -> (Cursor, [ParsedUsage]) {
        let (lines, next) = completeLines(data, cursor: cursor)
        let decoder = JSONDecoder()
        var keyed: [String: ParsedUsage] = [:]
        var anonymous: [ParsedUsage] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        for line in lines {
            guard let decoded = try? decoder.decode(ClaudeLine.self, from: line),
                  decoded.type == "assistant",
                  let timestamp = decoded.timestamp,
                  let date = formatter.date(from: timestamp) ?? fallbackFormatter.date(from: timestamp),
                  let message = decoded.message,
                  let rawModel = nonEmpty(message.model),
                  let usage = message.usage else { continue }
            let tokens = [usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens,
                          usage.cache_creation_input_tokens]
            guard tokens.contains(where: { $0 != nil }),
                  tokens.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { continue }
            let parsed = ParsedUsage(
                day: SuggestionRetention.utcDay(date), provider: .claude, accountRef: accountRef,
                model: safeModel(rawModel), effort: safeEffort(decoded.effort ?? decoded.perTurnEffort),
                inputTokens: usage.input_tokens ?? 0,
                cachedInputTokens: Self.saturatingAdd(
                    usage.cache_read_input_tokens ?? 0, usage.cache_creation_input_tokens ?? 0),
                outputTokens: usage.output_tokens ?? 0, reasoningTokens: 0,
                toolVersion: safeToolVersion(decoded.version))
            if let id = message.id, !id.isEmpty {
                keyed[id] = parsed
            } else {
                anonymous.append(parsed)
            }
        }
        return (next, anonymous + keyed.values)
    }

    private func processCodex(_ data: Data, cursor: Cursor, accountRef: String,
                              now: Date) -> (Cursor, [ParsedUsage]) {
        let (lines, next) = completeLines(data, cursor: cursor)
        let decoder = JSONDecoder()
        var model = cursor.codexModel
        var effort = cursor.codexEffort
        var version = cursor.codexToolVersion
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
                    day: SuggestionRetention.utcDay(date), provider: .codex, accountRef: accountRef,
                    model: currentModel, effort: effort,
                    inputTokens: usage.input_tokens ?? 0,
                    cachedInputTokens: usage.cached_input_tokens ?? 0,
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
        let digest = SHA256.hash(data: Data(path.utf8))
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

    func append(_ records: [SuggestionLogUsage]) -> Bool {
        guard !records.isEmpty else { return true }
        let grouped = Dictionary(grouping: records, by: \.day)
        do {
            try fs.createDirectory(directory)
            for (day, values) in grouped {
                try SuggestionStorage.appendLines(
                    values.sorted { ($0.accountRef, $0.model, $0.effort ?? "")
                        < ($1.accountRef, $1.model, $1.effort ?? "") },
                    component: "log-usage", day: day, directory: directory, fs: fs)
            }
            return true
        } catch {
            return false
        }
    }

    func recentRecords(now: Date) -> [SuggestionLogUsage] {
        let today = SuggestionRetention.utcDay(now)
        let firstDay = SuggestionRetention.utcDay(now.addingTimeInterval(-24 * 60 * 60))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var remaining = SuggestionLogReader.maximumReadBytes
        let candidates = files.filter { file in
            guard let day = Self.day(in: file.lastPathComponent) else { return false }
            return day >= firstDay && day <= today
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        var records: [SuggestionLogUsage] = []
        for file in candidates where remaining > 0 {
            guard let info = SuggestionLogReaderFileInfo.read(file),
                  info.size <= UInt64(remaining),
                  case let .data(data) = reader.read(atPath: file.path, using: { path in
                    FileManager.default.contents(atPath: path)
                  }) else { continue }
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
        guard let range = filename.range(of: #"^log-usage-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:-[0-9]+)?\.jsonl$"#,
                                         options: .regularExpression) else { return nil }
        let matched = String(filename[range])
        let prefix = "log-usage-"
        let suffix = matched.firstIndex(of: ".") ?? matched.endIndex
        let stem = matched[prefix.endIndex..<suffix]
        return String(stem.prefix(10))
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
