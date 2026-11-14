import Foundation
import SwitcherCore

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

    static func claudeStream(_ panel: String) -> [String] {
        let result: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                     "num_turns": 0, "total_cost_usd": 0, "result": panel]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return [#"{"type":"system","subtype":"init","account":"\#(email)"}"#,
                #"{"type":"assistant","message":{"model":"<synthetic>"}}"#, line]
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
        var status: [String: Any] = [
            "loggedIn": loggedIn, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "analyticsDisabled": false, "projectsDirectory": "/Users/someone/.claude/projects",
            "configDirectory": "/Users/someone/.claude", "email": email, "orgId": accountId,
            "orgName": "Someone's Org", "subscriptionType": "max",
        ]
        if let dropped { status[dropped] = nil }
        return String(decoding: try! JSONSerialization.data(withJSONObject: status), as: UTF8.self)
    }

    /// A `codex app-server` exchange whose answer is built from the names in `CodexAppContract`.
    static func codexAnswer(window: [String: Any] = ["usedPercent": 31, "windowDurationMins": 10080,
                                                       "resetsAt": 1_794_301_834]) -> [String] {
        let snapshot: [String: Any] = ["primary": window, "secondary": NSNull(), "planType": "plus",
                                       "limitId": "codex"]
        let answer: [String: Any] = ["id": 2, "result": [
            "rateLimits": snapshot, "rateLimitsByLimitId": ["codex": snapshot, "other-limit": snapshot],
            "accountId": accountId,
        ]]
        return [#"{"id":1,"result":{"userAgent":"usageswitch"}}"#,
                String(decoding: try! JSONSerialization.data(withJSONObject: answer), as: UTF8.self)]
    }

    /// The smallest schema bundle `CodexProtocolSnapshot.read` understands, written the way
    /// `codex app-server generate-json-schema --out` lays it out. `edit` changes it first.
    static func writeSchema(to directory: URL, edit: (inout [String: [String: Any]]) -> Void = { _ in }) {
        func reference(_ name: String) -> [String: Any] { ["$ref": "#/definitions/\(name)"] }
        func method(_ name: String, _ params: Any) -> [String: Any] {
            ["properties": ["method": ["enum": [name], "type": "string"], "params": params]]
        }
        let window: [String: Any] = [
            "type": "object", "required": ["usedPercent"],
            "properties": ["usedPercent": ["type": "integer", "format": "int32"],
                           "windowDurationMins": ["type": ["integer", "null"], "format": "int64"],
                           "resetsAt": ["type": ["integer", "null"], "format": "int64"]],
        ]
        let nullableWindow: [String: Any] = ["anyOf": [reference("RateLimitWindow"), ["type": "null"]]]
        let snapshot: [String: Any] = [
            "type": "object",
            "properties": ["primary": nullableWindow, "secondary": nullableWindow,
                           "planType": ["anyOf": [reference("PlanType"), ["type": "null"]]],
                           "limitId": ["type": ["string", "null"]]],
        ]
        let shared: [String: Any] = [
            "RateLimitWindow": window, "RateLimitSnapshot": snapshot,
            "PlanType": ["enum": ["free", "plus", "pro"], "type": "string"],
            "ClientInfo": ["type": "object", "required": ["name", "version"],
                           "properties": ["name": ["type": "string"], "version": ["type": "string"]]],
            "InitializeParams": ["type": "object", "required": ["clientInfo"],
                                 "properties": ["clientInfo": reference("ClientInfo")]],
            "GetAccountRateLimitsParams": ["type": "object",
                                           "properties": ["excludeResetCreditDetails": ["type": "boolean"]]],
            "ConsumeAccountRateLimitResetCreditParams": [
                "type": "object", "required": ["idempotencyKey"],
                "properties": ["idempotencyKey": ["type": "string"]]],
        ]
        var files: [String: [String: Any]] = [
            "ClientRequest.json": ["definitions": shared, "oneOf": [
                method("initialize", reference("InitializeParams")),
                method("account/rateLimits/read",
                       ["anyOf": [reference("GetAccountRateLimitsParams"), ["type": "null"]]]),
                method("account/rateLimitResetCredit/consume",
                       reference("ConsumeAccountRateLimitResetCreditParams")),
                method("thread/start", ["type": "null"]),
            ]],
            "ClientNotification.json": ["oneOf": [
                ["properties": ["method": ["enum": ["initialized"], "type": "string"]], "required": ["method"]],
            ]],
            "ServerNotification.json": ["definitions": shared, "oneOf": [
                method("account/rateLimits/updated", reference("AccountRateLimitsUpdatedNotification")),
                method("thread/started", ["type": "null"]),
            ]],
            "v2/GetAccountRateLimitsResponse.json": [
                "definitions": shared, "type": "object", "required": ["rateLimits"],
                "properties": ["rateLimits": ["allOf": [reference("RateLimitSnapshot")]],
                               "rateLimitsByLimitId": ["type": ["object", "null"],
                                                       "additionalProperties": reference("RateLimitSnapshot")],
                               "accountId": ["type": ["string", "null"]]]],
            "JSONRPCErrorError.json": [
                "type": "object", "required": ["code", "message"],
                "properties": ["code": ["type": "integer", "format": "int64"],
                               "message": ["type": "string"], "data": true]],
        ]
        edit(&files)
        for (name, content) in files {
            let file = directory.appendingPathComponent(name)
            try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try! JSONSerialization.data(withJSONObject: content).write(to: file)
        }
    }
}
