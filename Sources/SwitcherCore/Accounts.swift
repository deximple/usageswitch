import Foundation

/// Non-secret identity of an Anthropic account, as recorded with a saved sign-in.
public struct AccountIdentity: Codable, Equatable, Hashable, Sendable {
    public let accountUuid: String
    public let orgUuid: String
    public let email: String?
    public let displayName: String?

    public init(accountUuid: String, orgUuid: String, email: String?, displayName: String?) {
        self.accountUuid = accountUuid
        self.orgUuid = orgUuid
        self.email = email
        self.displayName = displayName
    }

    /// Snapshot key: one stored Desktop sign-in per account+org.
    public var key: String { "\(accountUuid)__\(orgUuid)" }
}

/// One selectable account: a Claude Desktop sign-in saved in this app.
public struct SwitcherAccount: Codable, Equatable, Identifiable, Sendable {
    /// Stable id: the identity key (`<account-uuid>__<org-uuid>`).
    public let id: String
    /// Shown everywhere: the user's name for the account, else its default name.
    public let label: String
    public let identity: AccountIdentity
    /// The name the user gave this account, if any.
    public let customName: String?

    /// - Parameter distinguishOrg: append the organization to a default name another account also has
    ///   (one email in two organizations).
    public init(identity: AccountIdentity, customName: String? = nil, distinguishOrg: Bool = false) {
        id = identity.key
        self.identity = identity
        self.customName = customName
        let base = Self.defaultName(for: identity)
        label = customName ?? (distinguishOrg ? "\(base) · \(identity.orgUuid.prefix(8))" : base)
    }

    /// The name used until the user picks one: the email, else the display name, else the start of the id.
    public static func defaultName(for identity: AccountIdentity) -> String {
        identity.email ?? identity.displayName ?? String(identity.accountUuid.prefix(8))
    }

    /// Everything this account can be looked up by besides its id: shown name, default name and email.
    public var names: [String] {
        [label, Self.defaultName(for: identity)] + (identity.email.map { [$0] } ?? [])
    }

    /// Case-insensitive, compatibility-normalized form used to compare names: NFKC makes
    /// lookalike encodings (full-width, ligatures, decomposed marks) fold to one key.
    public static func fold(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    public func answers(to name: String) -> Bool {
        let wanted = Self.fold(name)
        return names.contains { Self.fold($0) == wanted }
    }
}

/// The user's own names for accounts, kept in this app's store and keyed by identity key.
public enum AccountNames {
    public static let maxLength = 40

    /// The stored names; nil when the file exists but can't be read (then nothing may overwrite it).
    public static func load(env: SwitcherEnvironment) -> [String: String]? {
        LockedStoreFile.load(env.accountNamesFile, as: [String: String].self, empty: [:])
    }

    /// Read-modify-write under an exclusive lock, so the app and the CLI never lose each other's changes.
    /// An unreadable names file is left alone and reported.
    public static func update(env: SwitcherEnvironment, fs: SafeFS, _ change: (inout [String: String]) throws -> Void) throws {
        try LockedStoreFile.update(env.accountNamesFile, lock: env.accountNamesLockFile, env: env, fs: fs, empty: [:],
                                   isEmpty: { $0.isEmpty }, change)
    }

    /// The name to store for a request: trimmed, at most `maxLength` characters, without line breaks, control
    /// characters or bidi overrides; nil when blank (back to the default name).
    public static func validated(_ raw: String?) throws -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxLength, !trimmed.unicodeScalars.contains(where: isForbidden) else {
            throw SwitcherError.invalidAccountName(maxLength: maxLength)
        }
        return trimmed.precomposedStringWithCompatibilityMapping
    }

    /// Format characters such as emoji joiners are fine; bidi overrides, invisible width/zero-space
    /// marks and tag characters could make one name look like another.
    static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar) { return true }
        if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return true }
        if (0x200B...0x200F).contains(scalar.value) || scalar.value == 0x2060
            || scalar.value == 0xFEFF || scalar.value == 0x061C { return true }
        return (0xE0000...0xE007F).contains(scalar.value)
    }
}
