import Darwin
import Foundation

/// Reads Claude's Winston logs (`main.log`, rotated to `main1.log` … `main4.log` at 10 MB) without ever
/// trusting byte offsets across rotation (design D5).
public struct ClaudeLog: Sendable {
    public struct Line: Equatable, Sendable {
        public let timestamp: Date
        public let text: String
        public init(timestamp: Date, text: String) {
            self.timestamp = timestamp
            self.text = text
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

    public init(logsDir: URL) { self.logsDir = logsDir }

    // MARK: - Parsing

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
        return Calendar.current.date(from: comps)
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

    func read(_ name: String, tailBytes: Int? = nil) -> String? {
        let url = logsDir.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if let tailBytes {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
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
        var loggedOutAfter = false
        for name in Self.fileNames {
            guard let text = read(name) else { continue }
            for line in Self.parse(text).reversed() {
                if Self.logoutPatterns.contains(where: { line.text.contains($0) }) { loggedOutAfter = true }
                if let pair = Self.parseInit(line) ?? Self.parseCacheKey(line) {
                    return IdentitySignal(
                        timestamp: line.timestamp, accountUuid: pair.account, orgUuid: pair.org,
                        loggedOutAfter: loggedOutAfter)
                }
            }
        }
        return nil
    }

    /// Design D2-5 recapture guard: the last `[LocalSessionManager] Initialization succeeded` exists and no
    /// logout marker follows it (token-cache lookups are not treated as sign-in evidence here).
    public func signedInSinceLastInit() -> Bool {
        var loggedOutAfter = false
        for name in Self.fileNames {
            guard let text = read(name) else { continue }
            for line in Self.parse(text).reversed() {
                if Self.logoutPatterns.contains(where: { line.text.contains($0) }) { loggedOutAfter = true }
                if Self.parseInit(line) != nil { return !loggedOutAfter }
            }
        }
        return false
    }

    // MARK: - Incremental reading

    /// Follows the log from "now" onward, surviving a rotation (the old inode becomes main1.log).
    public final class Cursor: @unchecked Sendable {
        let log: ClaudeLog
        private var inode: ino_t = 0
        private var offset: UInt64 = 0
        private var lastTimestamp: Date?
        public private(set) var collected: [Line] = []

        public init(log: ClaudeLog) {
            self.log = log
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
            let lines = ClaudeLog.parse(newText, initialTimestamp: lastTimestamp)
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
        if now.timeIntervalSince(firstLine.timestamp) < settle { return .pending }
        return .success(initAt: firstLine.timestamp)
    }
}
