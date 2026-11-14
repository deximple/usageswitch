import Foundation
import Testing
@testable import SwitcherCore
@testable import VendorDrift

@Suite("Codex protocol snapshot")
struct CodexProtocolSnapshotTests {
    private func snapshot(version: String? = "1.2.3",
                          edit: (inout [String: [String: Any]]) -> Void = { _ in }) -> CodexProtocolSnapshot {
        let folder = TempFolder()
        Sample.writeSchema(to: folder.url, edit: edit)
        return try! CodexProtocolSnapshot.read(schemaDirectory: folder.url, cliVersion: version).get()
    }

    /// Changes `definition` wherever the bundle carries it.
    private func editing(_ definition: String, _ change: @escaping (inout [String: Any]) -> Void)
        -> (inout [String: [String: Any]]) -> Void {
        { files in
            for name in files.keys {
                guard var definitions = files[name]?["definitions"] as? [String: Any],
                      var target = definitions[definition] as? [String: Any] else { continue }
                change(&target)
                definitions[definition] = target
                files[name]?["definitions"] = definitions
            }
        }
    }

    private func properties(_ definition: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var properties = definition["properties"] as? [String: Any] ?? [:]
        change(&properties)
        definition["properties"] = properties
    }

    @Test("reads the account methods and the frozen types with everything they reference")
    func reading() {
        let snapshot = snapshot()
        #expect(snapshot.cliVersion == "1.2.3")
        #expect(snapshot.requests == [
            "initialize": "InitializeParams",
            "account/rateLimits/read": "GetAccountRateLimitsParams | null",
            "account/rateLimitResetCredit/consume": "ConsumeAccountRateLimitResetCreditParams",
        ])
        #expect(snapshot.clientNotifications == ["initialized": "none"])
        #expect(snapshot.notifications == ["account/rateLimits/updated": "AccountRateLimitsUpdatedNotification"])
        #expect(snapshot.missingFromContract.isEmpty)
        #expect(snapshot.types["RateLimitWindow"] == [
            "usedPercent": "integer<int32> (required)", "windowDurationMins": "integer<int64> | null",
            "resetsAt": "integer<int64> | null",
        ])
        #expect(snapshot.types["GetAccountRateLimitsResponse"]?["rateLimitsByLimitId"]
            == "{(any other key): RateLimitSnapshot} | null")
        // Referenced from a root, not a root itself.
        #expect(snapshot.types["PlanType"] == ["free": "enum value", "plus": "enum value", "pro": "enum value"])
        #expect(snapshot.types["ClientInfo"] != nil)
        // A root this bundle doesn't define is simply absent.
        #expect(snapshot.types["GetAccountResponse"] == nil)
    }

    @Test("a bundle without its request or notification file is unreadable")
    func unreadableBundle() {
        let noClient = TempFolder()
        Sample.writeSchema(to: noClient.url) { $0["ClientNotification.json"] = nil }
        #expect(CodexProtocolSnapshot.read(schemaDirectory: noClient.url, cliVersion: nil)
            == .failure(.unreadable("ClientNotification.json")))
        let empty = TempFolder()
        #expect(CodexProtocolSnapshot.read(schemaDirectory: empty.url, cliVersion: nil)
            == .failure(.unreadable("ClientRequest.json")))
        let half = TempFolder()
        Sample.writeSchema(to: half.url) { $0["ServerNotification.json"] = ["oneOf": []] }
        #expect(CodexProtocolSnapshot.read(schemaDirectory: half.url, cliVersion: nil)
            == .failure(.unreadable("ServerNotification.json")))
        let garbage = TempFolder()
        garbage.write("not json", to: "ClientRequest.json")
        #expect(CodexProtocolSnapshot.read(schemaDirectory: garbage.url, cliVersion: nil)
            == .failure(.unreadable("ClientRequest.json")))
    }

    @Test("the same bundle has no changes")
    func noChanges() {
        #expect(snapshot().changes(to: snapshot(version: "9.9.9")).isEmpty)
    }

    @Test("a new answer field is a change the app does not read")
    func addedField() {
        let installed = snapshot(edit: editing("RateLimitSnapshot") { definition in
            self.properties(&definition) { $0["rateLimitReachedType"] = ["type": ["string", "null"]] }
        })
        #expect(snapshot().changes(to: installed) == [
            ProtocolChange(kind: .added, path: "RateLimitSnapshot.rateLimitReachedType", before: nil,
                           after: "string | null", affectsApp: false),
        ])
    }

    @Test("removing or retyping a field the parser reads affects the app")
    func readFieldChanges() {
        let removed = snapshot(edit: editing("RateLimitWindow") { definition in
            self.properties(&definition) { $0["resetsAt"] = nil }
        })
        #expect(snapshot().changes(to: removed) == [
            ProtocolChange(kind: .removed, path: "RateLimitWindow.resetsAt", before: "integer<int64> | null",
                           after: nil, affectsApp: true),
        ])
        let retyped = snapshot(edit: editing("RateLimitWindow") { definition in
            self.properties(&definition) { $0["usedPercent"] = ["type": "number", "format": "double"] }
        })
        #expect(snapshot().changes(to: retyped) == [
            ProtocolChange(kind: .changed, path: "RateLimitWindow.usedPercent",
                           before: "integer<int32> (required)", after: "number<double> (required)",
                           affectsApp: true),
        ])
    }

    @Test("removing or retyping a field the parser ignores does not affect the app")
    func unreadFieldChanges() {
        let installed = snapshot(edit: editing("RateLimitSnapshot") { definition in
            self.properties(&definition) { $0["limitId"] = nil }
        })
        #expect(snapshot().changes(to: installed).map(\.affectsApp) == [false])
    }

    @Test("a new required member of something the app sends affects the app; an optional one does not")
    func sentTypeChanges() {
        let required = snapshot(edit: editing("ClientInfo") { definition in
            self.properties(&definition) { $0["build"] = ["type": "string"] }
            definition["required"] = ["name", "version", "build"]
        })
        #expect(snapshot().changes(to: required) == [
            ProtocolChange(kind: .added, path: "ClientInfo.build", before: nil, after: "string (required)",
                           affectsApp: true),
        ])
        // An optional member the app doesn't send turning required breaks the request too.
        let withOptional = editing("InitializeParams") { definition in
            self.properties(&definition) { $0["capabilities"] = ["type": ["object", "null"]] }
        }
        let turnedRequired = snapshot(edit: editing("InitializeParams") { definition in
            self.properties(&definition) { $0["capabilities"] = ["type": "object"] }
            definition["required"] = ["clientInfo", "capabilities"]
        })
        #expect(snapshot(edit: withOptional).changes(to: turnedRequired) == [
            ProtocolChange(kind: .changed, path: "InitializeParams.capabilities", before: "object | null",
                           after: "object (required)", affectsApp: true),
        ])
        // …while one that only changes type and stays optional does not.
        let retypedOptional = snapshot(edit: editing("InitializeParams") { definition in
            self.properties(&definition) { $0["capabilities"] = ["type": ["string", "null"]] }
        })
        #expect(snapshot(edit: withOptional).changes(to: retypedOptional).map(\.affectsApp) == [false])
        let optional = snapshot(edit: editing("GetAccountRateLimitsParams") { definition in
            self.properties(&definition) { $0["supportsReserve"] = ["type": "boolean"] }
        })
        #expect(snapshot().changes(to: optional).map(\.affectsApp) == [false])
        // The same new required member on an answer type is not the app's problem.
        let answer = snapshot(edit: editing("RateLimitWindow") { definition in
            self.properties(&definition) { $0["extra"] = ["type": "string"] }
            definition["required"] = ["usedPercent", "extra"]
        })
        #expect(snapshot().changes(to: answer).map(\.affectsApp) == [false])
    }

    @Test("a request the app sends going away or changing affects the app; other methods do not")
    func methodChanges() {
        let installed = snapshot { files in
            var requests = files["ClientRequest.json"]?["oneOf"] as? [[String: Any]] ?? []
            requests.removeAll { (request: [String: Any]) -> Bool in
                "\(request)".contains("account/rateLimits/read")
            }
            let added: [String: Any] = ["enum": ["account/securitySetup/read"] as [String]]
            requests.append(["properties": ["method": added] as [String: Any]])
            files["ClientRequest.json"]?["oneOf"] = requests
            let updated: [String: Any] = ["enum": ["account/updated"] as [String]]
            let noParams: [String: Any] = ["type": "null"]
            let server: [String: Any] = ["properties": ["method": updated, "params": noParams] as [String: Any]]
            files["ServerNotification.json"]?["oneOf"] = [server]
            let ready: [String: Any] = ["enum": ["ready"] as [String]]
            let client: [String: Any] = ["properties": ["method": ready] as [String: Any]]
            files["ClientNotification.json"]?["oneOf"] = [client]
        }
        #expect(snapshot().changes(to: installed) == [
            ProtocolChange(kind: .removed, path: "request account/rateLimits/read",
                           before: "GetAccountRateLimitsParams | null", after: nil, affectsApp: true),
            ProtocolChange(kind: .added, path: "request account/securitySetup/read", before: nil,
                           after: "none", affectsApp: false),
            ProtocolChange(kind: .removed, path: "client notification initialized", before: "none",
                           after: nil, affectsApp: true),
            ProtocolChange(kind: .added, path: "client notification ready", before: nil, after: "none",
                           affectsApp: false),
            ProtocolChange(kind: .removed, path: "notification account/rateLimits/updated",
                           before: "AccountRateLimitsUpdatedNotification", after: nil, affectsApp: false),
            ProtocolChange(kind: .added, path: "notification account/updated", before: nil,
                           after: "null", affectsApp: false),
        ])
    }

    @Test("a whole type appearing or going away is one change")
    func wholeTypeChanges() {
        var installed = snapshot()
        installed.types["RateLimitWindow"] = nil
        installed.types["PlanType"] = nil
        installed.types["Brand New"] = ["a": "string", "b": "string"]
        #expect(snapshot().changes(to: installed) == [
            ProtocolChange(kind: .added, path: "Brand New", before: nil, after: "2 members", affectsApp: false),
            ProtocolChange(kind: .removed, path: "PlanType", before: "3 members", after: nil, affectsApp: false),
            ProtocolChange(kind: .removed, path: "RateLimitWindow", before: "3 members", after: nil,
                           affectsApp: true),
        ])
    }

    @Test("names what the app sends or reads that a snapshot lacks")
    func missingFromContract() {
        var partial = snapshot()
        partial.requests["account/rateLimits/read"] = nil
        partial.clientNotifications = [:]
        partial.types["RateLimitWindow"] = nil
        partial.types["ClientInfo"]?["version"] = nil
        #expect(partial.missingFromContract == [
            "request account/rateLimits/read", "client notification initialized", "ClientInfo.version",
            "RateLimitWindow.usedPercent", "RateLimitWindow.windowDurationMins", "RateLimitWindow.resetsAt",
        ])
    }

    @Test("lists the answer fields the app does not read, never what it sends")
    func unreadByApp() {
        #expect(snapshot().unreadByApp == ["JSONRPCErrorError.data", "RateLimitSnapshot.limitId"])
    }

    @Test("the JSON form round-trips and is stable")
    func jsonRoundTrip() {
        let snapshot = snapshot()
        #expect(CodexProtocolSnapshot(json: snapshot.json()) == snapshot)
        #expect(snapshot.json() == snapshot.json())
        #expect(CodexProtocolSnapshot(json: Data("{}".utf8)) == nil)
    }

    // MARK: - The contract list against the app's own code

    /// An answer holding one view of the limits, optionally with one contract member turned
    /// into something the parser can't accept.
    private func answer(view: String, corrupting: (type: String, member: String)? = nil) -> [String] {
        func corrupt(_ type: String, _ object: [String: Any]) -> [String: Any] {
            guard let corrupting, corrupting.type == type else { return object }
            return object.merging([corrupting.member: ["unexpected": true]]) { _, new in new }
        }
        let plainWindow: [String: Any] = ["usedPercent": 31, "windowDurationMins": 10080,
                                          "resetsAt": 1_794_301_834]
        let window = corrupt("RateLimitWindow", plainWindow)
        let plainLimits: [String: Any] = ["primary": window, "secondary": window, "planType": "plus"]
        let limits = corrupt("RateLimitSnapshot", plainLimits)
        let byLimit: [String: Any] = ["codex": limits]
        let plainResult: [String: Any] = [
            view: view == "rateLimits" ? limits : byLimit, "accountId": Sample.accountId,
        ]
        let result = corrupt("GetAccountRateLimitsResponse", plainResult)
        let message: [String: Any] = ["id": CodexRateLimitsParser.answerID, "result": result]
        return [String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)]
    }

    @Test("every answer member in the contract is one the app's parser actually reads",
          arguments: ["rateLimits", "rateLimitsByLimitId"])
    func contractMatchesParser(view: String) throws {
        let intact = CodexRateLimitsParser.read(answer(view: view))
        #expect(try intact.get().windows.count == 2)
        let other = view == "rateLimits" ? "rateLimitsByLimitId" : "rateLimits"
        for type in ["GetAccountRateLimitsResponse", "RateLimitSnapshot", "RateLimitWindow"] {
            for member in try #require(CodexAppContract.members[type]) where member != other {
                #expect(CodexRateLimitsParser.read(answer(view: view, corrupting: (type, member))) != intact,
                        "\(type).\(member) is listed but the parser ignores it")
            }
        }
    }

    @Test("the contract names what the app's collector sends")
    func contractMatchesCollector() throws {
        let sent = CodexUsageCollector.stdinLines(version: "1.0").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let requests = sent.filter { $0["id"] != nil }
        #expect(requests.compactMap { $0["method"] as? String } == CodexAppContract.requests)
        #expect(sent.filter { $0["id"] == nil }.compactMap { $0["method"] as? String }
            == CodexAppContract.clientNotifications)
        let initialize = try #require(requests.first?["params"] as? [String: Any])
        #expect(Array(initialize.keys) == CodexAppContract.members["InitializeParams"])
        #expect(Set(try #require(initialize["clientInfo"] as? [String: Any]).keys)
            == Set(try #require(CodexAppContract.members["ClientInfo"])))
        let read = try #require(requests.last?["params"] as? [String: Any])
        #expect(Array(read.keys) == CodexAppContract.members["GetAccountRateLimitsParams"])
        // The reset-credit request spends a credit: it must never be among what is sent.
        #expect(!sent.contains { $0["method"] as? String == CodexAppContract.neverCalled })
    }

    @Test("the snapshot kept in the repository covers everything in the contract")
    func repositorySnapshot() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/vendor-drift/codex-protocol.snapshot.json")
        let frozen = try #require(CodexProtocolSnapshot(json: try Data(contentsOf: file)))
        #expect(frozen.cliVersion != nil)
        #expect(frozen.missingFromContract == [])
        // Tracked so a change to it shows up; never sent.
        #expect(frozen.requests[CodexAppContract.neverCalled] != nil)
    }
}
