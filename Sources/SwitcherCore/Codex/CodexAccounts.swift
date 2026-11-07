import Foundation

/// A Codex home shown in the Codex tab. Each account has its own home and opens in its own Codex window.
public struct CodexProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// ~/.codex, used by Codex's usual window and the command line.
        case standard
        /// Another Codex home in the home folder (`~/.codex-work`, `~/.codex_second`, …). Listed only after the user
        /// adds it: a folder like that may also be a backup copy, and opening a copy would use its sign-in twice.
        case found
        /// Created by this app (kept in its store).
        case managed
    }

    public let id: String
    public let kind: Kind
    public let home: URL
    /// `--user-data-dir` for its own window; nil for the standard home (Codex's usual app data).
    public let appDataDir: URL?
}

/// One row of the Codex tab.
public struct CodexAccount: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        case signedIn = "signed_in"
        case signedOut = "signed_out"
    }

    public let id: String
    public let kind: CodexProfile.Kind
    /// Shown everywhere: the user's name for the account, else its default name.
    public let label: String
    public let customName: String?
    /// The email, else "API key", else the folder.
    public let defaultName: String
    /// The home folder, and the same with the user's home shown as `~`.
    public let home: String
    public let homePath: String
    public let identity: CodexIdentity?
    public let state: State
    /// Its open Codex windows (main app processes).
    public let pids: [Int32]

    public var email: String? { identity?.email }

    public init(id: String, kind: CodexProfile.Kind, label: String, customName: String?, defaultName: String, home: String,
                homePath: String, identity: CodexIdentity?, state: State, pids: [Int32]) {
        self.id = id; self.kind = kind; self.label = label; self.customName = customName; self.defaultName = defaultName
        self.home = home; self.homePath = homePath; self.identity = identity; self.state = state; self.pids = pids
    }

    /// Everything the account can be looked up by besides its id.
    var names: [String] { [label, defaultName] + (email.map { [$0] } ?? []) }

    func answers(to name: String) -> Bool {
        let wanted = SwitcherAccount.fold(name)
        return names.contains { SwitcherAccount.fold($0) == wanted }
    }
}

public struct CodexStatus: Codable, Equatable, Sendable {
    public let installed: Bool
    public let version: String?
    public let accounts: [CodexAccount]
    /// Codex homes found on this Mac that aren't in the list yet (they are never opened or signed in to until added).
    public let found: [CodexAccount]
    /// Found homes the user hid or removed from the list (they can be shown again).
    public let hiddenCount: Int

    public var runningCount: Int { accounts.filter { $0.state == .running }.count }

    /// Without the standard home when Codex isn't installed and that home has no sign-in or window: the same
    /// phantom default that never shows a Codex tab, so the command line doesn't list it either.
    public var withoutPhantomDefault: CodexStatus {
        guard !installed else { return self }
        let real = accounts.filter { $0.kind != .standard || $0.identity != nil || !$0.pids.isEmpty }
        return CodexStatus(installed: installed, version: version, accounts: real, found: found, hiddenCount: hiddenCount)
    }

    public init(installed: Bool, version: String?, accounts: [CodexAccount], found: [CodexAccount] = [], hiddenCount: Int) {
        self.installed = installed; self.version = version; self.accounts = accounts; self.found = found
        self.hiddenCount = hiddenCount
    }
}

/// The Codex tab's own records in the store: homes it created, found homes the user added or hid, and names.
struct CodexRegistry: Codable, Equatable, Sendable {
    var managed: [String] = []
    var adopted: [String] = []
    var hidden: [String] = []
    var names: [String: String] = [:]

    init(managed: [String] = [], adopted: [String] = [], hidden: [String] = [], names: [String: String] = [:]) {
        self.managed = managed; self.adopted = adopted; self.hidden = hidden; self.names = names
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managed = try c.decodeIfPresent([String].self, forKey: .managed) ?? []
        adopted = try c.decodeIfPresent([String].self, forKey: .adopted) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
    }

    var isEmpty: Bool { managed.isEmpty && adopted.isEmpty && hidden.isEmpty && names.isEmpty }

    /// Only ids this app could have written: a hand-edited id must never name a folder to trash or open.
    var sanitized: CodexRegistry {
        CodexRegistry(managed: managed.filter(Self.isManagedID), adopted: adopted.filter(Self.isFoundID),
                      hidden: hidden.filter(Self.isFoundID), names: names)
    }

    static func isManagedID(_ id: String) -> Bool {
        id.count == 10 && id.hasPrefix("m-") && id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isFoundID(_ id: String) -> Bool {
        id.hasPrefix("found:") && CodexManager.isCodexHomeName(String(id.dropFirst("found:".count)))
    }
}
