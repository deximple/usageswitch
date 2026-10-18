import Foundation

/// Read-only view of Claude's config.json plus the one sanctioned mutation (design D3).
public struct ClaudeConfig: Sendable {
    public let lastKnownAccountUuid: String?
    public let stagedUpdateVersion: String?
    public let runningInstancePID: Int?
    public let hasTokenCache: Bool

    public init(data: Data) throws {
        let dict = try Self.parse(data)
        lastKnownAccountUuid = dict[SnapshotItems.lastKnownAccountKey] as? String
        stagedUpdateVersion = (dict["updaterStagedPayloadKind"] as? [String: Any])?["version"] as? String
        runningInstancePID = ((dict["updaterRunningInstance"] as? [String: Any])?["pid"] as? NSNumber)?.intValue
        hasTokenCache = SnapshotItems.tokenCacheKeys.contains { dict[$0] != nil }
    }

    public static func load(_ url: URL) throws -> ClaudeConfig {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw SwitcherError.io(L10n.t(.reasonConfigUnreadable))
        }
        return try ClaudeConfig(data: data)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw SwitcherError.io(L10n.t(.reasonConfigInvalid))
        }
        return dict
    }

    public enum Mutation: Sendable, Equatable {
        /// Restore a snapshot: point the account marker at the snapshot identity and drop token caches
        /// so Claude re-mints them from the restored sessionKey.
        case restore(accountUuid: String)
        /// Prepare a fresh sign-in: no account marker, no token caches (avoids identity-change resets).
        case clearForLogin
    }

    /// The same config without the encrypted OAuth token caches (for copies kept in the switcher store).
    public static func strippingTokenCaches(_ data: Data) throws -> Data {
        var dict = try parse(data)
        for key in SnapshotItems.tokenCacheKeys { dict.removeValue(forKey: key) }
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// Returns new config bytes with only the sanctioned keys changed; all other keys are preserved.
    public static func mutated(_ data: Data, _ mutation: Mutation) throws -> Data {
        var dict = try parse(data)
        for key in SnapshotItems.tokenCacheKeys { dict.removeValue(forKey: key) }
        switch mutation {
        case .restore(let uuid): dict[SnapshotItems.lastKnownAccountKey] = uuid
        case .clearForLogin: dict.removeValue(forKey: SnapshotItems.lastKnownAccountKey)
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}
