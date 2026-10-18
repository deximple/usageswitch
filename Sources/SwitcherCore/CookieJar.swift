import Foundation

/// Metadata-only access to Claude's Chromium cookie DB. Never selects `value` or `encrypted_value`.
public enum CookieJar {
    public struct Meta: Equatable, Sendable, Codable {
        public let version: Int
        public let lastCompatibleVersion: Int
    }

    public struct SessionInfo: Equatable, Sendable, Codable {
        public let expiresAt: Date
        public let httpOnly: Bool
        public let secure: Bool

        public func isValid(at now: Date) -> Bool { httpOnly && secure && expiresAt > now }
    }

    /// Chromium stores times as microseconds since 1601-01-01 UTC.
    static let chromiumEpochOffset: Double = 11_644_473_600

    static func date(fromChromium value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000 - chromiumEpochOffset)
    }

    public static func meta(of url: URL) throws -> Meta {
        let db = try SQLiteDB(path: url.path, mode: .readOnlyImmutable)
        let rows = try db.query("SELECT key, value FROM meta WHERE key IN ('version','last_compatible_version')")
        var values: [String: Int] = [:]
        for row in rows {
            if let k = row[0].text, let v = row[1].int { values[k] = Int(v) }
        }
        guard let version = values["version"] else { throw SwitcherError.sqlite(L10n.t(.reasonCookieMetaMissing)) }
        return Meta(version: version, lastCompatibleVersion: values["last_compatible_version"] ?? version)
    }

    /// The claude.ai `sessionKey` row's metadata, if present.
    public static func sessionInfo(of url: URL) throws -> SessionInfo? {
        let db = try SQLiteDB(path: url.path, mode: .readOnlyImmutable)
        let rows = try db.query("""
            SELECT expires_utc, is_httponly, is_secure FROM cookies
            WHERE name = 'sessionKey' AND host_key IN ('.claude.ai', 'claude.ai')
            ORDER BY expires_utc DESC LIMIT 1
            """)
        guard let row = rows.first, let exp = row[0].int else { return nil }
        return SessionInfo(expiresAt: date(fromChromium: exp), httpOnly: row[1].int == 1, secure: row[2].int == 1)
    }

    /// Deletes the sign-in rows from a *staged copy* (never the live DB) to prepare a fresh login.
    /// Values are never decrypted; device-trust and Cloudflare cookies are kept to reduce login friction.
    @discardableResult
    public static func removeAuthRows(fromStagedCopy url: URL, stagingDir: URL, fs: SafeFS) throws -> Int {
        try fs.check(url)
        guard SafeFS.normalized(url.deletingLastPathComponent()) == SafeFS.normalized(stagingDir) else {
            throw SwitcherError.forbiddenWrite(url.path)   // never the live jar
        }
        let db = try SQLiteDB(path: url.path, mode: .readWrite)
        let hosts = SnapshotItems.authCookieHosts
        var removed = 0
        for prefix in SnapshotItems.authCookieNamePrefixes {
            removed += try db.execute(
                "DELETE FROM cookies WHERE host_key IN (?, ?) AND name LIKE ? ESCAPE '\\'",
                [hosts[0], hosts[1], prefix.replacingOccurrences(of: "_", with: "\\_") + "%"])
        }
        return removed
    }

    /// Compatibility rule (design D6): Chromium migrates older cookie schemas forward on open, so an older
    /// or equal snapshot is fine; a newer one only if its `last_compatible_version` admits the installed
    /// schema. App version differences are only warnings.
    public static func isCompatible(snapshot: Meta, live: Meta?) -> Bool {
        guard let live else { return true }
        if snapshot.version <= live.version { return true }
        return snapshot.lastCompatibleVersion <= live.version
    }
}
