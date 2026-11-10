import Darwin
import Foundation

/// Reads Claude's Winston logs (`main.log`, rotated to `main1.log` … `main4.log` at 10 MB) without ever
/// trusting byte offsets across rotation (design D5).
public struct ClaudeLog: Sendable {
    public struct Line: Equatable, Sendable {
        public let timestamp: Date
        public let text: String
        /// When a `Cursor` read the line. Unlike `timestamp` it does not depend on parsing the log's wall clock.
        public let observedAt: Date?
        public init(timestamp: Date, text: String, observedAt: Date? = nil) {
            self.timestamp = timestamp
            self.text = text
            self.observedAt = observedAt
        }
    }

    /// An (account, org) pair observed in the log.
    public struct IdentitySignal: Equatable, Sendable {
        public let timestamp: Date
        public let accountUuid: String
        public let orgUuid: String
        /// A logout marker appeared after this signal.
        public let loggedOutAfter: Bool
    }

    public let logsDir: URL
    public static let fileNames = ["main.log", "main1.log", "main2.log", "main3.log", "main4.log"]

    /// Status polling looks here first; the whole file is read only when the tail has no answer.
    static let tailBytes = 262_144
    /// Called with the file name and byte count of every read (tests count reads through it).
    var onRead: (@Sendable (String, Int) -> Void)?

    public init(logsDir: URL) { self.logsDir = logsDir }

    // MARK: - Parsing

    /// Claude writes local wall-clock time in the Gregorian calendar, whatever calendar the user picked.
    static let logCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static func parseTimestamp(_ line: Substring) -> Date? {
        let u = Array(line.utf8.prefix(19))
        guard u.count == 19, u[4] == 45, u[7] == 45, u[10] == 32, u[13] == 58, u[16] == 58 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { let d = Int(u[i]) - 48; guard (0...9).contains(d) else { return nil }; v = v * 10 + d }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let s = num(17..<19) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi; comps.second = s
        return logCalendar.date(from: comps)
    }

    /// Splits text into lines; continuation lines (no timestamp) inherit the previous timestamp.
    public static func parse(_ text: String, initialTimestamp: Date? = nil) -> [Line] {
        var out: [Line] = []
        var current = initialTimestamp
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let ts = parseTimestamp(raw) { current = ts }
            guard let ts = current else { continue }
            out.append(Line(timestamp: ts, text: String(raw)))
        }
        return out
    }

    /// The whole file, or its last `tailBytes`. A tail that starts inside a line drops that fragment.
    func read(_ name: String, tailBytes: Int? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logsDir.appendingPathComponent(name)) else { return nil }
        defer { try? handle.close() }
        var cut = false
        if let tailBytes {
            let size = (try? handle.seekToEnd()) ?? 0
            cut = size > UInt64(tailBytes)
            // One byte early, so a tail that begins exactly on a line boundary keeps its first line.
            try? handle.seek(toOffset: cut ? size - UInt64(tailBytes) - 1 : 0)
        }
        guard var data = try? handle.readToEnd() else { return nil }
        onRead?(name, data.count)
        if cut {
            guard let newline = data.firstIndex(of: 0x0A) else { return "" }
            data = data[data.index(after: newline)...]
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Bytes of `name` from `offset` to the end (nil when the file cannot be opened).
    func readData(_ name: String, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: logsDir.appendingPathComponent(name)) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        onRead?(name, data.count)
        return data
    }

    private func size(of name: String) -> Int? {
        var info = stat()
        return stat(logsDir.appendingPathComponent(name).path, &info) == 0 ? Int(info.st_size) : nil
    }

    /// Walks the log newest line first and stops at the first line `match` accepts. Each file is tried by
    /// its tail before it is read whole. `loggedOutAfter` says whether a logout marker follows that line.
    private func newestMatch<T>(_ match: (Line) -> T?) -> (value: T, loggedOutAfter: Bool)? {
        var loggedOutInNewerFiles = false
        for name in Self.fileNames {
            guard let size = size(of: name) else { continue }
            let passes: [Int?] = size > Self.tailBytes ? [Self.tailBytes, nil] : [nil]
            for tail in passes {
                guard let text = read(name, tailBytes: tail) else { break }
                var loggedOut = loggedOutInNewerFiles
                for line in Self.parse(text).reversed() {
                    if Self.logoutPatterns.contains(where: { line.text.contains($0) }) { loggedOut = true }
                    if let value = match(line) { return (value, loggedOut) }
                }
                if tail == nil { loggedOutInNewerFiles = loggedOut }
            }
        }
        return nil
    }

    /// Lines with timestamp >= `since` (second resolution) from main1.log + main.log, oldest first.
    public func lines(since: Date) -> [Line] {
        let floorSince = Date(timeIntervalSince1970: floor(since.timeIntervalSince1970))
        var out: [Line] = []
        for name in ["main1.log", "main.log"] {
            guard let text = read(name) else { continue }
            out += Self.parse(text).filter { $0.timestamp >= floorSince }
        }
        return out
    }

    // MARK: - Markers

    static let initMarker = "[LocalSessionManager] Initialization succeeded — accountId="
    static let cacheKeyRegex = try! NSRegularExpression(
        pattern: #"cacheKey=acct:([0-9a-f-]{36})\|[0-9a-f-]{36}:([0-9a-f-]{36}):"#)

    public static let startMarker = "[info] Starting app"
    public static let vetoMarker = "beforeQuit: vetoed by before-quit interceptor"
    public static let quitHandlerMarker = "beforeQuit:"
    public static let cleanupStartMarker = "Starting onQuitCleanup"
    public static let cleanQuitMarker = "Successully ran all onQuitCleanup handlers"
    /// The app's own spelling plus likely variants, so a typo fix in Claude does not make every quit "unclean".
    public static let cleanQuitMarkers = [
        cleanQuitMarker, "Successfully ran all onQuitCleanup handlers", "marking readyForQuit", "onQuitCleanup handlers done",
    ]
    public static let multiAccountMarker = "/api/auth/accounts"

    /// Any of these after a relaunch means the switch did not land cleanly. ("dropped (identity mismatch)"
    /// is deliberately absent: every cold start logs it benignly for empty custom groups.)
    public static let failurePatterns = [
        "Login-state transition", "names a different account", "not minting", "not_logged_in",
        "User is logged out", "Cannot initialize sessions", "no sessionKey cookie", "session_stale_relogin",
        "Navigated to /logout",
    ]
    /// Failures meaning the stored sign-in itself is no longer valid.
    public static let reloginPatterns = [
        "not_logged_in", "User is logged out", "no sessionKey cookie", "session_stale_relogin", "Navigated to /logout",
    ]
    public static let logoutPatterns = [
        "Navigated to /logout", "Login-state transition (loggedOut: false → true", "User is logged out",
    ]

    public static func parseInit(_ line: Line) -> (account: String, org: String)? {
        guard let r = line.text.range(of: initMarker) else { return nil }
        let rest = line.text[r.upperBound...]
        guard let comma = rest.range(of: ", orgId=") else { return nil }
        let account = String(rest[..<comma.lowerBound])
        let org = String(rest[comma.upperBound...].prefix { $0 != "," && $0 != " " })
        guard isUUID(account), isUUID(org) else { return nil }
        return (account.lowercased(), org.lowercased())
    }

    /// Account/org ids become path components, so only canonical UUIDs are accepted.
    public static func isUUID(_ s: String) -> Bool { s.count == 36 && UUID(uuidString: s) != nil }

    static func parseCacheKey(_ line: Line) -> (account: String, org: String)? {
        let ns = line.text as NSString
        guard let m = cacheKeyRegex.firstMatch(in: line.text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let account = ns.substring(with: m.range(at: 1)), org = ns.substring(with: m.range(at: 2))
        guard isUUID(account), isUUID(org) else { return nil }
        return (account, org)
    }

    /// Most recent account/org evidence: an `Initialization succeeded` line, or a token-cache lookup that
    /// names `acct:<uuid>|…:<org>` (these appear constantly while signed in). Scans newest file first.
    public func latestIdentity() -> IdentitySignal? {
        newestMatch { line in (Self.parseInit(line) ?? Self.parseCacheKey(line)).map { (line.timestamp, $0) } }
            .map { found in
                IdentitySignal(timestamp: found.value.0, accountUuid: found.value.1.account,
                               orgUuid: found.value.1.org, loggedOutAfter: found.loggedOutAfter)
            }
    }

    /// Design D2-5 recapture guard: the last `[LocalSessionManager] Initialization succeeded` exists and no
    /// logout marker follows it (token-cache lookups are not treated as sign-in evidence here).
    public func signedInSinceLastInit() -> Bool {
        newestMatch { Self.parseInit($0) != nil ? true : nil }.map { !$0.loggedOutAfter } ?? false
    }

    // MARK: - Incremental reading

    /// Follows the log from "now" onward, surviving a rotation (the old inode becomes main1.log).
    public final class Cursor: @unchecked Sendable {
        let log: ClaudeLog
        private var inode: ino_t = 0
        private var offset: UInt64 = 0
        private var lastTimestamp: Date?
        private let now: @Sendable () -> Date
        public private(set) var collected: [Line] = []

        public init(log: ClaudeLog, now: @escaping @Sendable () -> Date = { Date() }) {
            self.log = log
            self.now = now
            let url = log.logsDir.appendingPathComponent("main.log")
            var st = stat()
            if stat(url.path, &st) == 0 {
                inode = st.st_ino
                offset = UInt64(st.st_size)
            }
        }

        @discardableResult
        public func poll() -> [Line] {
            let mainURL = log.logsDir.appendingPathComponent("main.log")
            var newText = ""
            if let ino = Self.inode(of: mainURL), ino == inode {
                let (text, read) = Self.read(mainURL, from: offset)
                newText = text
                offset += read
            } else {
                // Rotated: finish the old inode (now main1.log…), then read the new main.log from the start.
                if inode != 0, let rotated = ClaudeLog.fileNames.dropFirst()
                    .map({ log.logsDir.appendingPathComponent($0) })
                    .first(where: { Self.inode(of: $0) == inode }) {
                    newText = Self.read(rotated, from: offset).text
                }
                if let ino = Self.inode(of: mainURL) {
                    let (text, read) = Self.read(mainURL, from: 0)
                    newText += text
                    inode = ino
                    offset = read
                } else {
                    inode = 0
                    offset = 0
                }
            }
            let observedAt = now()
            let lines = ClaudeLog.parse(newText, initialTimestamp: lastTimestamp)
                .map { Line(timestamp: $0.timestamp, text: $0.text, observedAt: observedAt) }
            if let last = lines.last { lastTimestamp = last.timestamp }
            collected += lines
            return lines
        }

        static func inode(of url: URL) -> ino_t? {
            var s = stat()
            return stat(url.path, &s) == 0 ? s.st_ino : nil
        }

        /// Reads whole lines only, so a partially written trailing line is picked up on the next poll.
        static func read(_ url: URL, from offset: UInt64) -> (text: String, read: UInt64) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return ("", 0) }
            defer { try? h.close() }
            try? h.seek(toOffset: offset)
            let data = (try? h.readToEnd()) ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return ("", 0) }
            let complete = data[data.startIndex...lastNewline]
            return (String(decoding: complete, as: UTF8.self), UInt64(complete.count))
        }
    }
}

/// Outcome of evaluating design D5 1–2 over the lines logged since a relaunch.
public enum LaunchVerdict: Equatable, Sendable {
    case pending
    case success(initAt: Date)
    case failure(reason: String, needsRelogin: Bool)

    public static func evaluate(
        lines: [ClaudeLog.Line], targetAccount: String, targetOrg: String, now: Date, settle: TimeInterval
    ) -> LaunchVerdict {
        guard let startIdx = lines.firstIndex(where: { $0.text.contains(ClaudeLog.startMarker) }) else { return .pending }
        let after = lines[startIdx...]
        for l in after {
            if let hit = ClaudeLog.failurePatterns.first(where: { l.text.contains($0) }) {
                let relogin = ClaudeLog.reloginPatterns.contains(where: { l.text.contains($0) })
                return .failure(reason: L10n.t(.reasonLogPattern, hit), needsRelogin: relogin)
            }
        }
        guard let firstLine = after.first(where: { ClaudeLog.parseInit($0) != nil }),
              let first = ClaudeLog.parseInit(firstLine) else { return .pending }
        guard first.account == targetAccount, first.org == targetOrg else {
            return .failure(
                reason: L10n.t(.reasonWrongAccount, String(first.account.prefix(8)), String(first.org.prefix(8))),
                needsRelogin: false)
        }
        if now.timeIntervalSince(firstLine.observedAt ?? firstLine.timestamp) < settle { return .pending }
        return .success(initAt: firstLine.timestamp)
    }
}
