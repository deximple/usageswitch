import Foundation
import SwitcherCore

/// The first bytes of a Mach-O file: what a fake CLI starts with so it isn't taken for a script.
let machOMagic: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]

/// Bytes followed by text, as one file's content.
func bytes(_ prefix: [UInt8], then text: String = "") -> Data {
    var data = Data(prefix)
    data.append(Data(text.utf8))
    return data
}

/// A throwaway folder under the temporary directory, removed when the test ends.
final class TempFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vendor-drift-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ text: String, to path: String, executable: Bool = false) -> URL {
        write(Data(text.utf8), to: path, executable: executable)
    }

    @discardableResult
    func write(_ data: Data, to path: String, executable: Bool = false) -> URL {
        let file = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! data.write(to: file)
        try! FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                               ofItemAtPath: file.path)
        return file
    }

    func folder(_ path: String) -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Answers every run from a closure and remembers what was asked. Never starts a process.
final class FakeRunner: UsageProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [UsageProcessRequest] = []
    private let respond: @Sendable (UsageProcessRequest) -> UsageProcessResult

    init(_ respond: @escaping @Sendable (UsageProcessRequest) -> UsageProcessResult) { self.respond = respond }

    func run(_ request: UsageProcessRequest) -> UsageProcessResult {
        lock.lock(); asked.append(request); lock.unlock()
        return respond(request)
    }

    var requests: [UsageProcessRequest] { lock.lock(); defer { lock.unlock() }; return asked }
}

enum Sample {
    /// A made-up account, so a leak into a report is easy to spot.
    static let email = "someone@example.com"
    static let accountId = "11111111-2222-3333-4444-555555555555"

    private static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func claudeStream(_ panel: String) -> [String] {
        let result: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                     "num_turns": 0, "total_cost_usd": 0, "result": panel]
        let initLine = #"{"type":"system","subtype":"init","account":"\#(email)"}"#
        let assistant = #"{"type":"assistant","message":{"model":"<synthetic>"}}"#
        return [initLine, assistant, line(result)]
    }

    static let claudePanel = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 40% used · resets 7:40pm (Asia/Seoul)
        Current week (all models): 75% used · resets Nov 6 at 12:59pm (Asia/Seoul)
        Current week (Fable): 3% used · resets Nov 6 at 12:59pm (Asia/Seoul)

        What's contributing to your usage?
        Last 24h · 3152 requests · 45 sessions
          89%  Start fresh when you switch tasks · run /clear
        Top MCP servers: private-server 12%
        """

    static func authStatus(loggedIn: Bool = true, dropping dropped: String? = nil) -> String {
        var status: [String: Any] = [:]
        status["loggedIn"] = loggedIn
        status["authMethod"] = "claude.ai"
        status["apiProvider"] = "firstParty"
        status["analyticsDisabled"] = false
        status["projectsDirectory"] = "/Users/someone/.claude/projects"
        status["configDirectory"] = "/Users/someone/.claude"
        status["email"] = email
        status["orgId"] = accountId
        status["orgName"] = "Someone's Org"
        status["subscriptionType"] = "max"
        if let dropped { status[dropped] = nil }
        return line(status)
    }

    static var defaultWindow: [String: Any] {
        ["usedPercent": 31, "windowDurationMins": 10080, "resetsAt": 1_794_301_834]
    }

    /// A `codex app-server` exchange whose answer is built from the names in `CodexAppContract`.
    static func codexAnswer(window: [String: Any] = defaultWindow) -> [String] {
        var snapshot: [String: Any] = [:]
        snapshot["primary"] = window
        snapshot["secondary"] = NSNull()
        snapshot["planType"] = "plus"
        snapshot["limitId"] = "codex"
        let byLimit: [String: Any] = ["codex": snapshot, "other-limit": snapshot]
        var result: [String: Any] = [:]
        result["rateLimits"] = snapshot
        result["rateLimitsByLimitId"] = byLimit
        result["accountId"] = accountId
        let answer: [String: Any] = ["id": 2, "result": result]
        return [#"{"id":1,"result":{"userAgent":"usageswitch"}}"#, line(answer)]
    }

    // MARK: - A schema bundle

    private static func reference(_ name: String) -> [String: Any] { ["$ref": "#/definitions/\(name)"] }

    private static func type(_ name: String) -> [String: Any] { ["type": name] }

    private static func nullable(_ name: String, format: String? = nil) -> [String: Any] {
        let names: [String] = [name, "null"]
        var schema: [String: Any] = ["type": names]
        if let format { schema["format"] = format }
        return schema
    }

    private static func orNull(_ schema: [String: Any]) -> [String: Any] {
        let alternatives: [[String: Any]] = [schema, type("null")]
        return ["anyOf": alternatives]
    }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func method(_ name: String, _ params: [String: Any]) -> [String: Any] {
        let names: [String] = [name]
        let tag: [String: Any] = ["enum": names, "type": "string"]
        let properties: [String: Any] = ["method": tag, "params": params]
        return ["properties": properties]
    }

    private static var sharedDefinitions: [String: Any] {
        var window: [String: Any] = [:]
        window["usedPercent"] = ["type": "integer", "format": "int32"] as [String: Any]
        window["windowDurationMins"] = nullable("integer", format: "int64")
        window["resetsAt"] = nullable("integer", format: "int64")

        var snapshot: [String: Any] = [:]
        snapshot["primary"] = orNull(reference("RateLimitWindow"))
        snapshot["secondary"] = orNull(reference("RateLimitWindow"))
        snapshot["planType"] = orNull(reference("PlanType"))
        snapshot["limitId"] = nullable("string")

        let plans: [String] = ["free", "plus", "pro"]
        let clientInfo: [String: Any] = ["name": type("string"), "version": type("string")]
        let initialize: [String: Any] = ["clientInfo": reference("ClientInfo")]
        let readParams: [String: Any] = ["excludeResetCreditDetails": type("boolean")]
        let consumeParams: [String: Any] = ["idempotencyKey": type("string")]

        var shared: [String: Any] = [:]
        shared["RateLimitWindow"] = object(window, required: ["usedPercent"])
        shared["RateLimitSnapshot"] = object(snapshot)
        shared["PlanType"] = ["enum": plans, "type": "string"] as [String: Any]
        shared["ClientInfo"] = object(clientInfo, required: ["name", "version"])
        shared["InitializeParams"] = object(initialize, required: ["clientInfo"])
        shared["GetAccountRateLimitsParams"] = object(readParams)
        shared["ConsumeAccountRateLimitResetCreditParams"] = object(consumeParams, required: ["idempotencyKey"])
        return shared
    }

    /// The smallest schema bundle `CodexProtocolSnapshot.read` understands, written the way
    /// `codex app-server generate-json-schema --out` lays it out. `edit` changes it first.
    static func writeSchema(to directory: URL, edit: (inout [String: [String: Any]]) -> Void = { _ in }) {
        let shared: [String: Any] = sharedDefinitions
        let requests: [[String: Any]] = [
            method("initialize", reference("InitializeParams")),
            method("account/rateLimits/read", orNull(reference("GetAccountRateLimitsParams"))),
            method("account/rateLimitResetCredit/consume", reference("ConsumeAccountRateLimitResetCreditParams")),
            method("thread/start", type("null")),
        ]
        let initializedTag: [String: Any] = ["enum": ["initialized"] as [String], "type": "string"]
        let initialized: [String: Any] = ["properties": ["method": initializedTag] as [String: Any],
                                          "required": ["method"] as [String]]
        let clientNotifications: [[String: Any]] = [initialized]
        let serverNotifications: [[String: Any]] = [
            method("account/rateLimits/updated", reference("AccountRateLimitsUpdatedNotification")),
            method("thread/started", type("null")),
        ]

        var byLimit: [String: Any] = nullable("object")
        byLimit["additionalProperties"] = reference("RateLimitSnapshot")
        var answer: [String: Any] = [:]
        answer["rateLimits"] = ["allOf": [reference("RateLimitSnapshot")] as [[String: Any]]] as [String: Any]
        answer["rateLimitsByLimitId"] = byLimit
        answer["accountId"] = nullable("string")
        var response: [String: Any] = object(answer, required: ["rateLimits"])
        response["definitions"] = shared

        var errorMembers: [String: Any] = [:]
        errorMembers["code"] = ["type": "integer", "format": "int64"] as [String: Any]
        errorMembers["message"] = type("string")
        errorMembers["data"] = true

        var files: [String: [String: Any]] = [:]
        files["ClientRequest.json"] = ["definitions": shared, "oneOf": requests]
        files["ClientNotification.json"] = ["oneOf": clientNotifications]
        files["ServerNotification.json"] = ["definitions": shared, "oneOf": serverNotifications]
        files["v2/GetAccountRateLimitsResponse.json"] = response
        files["JSONRPCErrorError.json"] = object(errorMembers, required: ["code", "message"])
        edit(&files)
        for (name, content) in files {
            let file: URL = directory.appendingPathComponent(name)
            try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try! JSONSerialization.data(withJSONObject: content).write(to: file)
        }
    }
}
