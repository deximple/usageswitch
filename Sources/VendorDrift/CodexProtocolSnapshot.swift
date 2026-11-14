import Foundation

/// What `CodexUsageCollector` sends and `CodexRateLimitsParser` reads from `codex app-server`.
/// A unit test builds an answer from exactly these names and checks the app's parser reads it,
/// so this list can't drift from the parser unnoticed.
public enum CodexAppContract {
    public static let requests = ["initialize", "account/rateLimits/read"]
    /// The notification the app sends between the two.
    public static let clientNotifications = ["initialized"]
    /// Types the app sends: a new required member there breaks the request.
    public static let sentTypes: Set<String> = ["InitializeParams", "ClientInfo", "GetAccountRateLimitsParams"]
    public static let members: [String: [String]] = [
        "InitializeParams": ["clientInfo"],
        "ClientInfo": ["name", "version"],
        "GetAccountRateLimitsParams": ["excludeResetCreditDetails"],
        "GetAccountRateLimitsResponse": ["rateLimits", "rateLimitsByLimitId", "accountId"],
        "RateLimitSnapshot": ["primary", "secondary", "planType"],
        "RateLimitWindow": ["usedPercent", "windowDurationMins", "resetsAt"],
        "JSONRPCErrorError": ["code", "message"],
    ]
    /// Tracked for its shape only. Nothing here ever calls it: it spends a reset credit.
    static let neverCalled = "account/rateLimitResetCredit/consume"

    /// The types whose shape is frozen, together with everything they reference.
    static let roots = [
        "InitializeParams", "InitializeResponse", "GetAccountRateLimitsParams",
        "GetAccountRateLimitsResponse", "AccountRateLimitsUpdatedNotification",
        "GetAccountParams", "GetAccountResponse", "ConsumeAccountRateLimitResetCreditParams",
        "ConsumeAccountRateLimitResetCreditResponse", "JSONRPCErrorError",
    ]
}

/// The part of the `codex app-server` protocol UsageSwitch depends on, as flat shape strings.
/// Schema only: it is generated from the CLI's own type definitions and holds no account data.
public struct CodexProtocolSnapshot: Codable, Equatable, Sendable {
    /// `codex --version` of the CLI the schema came from.
    public var cliVersion: String?
    /// Client request method → params signature: `initialize` and every `account/*` method.
    public var requests: [String: String]
    /// Client notification method → params signature: all of them.
    public var clientNotifications: [String: String]
    /// Server notification method → params signature: every `account/*` notification.
    public var notifications: [String: String]
    /// Type name → member → signature, for the frozen roots and everything they reference.
    public var types: [String: [String: String]]

    public init(cliVersion: String?, requests: [String: String], clientNotifications: [String: String],
                notifications: [String: String], types: [String: [String: String]]) {
        self.cliVersion = cliVersion; self.requests = requests
        self.clientNotifications = clientNotifications
        self.notifications = notifications; self.types = types
    }

    public init?(json: Data) {
        guard let snapshot = try? JSONDecoder().decode(CodexProtocolSnapshot.self, from: json) else { return nil }
        self = snapshot
    }

    /// Stable text for the repository: sorted keys, one member per line.
    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// What the app sends or reads that this snapshot doesn't have. A snapshot with anything
    /// here came from a schema this reader no longer follows, and must not be frozen.
    public var missingFromContract: [String] {
        CodexAppContract.requests.filter { requests[$0] == nil }.map { "request \($0)" }
            + CodexAppContract.clientNotifications.filter { clientNotifications[$0] == nil }
                .map { "client notification \($0)" }
            + CodexAppContract.members.keys.sorted().flatMap { type in
                (CodexAppContract.members[type] ?? []).filter { types[type]?[$0] == nil }.map { "\(type).\($0)" }
            }
    }

    /// Members of the answer types that the app does not read (new vendor fields land here).
    public var unreadByApp: [String] {
        CodexAppContract.members.keys.sorted()
            .filter { !CodexAppContract.sentTypes.contains($0) }
            .flatMap { type in
                Set((types[type] ?? [:]).keys).subtracting(CodexAppContract.members[type] ?? [])
                    .sorted().map { "\(type).\($0)" }
            }
    }
}

public struct ProtocolChange: Equatable, Sendable {
    public enum Kind: String, Sendable { case added, removed, changed }

    public let kind: Kind
    /// `request <method>`, `notification <method>`, `<Type>.<member>`, or a whole type's name.
    public let path: String
    public let before: String?
    public let after: String?
    /// The change touches something the app's Codex reader sends or reads.
    public let affectsApp: Bool
}

extension CodexProtocolSnapshot {
    /// Everything that differs between this (frozen) snapshot and the installed CLI's, by path.
    public func changes(to installed: CodexProtocolSnapshot) -> [ProtocolChange] {
        let methods = Self.changes(from: requests, to: installed.requests, prefix: "request ") { kind, method, _ in
            kind != .added && CodexAppContract.requests.contains(method)
        } + Self.changes(from: clientNotifications, to: installed.clientNotifications,
                         prefix: "client notification ") { kind, method, _ in
            kind != .added && CodexAppContract.clientNotifications.contains(method)
        } + Self.changes(from: notifications, to: installed.notifications, prefix: "notification ") { _, _, _ in false }

        let names = Set(types.keys).union(installed.types.keys).sorted()
        let members = names.flatMap { name -> [ProtocolChange] in
            let read = CodexAppContract.members[name]
            guard let before = types[name] else {
                return [ProtocolChange(kind: .added, path: name, before: nil,
                                       after: "\(installed.types[name]?.count ?? 0) members", affectsApp: false)]
            }
            guard let after = installed.types[name] else {
                return [ProtocolChange(kind: .removed, path: name, before: "\(before.count) members",
                                       after: nil, affectsApp: read != nil)]
            }
            return Self.changes(from: before, to: after, prefix: "\(name).") { kind, member, signature in
                // Something the app reads went away or changed; or something it sends now has
                // a member it must carry (new, or turned from optional to required).
                let mustBeSent = kind != .removed && CodexAppContract.sentTypes.contains(name)
                    && signature.hasSuffix(SchemaShape.requiredSuffix)
                return mustBeSent || (kind != .added && read?.contains(member) ?? false)
            }
        }
        return methods + members
    }

    private static func changes(from before: [String: String], to after: [String: String], prefix: String,
                                affectsApp: (ProtocolChange.Kind, String, String) -> Bool) -> [ProtocolChange] {
        Set(before.keys).union(after.keys).sorted().compactMap { key in
            let (old, new) = (before[key], after[key])
            guard old != new else { return nil }
            let kind: ProtocolChange.Kind = old == nil ? .added : new == nil ? .removed : .changed
            return ProtocolChange(kind: kind, path: prefix + key, before: old, after: new,
                                  affectsApp: affectsApp(kind, key, new ?? old ?? ""))
        }
    }
}

extension CodexProtocolSnapshot {
    public enum ReadFailure: Error, Equatable {
        /// A file of the bundle is missing or isn't the JSON this reader knows.
        case unreadable(String)
    }

    /// Reads the bundle `codex app-server generate-json-schema --out <directory>` wrote.
    public static func read(schemaDirectory: URL, cliVersion: String?) -> Result<CodexProtocolSnapshot, ReadFailure> {
        var bundle = SchemaBundle(directory: schemaDirectory)
        guard let requests = bundle.methods(in: "ClientRequest.json") else {
            return .failure(.unreadable("ClientRequest.json"))
        }
        guard let clientNotifications = bundle.methods(in: "ClientNotification.json") else {
            return .failure(.unreadable("ClientNotification.json"))
        }
        guard let notifications = bundle.methods(in: "ServerNotification.json") else {
            return .failure(.unreadable("ServerNotification.json"))
        }
        var types: [String: [String: String]] = [:]
        var pending = CodexAppContract.roots
        while let name = pending.popLast() {
            guard types[name] == nil, let definition = bundle.definition(named: name) else { continue }
            types[name] = SchemaShape.members(of: definition)
            pending += SchemaShape.references(in: definition).sorted()
        }
        return .success(CodexProtocolSnapshot(
            cliVersion: cliVersion,
            requests: requests.filter { $0.key == "initialize" || $0.key.hasPrefix("account/") },
            clientNotifications: clientNotifications,
            notifications: notifications.filter { $0.key.hasPrefix("account/") },
            types: types))
    }
}

/// The schema files of one bundle, with the definitions seen so far.
private struct SchemaBundle {
    let directory: URL
    private var definitions: [String: Any] = [:]

    init(directory: URL) { self.directory = directory }

    /// Method name → params signature of a tagged request/notification union file.
    mutating func methods(in file: String) -> [String: String]? {
        guard let root = object(file), let variants = root["oneOf"] as? [[String: Any]] else { return nil }
        absorb(root)
        let pairs = variants.compactMap { variant -> (String, String)? in
            let properties = variant["properties"] as? [String: Any] ?? [:]
            guard let method = ((properties["method"] as? [String: Any])?["enum"] as? [String])?.first
            else { return nil }
            return (method, properties["params"].map(SchemaShape.signature) ?? "none")
        }
        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// A definition by name: one already seen, else the bundle's own file for it.
    mutating func definition(named name: String) -> Any? {
        if let known = definitions[name] { return known }
        for folder in ["v2/", "v1/", ""] {
            guard let root = object("\(folder)\(name).json") else { continue }
            absorb(root)
            let own = root.filter { $0.key != "definitions" && $0.key != "$schema" }
            definitions[name] = own
            return own
        }
        return nil
    }

    private mutating func absorb(_ root: [String: Any]) {
        for (name, definition) in root["definitions"] as? [String: Any] ?? [:] where definitions[name] == nil {
            definitions[name] = definition
        }
    }

    private func object(_ file: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
