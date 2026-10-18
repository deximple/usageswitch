import Foundation

/// Who a Codex home is signed in as, read from `<home>/auth.json`. Only the id token's claims are read; tokens and
/// keys are never kept, copied or printed.
public struct CodexIdentity: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case chatgpt
        case apiKey = "api_key"
        /// A sign-in file that can't be understood.
        case unknown
    }

    public let mode: Mode
    public let email: String?
    public let name: String?
    /// ChatGPT plan, e.g. "plus", "pro", "team".
    public let plan: String?
    public let accountId: String?

    public init(mode: Mode, email: String? = nil, name: String? = nil, plan: String? = nil, accountId: String? = nil) {
        self.mode = mode
        self.email = email
        self.name = name
        self.plan = plan
        self.accountId = accountId
    }

    /// nil when the home has no sign-in file (signed out).
    public static func read(home: URL) -> CodexIdentity? {
        let url = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexIdentity(mode: .unknown)
        }
        let tokens = object["tokens"] as? [String: Any]
        if let idToken = tokens?["id_token"] as? String, let claims = claims(ofJWT: idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            return CodexIdentity(
                mode: .chatgpt, email: claims["email"] as? String, name: claims["name"] as? String,
                plan: auth?["chatgpt_plan_type"] as? String,
                accountId: (auth?["chatgpt_account_id"] as? String) ?? (tokens?["account_id"] as? String))
        }
        if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { return CodexIdentity(mode: .apiKey) }
        return CodexIdentity(mode: .unknown)
    }

    /// The payload of a JWT. The signature isn't checked: the claims only name the account in the list.
    static func claims(ofJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
