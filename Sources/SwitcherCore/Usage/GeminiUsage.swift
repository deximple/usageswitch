import CryptoKit
import Foundation

/// Gemini CLI usage adapter: Keychain first, then the legacy bounded auth file,
/// followed by loadCodeAssist -> retrieveUserQuota.
public struct GeminiUsageCollector: Sendable {
    public static let rowID = "gemini:current"
    public static let rowAccountRef = "current"
    private static let assistURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let runner: any UsageProcessRunner
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    /// Granted only via the Gemini connect dialog that discloses the in-memory refresh.
    private let refreshAllowed: Bool
    /// The installed Gemini CLI path; its package supplies the OAuth client it signs in with.
    private let cli: URL?
    private let clientFinder: any GeminiOAuthClientFinding
    private let tokenCache: GeminiAccessTokenCache

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                runner: any UsageProcessRunner,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = [:],
                refreshAllowed: Bool = false, cli: URL? = nil,
                clientFinder: any GeminiOAuthClientFinding = GeminiOAuthClientFinder(),
                tokenCache: GeminiAccessTokenCache = GeminiAccessTokenCache(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.credentials = credentials
        self.runner = runner; self.home = home; self.environment = environment; self.now = now
        self.refreshAllowed = refreshAllowed; self.cli = cli
        self.clientFinder = clientFinder; self.tokenCache = tokenCache
    }

    private enum CredentialResult {
        case token(String)
        /// Stored credential parsed fine but expired; carries any refresh token found.
        case expired(refreshToken: String?)
        case unavailable(UsageProblem)
        case failed(UsageProblem)
    }

    private func token() -> CredentialResult {
        guard environment["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"] != "true" else {
            return .unavailable(.noSignIn)
        }
        let keychain = runner.run(UsageProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", "main-account",
                        "-s", "gemini-cli-oauth", "-w"],
            environment: SystemClaudeAppControl.cleanEnvironment(from: environment),
            workingDirectory: FileManager.default.temporaryDirectory,
            maxOutputBytes: 64 * 1024, timeout: 3))
        switch keychain.outcome {
        case .exited(0):
            let raw = keychain.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard let data = raw.data(using: .utf8),
                      let object = UsageJSON.object(data),
                      object["serverName"] as? String == "main-account",
                      let token = object["token"] as? [String: Any],
                      let expiry = UsageJSON.double(token["expiresAt"]),
                      let access = UsageJSON.token(token["accessToken"]) else {
                    return .unavailable(.schemaChanged)
                }
                guard expiry > now().timeIntervalSince1970 * 1000 else {
                    return .expired(refreshToken: UsageJSON.token(token["refreshToken"]))
                }
                return .token(access)
            }
        case .outputLimit:
            return .unavailable(.schemaChanged)
        default:
            break
        }
        guard let data = credentials.read(home.appendingPathComponent(".gemini/oauth_creds.json")) else {
            return .unavailable(.noSignIn)
        }
        guard let object = UsageJSON.object(data),
              let expiry = UsageJSON.double(object["expiry_date"]),
              let access = UsageJSON.token(object["access_token"]) else {
            return .unavailable(.schemaChanged)
        }
        guard expiry > now().timeIntervalSince1970 * 1000 else {
            return .expired(refreshToken: UsageJSON.token(object["refresh_token"]))
        }
        return .token(access)
    }

    /// The Gemini CLI's access token lives ~1 h and is refreshed only when `gemini`
    /// runs. With explicit consent we mint a memory-only token from the stored
    /// refresh token + the installed CLI's own OAuth client. Nothing is written
    /// back; a missing refresh token, client, or consent keeps the old behavior.
    private func refreshAccess(_ refreshToken: String?) -> CredentialResult {
        guard refreshAllowed, let refreshToken else { return .unavailable(.signInExpired) }
        let key = Data(SHA256.hash(data: Data(refreshToken.utf8)))
        if let cached = tokenCache.value(for: key, at: now()) { return .token(cached) }
        guard let client = clientFinder.client(for: cli) else { return .unavailable(.signInExpired) }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
        ]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            return .unavailable(.schemaChanged)
        }
        let request = UsageHTTPRequest(url: Self.tokenURL, method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: body, timeout: 10)
        guard let response = http.send(request) else { return .failed(.network) }
        switch response.status {
        case 400, 401: return .unavailable(.signInExpired)
        case 429: return .failed(.rateLimited)
        case 200: break
        default: return .failed(.network)
        }
        // Only access_token + expires_in are read; a rotated refresh_token/id_token is ignored.
        guard let object = UsageJSON.object(response.body),
              let access = UsageJSON.token(object["access_token"]),
              let expires = UsageJSON.double(object["expires_in"]), expires > 0 else {
            return .unavailable(.schemaChanged)
        }
        tokenCache.store(for: key, accessToken: access,
                         validUntil: now().addingTimeInterval(max(0, expires - 60)))
        return .token(access)
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], plan: String? = nil) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .gemini, accountRef: Self.rowAccountRef,
                         label: "Gemini", plan: plan, windows: windows,
                         state: state, readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        let key: String
        switch token() {
        case .token(let access): key = access
        case .unavailable(let problem): return [finish(.unavailable(problem))]
        case .failed(let problem): return [finish(.failed(problem))]
        case .expired(let refreshToken):
            switch refreshAccess(refreshToken) {
            case .token(let access): key = access
            case .unavailable(let problem): return [finish(.unavailable(problem))]
            case .failed(let problem): return [finish(.failed(problem))]
            case .expired: return [finish(.unavailable(.signInExpired))]
            }
        }
        let headers = ["Authorization": "Bearer \(key)", "Content-Type": "application/json"]

        // Step 1: project id — the opaque project string is serialized as JSON, never
        // interpolated into a URL.
        let meta = UsageHTTPRequest(url: Self.assistURL, method: .post, headers: headers,
            body: #"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.data(using: .utf8),
            timeout: 10)
        guard let a = http.send(meta) else { return [finish(.failed(.network))] }
        switch a.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        guard let assist = UsageJSON.object(a.body),
              let project = UsageJSON.plainID(assist["cloudaicompanionProject"], max: 200) else {
            return [finish(.unavailable(.schemaChanged))]
        }

        // Step 2: quota buckets — validate the whole collection; malformed buckets must
        // not silently drop a limiting quota.
        struct Body: Encodable { let project: String }
        let quota = UsageHTTPRequest(url: Self.quotaURL, method: .post, headers: headers,
            body: try? JSONEncoder().encode(Body(project: project)), timeout: 10)
        guard let q = http.send(quota) else { return [finish(.failed(.network))] }
        switch q.status {
        case 200: break
        case 401, 403: return [finish(.failed(.refused))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }
        let buckets: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: q.body) as? [[String: Any]] {
            buckets = arr
        } else if let o = UsageJSON.object(q.body), let arr = o["buckets"] as? [[String: Any]] {
            buckets = arr
        } else {
            return [finish(.unavailable(.schemaChanged))]
        }
        var byScope: [String: UsageWindow] = [:]
        var order: [String] = []
        for b in buckets {
            guard let remaining = UsageJSON.double(b["remainingFraction"]),
                  (0...1).contains(remaining),
                  let model = UsageJSON.plainID(b["modelId"], max: 64) else {
                // malformed bucket: fail the collection rather than drop a quota
                return [finish(.unavailable(.schemaChanged))]
            }
            // resetTime is required and must parse — an absent quota reset is not "no window"
            guard let reset = UsageJSON.resetDateISO(b["resetTime"]) else {
                return [finish(.unavailable(.schemaChanged))]
            }
            let tokenType = b["tokenType"].flatMap { UsageJSON.plainID($0, max: 64) }
            if b["tokenType"] != nil && tokenType == nil {
                return [finish(.unavailable(.schemaChanged))]
            }
            // input ids never contain brackets, so "model [type]" can't collide with a bare model
            let scope = tokenType.map { "\(model) [\($0)]" } ?? model
            let candidate = UsageWindow(scope: scope, durationMinutes: nil,
                                        usedPercent: (1 - remaining) * 100,
                                        resetsAt: reset)
            if let existing = byScope[scope] {
                // identical typed duplicate collapses; a different record for the same
                // scope is contradictory input, not a merge
                if existing.usedPercent != candidate.usedPercent || existing.resetsAt != reset {
                    return [finish(.unavailable(.schemaChanged))]
                }
                continue
            }
            byScope[scope] = candidate
            order.append(scope)
        }
        let windows = order.compactMap { byScope[$0] }
        return windows.isEmpty ? [finish(.notReporting)] : [finish(.ok, windows)]
    }
}

/// Memory-only access-token cache for the Gemini refresh path. Keyed by the
/// SHA-256 of the refresh token so a different sign-in can never reuse an entry.
public final class GeminiAccessTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var accessToken: String?
    private var validUntil: Date = .distantPast

    public init() {}

    func value(for key: Data, at now: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard self.key == key, now < validUntil, let accessToken else { return nil }
        return accessToken
    }

    func store(for key: Data, accessToken: String, validUntil: Date) {
        lock.lock()
        self.key = key; self.accessToken = accessToken; self.validUntil = validUntil
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        key = nil; accessToken = nil; validUntil = .distantPast
        lock.unlock()
    }
}

/// Supplies the OAuth client the installed Gemini CLI uses — never hardcoded here.
public protocol GeminiOAuthClientFinding: Sendable {
    func client(for cli: URL?) -> (id: String, secret: String)?
}

/// Reads `OAUTH_CLIENT_ID`/`OAUTH_CLIENT_SECRET` from the installed
/// `@google/gemini-cli` package's `bundle/*.js`. Accepts only a single distinct
/// value for each, shape-validated; results are cached per package path and
/// bundle-directory modification time. Values are never logged.
public final class GeminiOAuthClientFinder: GeminiOAuthClientFinding, @unchecked Sendable {
    private struct CacheEntry: Sendable {
        let bundleModified: Date?
        let client: (id: String, secret: String)?
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    public init() {}

    public func client(for cli: URL?) -> (id: String, secret: String)? {
        guard let cli else { return nil }
        var dir = cli.resolvingSymlinksInPath().standardizedFileURL
        while dir.pathComponents.count > 1 {
            if dir.lastPathComponent == "gemini-cli",
               dir.deletingLastPathComponent().lastPathComponent == "@google" { break }
            dir = dir.deletingLastPathComponent()
        }
        guard dir.lastPathComponent == "gemini-cli" else { return nil }
        let bundle = dir.appendingPathComponent("bundle", isDirectory: true)
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: bundle.path)[.modificationDate]) as? Date
        let key = dir.path
        lock.lock()
        if let hit = cache[key], hit.bundleModified == modified {
            let client = hit.client; lock.unlock(); return client
        }
        lock.unlock()
        let found = Self.scan(bundle: bundle)
        lock.lock()
        cache[key] = CacheEntry(bundleModified: modified, client: found)
        lock.unlock()
        return found
    }

    private static func scan(bundle: URL) -> (id: String, secret: String)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundle, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var ids = Set<String>(), secrets = Set<String>()
        var scanned = 0
        for file in files where file.pathExtension == "js" {
            scanned += 1
            if scanned > 400 || ids.count > 1 || secrets.count > 1 { break }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            ids.formUnion(Self.quotedValues(needle: "OAUTH_CLIENT_ID = \"", in: text))
            secrets.formUnion(Self.quotedValues(needle: "OAUTH_CLIENT_SECRET = \"", in: text))
        }
        guard ids.count == 1, let id = ids.first,
              id.range(of: #"^[0-9]+-[0-9a-z]+\.apps\.googleusercontent\.com$"#,
                       options: .regularExpression) != nil,
              secrets.count == 1, let secret = secrets.first,
              secret.range(of: #"^GOCSPX-[A-Za-z0-9_-]{20,64}$"#,
                           options: .regularExpression) != nil else { return nil }
        return (id, secret)
    }

    private static func quotedValues(needle: String, in text: String) -> Set<String> {
        var out = Set<String>()
        var start = text.startIndex
        while let range = text.range(of: needle, range: start..<text.endIndex) {
            start = range.upperBound
            guard let close = text[start...].firstIndex(of: "\"") else { break }
            out.insert(String(text[start..<close])); start = close
        }
        return out
    }
}
