import Foundation

/// Limit resets a vendor granted the account (Codex "rate limit reset credits"). Only the count and
/// the expiries are kept — the vendor's credit ids, titles and descriptions are never read into it.
public struct UsageResetCredits: Equatable, Sendable {
    /// Resets the account can use now, as the vendor counts them.
    public let available: Int
    /// Expiry of each available reset that reported one, earliest first. Empty when the read carried
    /// only the count, or when none expires. Can be shorter than `available` (the vendor caps the list).
    public let expiries: [Date]

    public init(available: Int, expiries: [Date] = []) {
        self.available = max(0, available)
        self.expiries = expiries.sorted()
    }

    /// The first reset still to expire at `now`; nil when no expiry is known.
    public func nextExpiry(now: Date) -> Date? {
        expiries.first { $0 > now }
    }
}

/// Remembers each Codex account's last detailed reset read, in memory only. Codex asks background
/// polls to skip the separate per-credit lookup (`excludeResetCreditDetails`); this lets a 5-minute
/// poll do that and still show expiries, asking for details again only when they may be out of date.
/// Entries are tied to the login that was read (`login`, the opaque identity key), so a different
/// account signed into the same Codex home never sees the previous one's expiries.
public final class CodexResetCreditCache: @unchecked Sendable {
    /// The app's one cache; a collector is rebuilt every refresh, so the cache must outlive it.
    public static let shared = CodexResetCreditCache()
    /// How long a detailed read stands while the count stays the same.
    public static let detailLifetime: TimeInterval = 6 * 60 * 60

    private struct Entry {
        /// nil: the detailed read came back without any reset credits (none held, or an older server).
        let credits: UsageResetCredits?
        let login: String?
        let detailedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Whether the next read of `account` should include the per-credit details: nothing kept for this
    /// login yet, the kept read is older than `detailLifetime`, or the clock moved backwards.
    public func wantsDetails(account: String, login: String?, now: Date) -> Bool {
        lock.withLock {
            guard let entry = entries[account], entry.login == login else { return true }
            let age = now.timeIntervalSince(entry.detailedAt)
            return age < 0 || age >= Self.detailLifetime
        }
    }

    /// Folds one read in and returns what to show. A detailed read replaces the kept one, even when it
    /// carried no credits (so an account or server without them isn't asked again every poll). A
    /// count-only read reuses the kept expiries while the login and count match; a changed count drops
    /// them (a reset was used or granted), so the next read asks for details again.
    public func merge(account: String, login: String?, read: UsageResetCredits?, detailed: Bool,
                      now: Date) -> UsageResetCredits? {
        lock.withLock {
            if detailed {
                entries[account] = Entry(credits: read, login: login, detailedAt: now)
                return read
            }
            guard let read else { return nil }
            guard let entry = entries[account], entry.login == login else { return read }
            if let kept = entry.credits, kept.available == read.available { return kept }
            entries[account] = nil
            return read
        }
    }

    /// Drops what was kept for `account` (its read was attributed to another login).
    public func forget(account: String) {
        lock.withLock { entries[account] = nil }
    }
}
