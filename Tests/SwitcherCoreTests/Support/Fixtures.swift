import Foundation
import SQLite3
@testable import SwitcherCore

// MARK: - Raw SQLite (test-side only)

final class TestDB {
    private(set) var handle: OpaquePointer?

    init(_ url: URL, create: Bool = true, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : (SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_URI)
        let escaped = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let path = readOnly ? "file:\(escaped)?mode=ro&immutable=1" : url.path
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw SwitcherError.sqlite("test open \(url.lastPathComponent)")
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw SwitcherError.sqlite("test exec: \(message)")
        }
    }


    func strings(_ sql: String) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw SwitcherError.sqlite("prepare \(sql)") }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }
}

// MARK: - Chromium Cookies

enum Chromium {
    static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + CookieJar.chromiumEpochOffset) * 1_000_000)
    }
}

struct CookieFixture {
    struct Row {
        var host: String
        var name: String
        var value: String
        var expires: Date
        var secure = true
        var httpOnly = true
    }

    static let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
          name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
          expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
          last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
          priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
          source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
          has_cross_site_ancestor INTEGER NOT NULL);
        """

    /// Standard signed-in jar: auth rows (removed by enrollment) plus keep-rows.
    static func signedInRows(identity: FakeIdentity?, sessionExpires: Date, tag: String = "0001", includeSession: Bool = true) -> [Row] {
        var rows: [Row] = []
        if includeSession {
            rows += [
                Row(host: ".claude.ai", name: "sessionKey", value: "FAKE-SESSION-\(tag)", expires: sessionExpires),
                Row(host: ".claude.ai", name: "sessionKeyLC", value: "FAKE-SESSION-LC-\(tag)", expires: sessionExpires),
                Row(host: ".claude.ai", name: "sessionKeyV3", value: "FAKE-SESSION-V3-\(tag)", expires: sessionExpires),
                Row(host: ".claude.ai", name: "routingHint", value: "FAKE-ROUTING-\(tag)", expires: sessionExpires),
                Row(host: ".claude.ai", name: "lastActiveOrg", value: identity?.org ?? "none", expires: sessionExpires,
                    httpOnly: false),
            ]
        }
        rows += [
            Row(host: "claude.ai", name: "__Host-ant_trusted_device", value: "FAKE-DEVICE-\(tag)",
                expires: Date().addingTimeInterval(365 * 86400)),
            Row(host: ".claude.ai", name: "cf_clearance", value: "FAKE-CF-\(tag)",
                expires: Date().addingTimeInterval(365 * 86400), httpOnly: true),
            Row(host: ".example.com", name: "sessionKey", value: "FAKE-OTHER-SITE-\(tag)",
                expires: Date().addingTimeInterval(86400)),
        ]
        if let identity {
            rows.append(Row(host: ".claude.ai", name: "fixture_identity", value: identity.fixtureValue,
                            expires: sessionExpires, secure: true, httpOnly: false))
        }
        return rows
    }

    @discardableResult
    static func make(
        at url: URL, identity: FakeIdentity?, sessionExpires: Date = Date().addingTimeInterval(20 * 86400),
        includeSession: Bool = true, version: Int = 24, lastCompatible: Int? = 24, tag: String = "0001",
        extraRows: [Row] = []
    ) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let db = try TestDB(url)
        try db.exec(schema)
        try db.exec("INSERT INTO meta VALUES('version','\(version)')")
        if let lastCompatible { try db.exec("INSERT INTO meta VALUES('last_compatible_version','\(lastCompatible)')") }
        try db.exec("INSERT INTO meta VALUES('mmap_status','-1')")
        let now = Chromium.microseconds(Date())
        let rows = signedInRows(identity: identity, sessionExpires: sessionExpires, tag: tag, includeSession: includeSession)
            + extraRows
        for r in rows {
            try db.exec("""
                INSERT INTO cookies VALUES(\(now), '\(r.host)', '', '\(r.name)', '\(r.value)', X'7631304641', '/',
                \(Chromium.microseconds(r.expires)), \(r.secure ? 1 : 0), \(r.httpOnly ? 1 : 0), \(now), 1, 1, 1, 0, 2,
                443, \(now), 0, 0)
                """)
        }
        db.close()
        return url
    }

    static func names(_ url: URL) throws -> [String] {
        let db = try TestDB(url, create: false, readOnly: true)
        return try db.strings("SELECT host_key || ' ' || name FROM cookies ORDER BY host_key, name")
    }
}

// MARK: - config.json

enum ConfigFixture {
    static func dictionary(lastKnown: String?, stagedVersion: String? = "1.0.0", runningPid: Int = 4242) -> [String: Any] {
        var d: [String: Any] = [
            "oauth:tokenCache": "FAKE-TOKEN-CACHE-0001",
            "oauth:tokenCacheV2": ["entries": ["FAKE-TOKEN-CACHE-V2-0001"]],
            "updaterRunningInstance": ["pid": runningPid],
            "dxt:allowlistEnabled:\(FakeIdentity.a.org)": true,
            "coworkTrustedDeviceToken:\(FakeIdentity.clientUuid)": "FAKE-DEVICE-TOKEN-0001",
            "locale": "en-US",
            "nested": ["keep": [1, 2, 3], "url": "https://claude.ai/x"],
        ]
        if let lastKnown { d["lastKnownAccountUuid"] = lastKnown }
        if let stagedVersion { d["updaterStagedPayloadKind"] = ["version": stagedVersion, "kind": "full"] }
        return d
    }

    @discardableResult
    static func make(at url: URL, lastKnown: String?, stagedVersion: String? = "1.0.0", runningPid: Int = 4242) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: dictionary(lastKnown: lastKnown, stagedVersion: stagedVersion, runningPid: runningPid),
            options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return data
    }
}

// MARK: - Files outside the allowlist

enum OutsideFixture {
    /// The CLI's own login file (never ours to touch), with a fake account.
    static func writeCLIConfig(_ url: URL, identity: FakeIdentity) throws {
        let obj: [String: Any] = ["oauthAccount": ["accountUuid": identity.account, "organizationUuid": identity.org]]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    /// Some other app's data directory.
    static func otherAppDir(_ env: SwitcherEnvironment) -> URL {
        env.home.appendingPathComponent("Library/Application Support/com.example.other-app", isDirectory: true)
    }
}

// MARK: - Logs

enum LogFixture {
    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    static func line(_ date: Date, _ text: String) -> String { "\(formatter().string(from: date)) [info] \(text)" }

    static func initLine(_ id: FakeIdentity) -> String {
        "[LocalSessionManager] Initialization succeeded — accountId=\(id.account), orgId=\(id.org), existingSessions=0"
    }

    static func agentInitLine(_ id: FakeIdentity) -> String {
        "[LocalAgentModeSessionManager] Initialization succeeded — accountId=\(id.account), orgId=\(id.org), existingSessions=2"
    }

    static func cacheKeyLine(_ id: FakeIdentity) -> String {
        "[oauth-v2] lookup orgId=\(id.org) cacheKey=acct:\(id.account)|\(FakeIdentity.clientUuid):\(id.org):https://api.anthropic.com:user:inference"
    }

    static let startText = "Starting app {"
    static let quitHandler = "beforeQuit: handler fired, going down"
    static let quitCleanupStart = "Starting onQuitCleanup handlers"
    static let veto = "beforeQuit: vetoed by before-quit interceptor"
    static let cleanQuit = "Successully ran all onQuitCleanup handlers, marking readyForQuit"
    static let logout = "[account] Navigated to /logout, synthesizing logged-out"
    static let loginTransition = "Login-state transition (loggedOut: false → true, reason=cookie_cleared)"

    static func append(_ url: URL, _ raw: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(raw.utf8))
    }

    static func appendLines(_ url: URL, _ lines: [(Date, String)]) throws {
        try append(url, lines.map { line($0.0, $0.1) + "\n" }.joined())
    }
}

// MARK: - LaunchAgents

enum AgentFixture {
    static let keepaliveLabel = "com.user.claude-keepalive"

    @discardableResult
    static func makeKeepalive(env: SwitcherEnvironment, scriptsDir: URL, label: String = keepaliveLabel) throws -> URL {
        let script = scriptsDir.appendingPathComponent("\(label).sh")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data("#!/bin/bash\nwhile true; do\n  pgrep -x Claude >/dev/null || open -g -a \"Claude\"\n  sleep 30\ndone\n".utf8)
            .write(to: script)
        return try writePlist(env: env, label: label, plist: [
            "Label": label, "ProgramArguments": ["/bin/bash", script.path], "RunAtLoad": true, "KeepAlive": true,
        ])
    }

    @discardableResult
    static func writePlist(env: SwitcherEnvironment, label: String, plist: [String: Any]) throws -> URL {
        let url = env.launchAgentsDir.appendingPathComponent("\(label).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }
}
