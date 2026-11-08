import Foundation

/// Antigravity usage adapter. The endpoint and response fields are inferred from
/// strings in the agy binary, not from a published API contract.
public struct AntigravityUsageCollector: Sendable {
    public static let rowID = "antigravity:current"
    public static let rowAccountRef = "current"
    private static let assistURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let modelsURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let home: URL
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.credentials = credentials
        self.home = home; self.now = now
    }

    private func token() -> String? {
        guard let data = credentials.read(home.appendingPathComponent(
            ".gemini/jetski-standalone-oauth-token")),
              let object = UsageJSON.object(data),
              let token = object["token"] as? [String: Any],
              let expiry = UsageJSON.expiryDate(token["expiry"]),
              expiry > now(),
              let accessToken = UsageJSON.token(token["access_token"])
        else { return nil }
        return accessToken
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = []) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .antigravity, accountRef: Self.rowAccountRef,
                         label: "Antigravity", plan: nil, windows: windows, state: state,
                         readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        guard let accessToken = token() else { return [finish(.unavailable(.noSignIn))] }
        let headers = ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json"]

        let metadata = UsageHTTPRequest(
            url: Self.assistURL, method: .post, headers: headers,
            body: #"{"metadata":{"ideType":"ANTIGRAVITY","pluginType":"GEMINI"}}"#.data(using: .utf8),
            timeout: 10)
        guard let assist = http.send(metadata) else { return [finish(.failed(.network))] }
        switch assist.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let object = UsageJSON.object(assist.body),
              let project = UsageJSON.plainID(object["cloudaicompanionProject"], max: 200) else {
            return [finish(.unavailable(.schemaChanged))]
        }

        struct Body: Encodable { let project: String }
        let modelsRequest = UsageHTTPRequest(
            url: Self.modelsURL, method: .post, headers: headers,
            body: try? JSONEncoder().encode(Body(project: project)), timeout: 10)
        guard let response = http.send(modelsRequest) else { return [finish(.failed(.network))] }
        switch response.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }

        guard let entries = modelEntries(response.body), !entries.isEmpty else {
            return [finish(.notReporting)]
        }
        var windowsByScope: [String: UsageWindow] = [:]
        var order: [String] = []
        for (dictionaryKey, model) in entries {
            guard let rawQuota = model["quotaInfo"], !(rawQuota is NSNull) else { continue }
            guard let scope = modelScope(model, dictionaryKey: dictionaryKey),
                  let quota = rawQuota as? [String: Any],
                  let remaining = UsageJSON.double(quota["remainingFraction"]),
                  remaining.isFinite,
                  let reset = UsageJSON.resetDateISO(quota["resetTime"])
            else { return [finish(.unavailable(.schemaChanged))] }
            let used = min(100, max(0, (1 - remaining) * 100))
            let candidate = UsageWindow(scope: scope, durationMinutes: nil,
                                        usedPercent: used, resetsAt: reset)
            if let existing = windowsByScope[scope] {
                guard existing.usedPercent == candidate.usedPercent,
                      existing.resetsAt == candidate.resetsAt else {
                    return [finish(.unavailable(.schemaChanged))]
                }
                continue
            }
            windowsByScope[scope] = candidate
            order.append(scope)
        }
        let windows = order.compactMap { windowsByScope[$0] }
        return windows.isEmpty ? [finish(.notReporting)] : [finish(.ok, windows)]
    }

    private func modelEntries(_ data: Data) -> [(String?, [String: Any])]? {
        guard let object = UsageJSON.object(data), let rawModels = object["models"] else { return nil }
        if let models = rawModels as? [String: Any] {
            var entries: [(String?, [String: Any])] = []
            for key in models.keys.sorted() {
                guard let model = models[key] as? [String: Any] else { return nil }
                entries.append((key, model))
            }
            return entries
        }
        if let models = rawModels as? [[String: Any]] {
            return models.map { (nil, $0) }
        }
        return nil
    }

    private func modelScope(_ model: [String: Any], dictionaryKey: String?) -> String? {
        for key in ["modelId", "id", "model"] {
            if let value = UsageJSON.plainID(model[key], max: 128) { return value }
        }
        if let dictionaryKey, let value = UsageJSON.plainID(dictionaryKey, max: 128) {
            return value
        }
        for key in ["displayName", "name"] {
            guard let value = UsageJSON.string(model[key]), value.count <= 128,
                  !value.contains("@"),
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { continue }
            return value
        }
        return nil
    }
}
