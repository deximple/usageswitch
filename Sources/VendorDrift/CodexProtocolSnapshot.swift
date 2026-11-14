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
        "GetAccountRateLimitsResponse": ["rateLimits", "rateLimitsByLimitId", "accountId", "rateLimitResetCredits"],
        "RateLimitSnapshot": ["primary", "secondary", "planType"],
        "RateLimitWindow": ["usedPercent", "windowDurationMins", "resetsAt"],
        // Reset credits: the count, and the expiry of each credit whose status is `available`.
        "RateLimitResetCreditsSummary": ["availableCount", "credits"],
        "RateLimitResetCredit": ["status", "expiresAt"],
        "RateLimitResetCreditStatus": ["available"],
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
        let requests: [String] = CodexAppContract.requests
            .filter { (method: String) -> Bool in self.requests[method] == nil }
            .map { (method: String) -> String in "request \(method)" }
        let sent: [String] = CodexAppContract.clientNotifications
            .filter { (method: String) -> Bool in clientNotifications[method] == nil }
            .map { (method: String) -> String in "client notification \(method)" }
        let members: [String] = CodexAppContract.members.keys.sorted().flatMap { (type: String) -> [String] in
            let wanted: [String] = CodexAppContract.members[type] ?? []
            let present: [String: String] = types[type] ?? [:]
            let missing: [String] = wanted.filter { (member: String) -> Bool in present[member] == nil }
            return missing.map { (member: String) -> String in "\(type).\(member)" }
        }
        let parts: [[String]] = [requests, sent, members]
        return parts.flatMap { $0 }
    }

    /// Members of the answer types that the app does not read (new vendor fields land here).
    public var unreadByApp: [String] {
        let answerTypes: [String] = CodexAppContract.members.keys.sorted()
            .filter { (type: String) -> Bool in !CodexAppContract.sentTypes.contains(type) }
        return answerTypes.flatMap { (type: String) -> [String] in
            let present: [String: String] = types[type] ?? [:]
            let read: Set<String> = Set(CodexAppContract.members[type] ?? [])
            let unread: [String] = present.keys.filter { (member: String) -> Bool in
                // An enum's other values aren't fields of the answer.
                !read.contains(member) && present[member] != SchemaShape.enumValue
            }
            return unread.sorted().map { (member: String) -> String in "\(type).\(member)" }
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
        let requestChanges: [ProtocolChange] = Self.changes(
            from: requests, to: installed.requests, prefix: "request "
        ) { (kind: ProtocolChange.Kind, method: String, _: String) -> Bool in
            kind != .added && CodexAppContract.requests.contains(method)
        }
        let sentChanges: [ProtocolChange] = Self.changes(
            from: clientNotifications, to: installed.clientNotifications, prefix: "client notification "
        ) { (kind: ProtocolChange.Kind, method: String, _: String) -> Bool in
            kind != .added && CodexAppContract.clientNotifications.contains(method)
        }
        let serverChanges: [ProtocolChange] = Self.changes(
            from: notifications, to: installed.notifications, prefix: "notification "
        ) { (_: ProtocolChange.Kind, _: String, _: String) -> Bool in false }

        let names: [String] = Set(types.keys).union(installed.types.keys).sorted()
        let memberChanges: [ProtocolChange] = names.flatMap { (name: String) -> [ProtocolChange] in
            typeChanges(of: name, to: installed)
        }
        let parts: [[ProtocolChange]] = [requestChanges, sentChanges, serverChanges, memberChanges]
        return parts.flatMap { $0 }
    }

    /// The changes to one type: the whole type appearing or going away, else member by member.
    private func typeChanges(of name: String, to installed: CodexProtocolSnapshot) -> [ProtocolChange] {
        let read: [String]? = CodexAppContract.members[name]
        guard let before: [String: String] = types[name] else {
            let count: Int = installed.types[name]?.count ?? 0
            return [ProtocolChange(kind: .added, path: name, before: nil, after: "\(count) members",
                                   affectsApp: false)]
        }
        guard let after: [String: String] = installed.types[name] else {
            return [ProtocolChange(kind: .removed, path: name, before: "\(before.count) members",
                                   after: nil, affectsApp: read != nil)]
        }
        let isSent: Bool = CodexAppContract.sentTypes.contains(name)
        return Self.changes(from: before, to: after, prefix: "\(name).") {
            (kind: ProtocolChange.Kind, member: String, signature: String) -> Bool in
            // Something it sends now has a member it must carry: new, or turned required.
            let isRequired: Bool = signature.hasSuffix(SchemaShape.requiredSuffix)
            if kind != .removed, isSent, isRequired { return true }
            // Something the app reads went away or changed.
            let isRead: Bool = read?.contains(member) ?? false
            return kind != .added && isRead
        }
    }

    private static func changes(from before: [String: String], to after: [String: String], prefix: String,
                                affectsApp: (ProtocolChange.Kind, String, String) -> Bool) -> [ProtocolChange] {
        let keys: [String] = Set(before.keys).union(after.keys).sorted()
        return keys.compactMap { (key: String) -> ProtocolChange? in
            let old: String? = before[key]
            let new: String? = after[key]
            guard old != new else { return nil }
            let kind: ProtocolChange.Kind
            if old == nil { kind = .added } else if new == nil { kind = .removed } else { kind = .changed }
            let signature: String = new ?? old ?? ""
            return ProtocolChange(kind: kind, path: "\(prefix)\(key)", before: old, after: new,
                                  affectsApp: affectsApp(kind, key, signature))
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
        let accountRequests: [String: String] = requests.filter { (entry: (key: String, value: String)) -> Bool in
            entry.key == "initialize" || entry.key.hasPrefix("account/")
        }
        let accountNotifications: [String: String] = notifications
            .filter { (entry: (key: String, value: String)) -> Bool in entry.key.hasPrefix("account/") }
        return .success(CodexProtocolSnapshot(
            cliVersion: cliVersion, requests: accountRequests, clientNotifications: clientNotifications,
            notifications: accountNotifications, types: types))
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
        var methods: [String: String] = [:]
        for variant in variants {
            let properties: [String: Any] = variant["properties"] as? [String: Any] ?? [:]
            guard let tag = properties["method"] as? [String: Any],
                  let names = tag["enum"] as? [String], let method = names.first, methods[method] == nil
            else { continue }
            var params = "none"
            if let schema = properties["params"] { params = SchemaShape.signature(schema) }
            methods[method] = params
        }
        return methods.isEmpty ? nil : methods
    }

    /// A definition by name: one already seen, else the bundle's own file for it.
    mutating func definition(named name: String) -> Any? {
        if let known = definitions[name] { return known }
        for folder in ["v2/", "v1/", ""] {
            guard var own = object("\(folder)\(name).json") else { continue }
            absorb(own)
            own["definitions"] = nil
            own["$schema"] = nil
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
