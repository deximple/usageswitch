import CryptoKit
import Foundation

/// Antigravity reads the local `/usage` screen first and supplements it with the
/// read-only quota summary API when that API is available.
public struct AntigravityUsageCollector: Sendable {
    public static let rowID = "antigravity:current"
    public static let rowAccountRef = "current"
    private static let assistURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let quotaURL = URL(string:
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let credentials: any UsageCredentialReading
    private let runner: any UsageProcessRunner
    private let screen: any AntigravityUsageScreenReading
    private let tokenCache: AntigravityAccessTokenCache
    private let screenCache: AntigravityUsageScreenCache
    private let home: URL
    private let agy: URL?
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                credentials: any UsageCredentialReading,
                runner: any UsageProcessRunner = SystemUsageProcessRunner(),
                screen: any AntigravityUsageScreenReading = AntigravityUsageScreen(),
                tokenCache: AntigravityAccessTokenCache = AntigravityAccessTokenCache(),
                screenCache: AntigravityUsageScreenCache = AntigravityUsageScreenCache(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                agy: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled
        self.http = http
        self.credentials = credentials
        self.runner = runner
        self.screen = screen
        self.tokenCache = tokenCache
        self.screenCache = screenCache
        self.home = home
        self.agy = agy
        self.environment = environment
        self.now = now
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [],
                    readAt: Date? = nil) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .antigravity, accountRef: Self.rowAccountRef,
                         label: "Antigravity", plan: nil, windows: windows, state: state,
                         readAt: readAt ?? now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        let keychainRead = readKeychainRecord()
        let legacyTokenRead: LegacyFileTokenRead?
        switch keychainRead {
        case .record(let record):
            let fingerprint = Data(SHA256.hash(data: Data(record.refreshToken.utf8)))
            tokenCache.updateAccountFingerprint(fingerprint, screenCache: screenCache)
            legacyTokenRead = nil
        case .missing:
            let read = readLegacyFileToken()
            let identity = read.accessToken.map { "file:\($0)" } ?? "none"
            let fingerprint = Data(SHA256.hash(data: Data(identity.utf8)))
            tokenCache.updateAccountFingerprint(fingerprint, screenCache: screenCache)
            legacyTokenRead = read
        case .refused, .schemaChanged:
            legacyTokenRead = nil
            break
        case .unavailable:
            // The Keychain read itself failed: publishing cached token or screen values would
            // assert an unverified account. Fail closed; the screen cache stays (audit B-09).
            return [finish(.failed(.timeout))]
        }
        let screenResult: AntigravityScreenResult
        let screenReadAt: Date?
        switch screenCache.acquire(at: now()) {
        case .read:
            let screenResultAt = now()
            let result = screen.read(executable: agy, now: screenResultAt)
            if result.state == .ok, !result.windows.isEmpty {
                let completedAt = now()
                screenCache.store(result.windows, readAt: completedAt)
                screenResult = result
                screenReadAt = completedAt
            } else {
                screenCache.recordFailure(at: now())
                screenResult = result
                screenReadAt = nil
            }
        case .cached(let windows, let readAt):
            screenResult = .success(windows)
            screenReadAt = readAt
        case .throttled:
            screenResult = .failure(.failed(.timeout))
            screenReadAt = nil
        }
        let apiResult = quota(keychainRead, legacyTokenRead: legacyTokenRead)
        switch (screenResult.state, apiResult) {
        case (.ok, .success(let apiWindows)):
            let windows = screenResult.windows.map { screenWindow in
                let reset = apiWindows.first {
                    $0.durationMinutes == screenWindow.durationMinutes
                        && ($0.scope ?? "").caseInsensitiveCompare(screenWindow.scope ?? "") == .orderedSame
                }?.resetsAt
                return UsageWindow(scope: screenWindow.scope,
                                   durationMinutes: screenWindow.durationMinutes,
                                   usedPercent: screenWindow.usedPercent,
                                   resetsAt: reset ?? screenWindow.resetsAt)
            }
            return [finish(.ok, windows, readAt: screenReadAt)]
        case (.ok, .failure):
            return [finish(.ok, screenResult.windows, readAt: screenReadAt)]
        case (_, .success(let windows)):
            return [finish(.ok, windows)]
        case (_, .failure(let apiState)):
            return [finish(Self.preferredFailure(screenResult.state, apiState))]
        }
    }

    private static func preferredFailure(_ screen: UsageState, _ api: UsageState) -> UsageState {
        switch api {
        case .failed(.refused), .failed(.signInRejected), .failed(.rateLimited), .unavailable(.noSignIn):
            return api
        default:
            break
        }
        switch screen {
        case .failed(.timeout), .failed(.network):
            return api
        default:
            return screen
        }
    }

    private enum APIResult {
        case success([UsageWindow])
        case failure(UsageState)
    }

    private struct KeychainRecord {
        let clientID: String
        let clientSecret: String
        let refreshToken: String
        let tokenURL: URL
        let projectID: String?
    }

    private struct LegacyFileTokenRead {
        let accessToken: String?
        let expiry: Date?
        let failure: UsageState?
    }

    private enum TokenResult {
        case token(String, projectID: String?)
        case failure(UsageState)
    }

    private enum KeychainRead {
        case record(KeychainRecord)
        case missing
        case schemaChanged
        case refused
        case unavailable
    }

    private func quota(_ keychainRead: KeychainRead,
                       legacyTokenRead: LegacyFileTokenRead?) -> APIResult {
        switch accessToken(keychainRead, legacyTokenRead: legacyTokenRead) {
        case .failure(let state): return .failure(state)
        case .token(let token, let fallbackProject):
            let headers = [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "User-Agent": "antigravity",
            ]
            let metadata = UsageHTTPRequest(
                url: Self.assistURL, method: .post, headers: headers,
                body: #"{"metadata":{"ideType":"ANTIGRAVITY","pluginType":"GEMINI"}}"#.data(using: .utf8),
                timeout: 10)
            let assist = http.send(metadata)
            let project = assist.flatMap { response -> String? in
                guard response.status == 200,
                      let object = UsageJSON.object(response.body) else { return nil }
                return UsageJSON.plainID(object["cloudaicompanionProject"], max: 200)
            } ?? fallbackProject
            guard let project else {
                return .failure(assist.flatMap(Self.apiFailure) ?? .unavailable(.schemaChanged))
            }

            struct Body: Encodable { let project: String }
            let request = UsageHTTPRequest(
                url: Self.quotaURL, method: .post, headers: headers,
                body: try? JSONEncoder().encode(Body(project: project)), timeout: 10)
            guard let response = http.send(request) else {
                return .failure(.failed(.network))
            }
            guard response.status == 200 else {
                return .failure(Self.apiFailure(response) ?? .failed(.network))
            }
            return Self.parseQuota(response.body)
        }
    }

    private static func apiFailure(_ response: UsageHTTPResponse) -> UsageState? {
        switch response.status {
        case 401, 403: return .failed(.signInRejected)
        case 429: return .failed(.rateLimited)
        case 200: return nil
        default: return .failed(.network)
        }
    }

    private static func parseQuota(_ data: Data) -> APIResult {
        guard let root = UsageJSON.object(data), let groups = root["groups"] as? [[String: Any]] else {
            return .failure(.unavailable(.schemaChanged))
        }
        var windows: [UsageWindow] = []
        for group in groups {
            guard let rawScope = UsageJSON.string(group["displayName"]),
                  validAPIScope(rawScope),
                  let buckets = group["buckets"] as? [[String: Any]] else {
                return .failure(.unavailable(.schemaChanged))
            }
            for bucket in buckets {
                guard let kind = UsageJSON.string(bucket["window"])?.lowercased() else {
                    return .failure(.unavailable(.schemaChanged))
                }
                let duration: Int
                switch kind {
                case "weekly": duration = 10_080
                case "5h": duration = 300
                default: continue
                }
                guard let remaining = UsageJSON.double(bucket["remainingFraction"]),
                      (0...1).contains(remaining),
                      let reset = UsageJSON.resetDateISO(bucket["resetTime"]) else {
                    return .failure(.unavailable(.schemaChanged))
                }
                windows.append(UsageWindow(scope: AntigravityScope.canonical(rawScope),
                                           durationMinutes: duration,
                                           usedPercent: (1 - remaining) * 100, resetsAt: reset))
            }
        }
        return windows.isEmpty ? .failure(.unavailable(.schemaChanged)) : .success(windows)
    }

}

/// One spelling for quota-group names, used by the screen and API read paths so pins and
/// alerts key the same window identically (audit B-09). The screen path's words-capitalized
/// spelling is the reference, so existing pins stay valid.
public enum AntigravityScope {
    /// Lowercases, then capitalizes the first letter of each word: "GEMINI MODELS" and
    /// "gemini models" both become "Gemini Models".
    public static func canonical(_ scope: String) -> String {
        scope.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word in
                var scalars = String(word)
                scalars.replaceSubrange(...scalars.startIndex,
                                        with: scalars.prefix(1).uppercased())
                return scalars
            }
            .joined(separator: " ")
    }
}

extension AntigravityUsageCollector {
    private static func validAPIScope(_ scope: String) -> Bool {
        (1...40).contains(scope.count) && scope.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value) || scalar == " " || scalar == "."
                || scalar == "&" || scalar == "-"
        }
    }

    private func readKeychainRecord() -> KeychainRead {
        let result = runner.run(UsageProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "gemini", "-a", "antigravity-acp", "-w"],
            environment: SystemClaudeAppControl.cleanEnvironment(from: environment),
            workingDirectory: FileManager.default.temporaryDirectory,
            maxOutputBytes: 64 * 1024, timeout: 3))
        switch result.outcome {
        case .exited(0):
            let raw = result.lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = raw.data(using: .utf8), let record = Self.keychainRecord(data) else {
                return .schemaChanged
            }
            return .record(record)
        case .exited(44):
            return .missing
        case .outputLimit:
            return .schemaChanged
        case .cancelled:
            return .refused
        default:
            return .unavailable
        }
    }

    private func accessToken(_ keychainRead: KeychainRead,
                             legacyTokenRead: LegacyFileTokenRead?) -> TokenResult {
        let current = now()
        switch keychainRead {
        case .record(let record):
            if let cached = tokenCache.value(at: current) {
                return .token(cached.accessToken, projectID: cached.projectID)
            }
            return exchange(record)
        case .missing:
            return fileToken(at: current, read: legacyTokenRead ?? readLegacyFileToken())
        case .schemaChanged:
            return .failure(.unavailable(.schemaChanged))
        case .refused:
            return .failure(.failed(.refused))
        case .unavailable:
            if let cached = tokenCache.value(at: current) {
                return .token(cached.accessToken, projectID: cached.projectID)
            }
            return .failure(.failed(.timeout))
        }
    }

    private func exchange(_ record: KeychainRecord) -> TokenResult {
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: record.refreshToken),
            URLQueryItem(name: "client_id", value: record.clientID),
            URLQueryItem(name: "client_secret", value: record.clientSecret),
        ]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            return .failure(.unavailable(.schemaChanged))
        }
        let request = UsageHTTPRequest(
            url: record.tokenURL, method: .post,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: body, timeout: 10)
        guard let response = http.send(request) else { return .failure(.failed(.network)) }
        switch response.status {
        case 400, 401: return .failure(.unavailable(.noSignIn))
        case 429: return .failure(.failed(.rateLimited))
        case 200: break
        default: return .failure(.failed(.network))
        }
        guard let object = UsageJSON.object(response.body),
              let access = UsageJSON.token(object["access_token"]),
              let expires = UsageJSON.double(object["expires_in"]), expires > 0 else {
            return .failure(.unavailable(.schemaChanged))
        }
        let refreshedAt = now()
        tokenCache.store(accessToken: access,
                         validUntil: refreshedAt.addingTimeInterval(max(0, expires - 60)),
                         projectID: record.projectID)
        return .token(access, projectID: record.projectID)
    }

    private func readLegacyFileToken() -> LegacyFileTokenRead {
        guard let data = credentials.read(home.appendingPathComponent(
            ".gemini/jetski-standalone-oauth-token")) else {
            return LegacyFileTokenRead(accessToken: nil, expiry: nil,
                                       failure: .unavailable(.noSignIn))
        }
        guard let object = UsageJSON.object(data),
              let token = object["token"] as? [String: Any],
              let access = UsageJSON.token(token["access_token"]) else {
            return LegacyFileTokenRead(accessToken: nil, expiry: nil,
                                       failure: .unavailable(.schemaChanged))
        }
        guard let expiry = UsageJSON.expiryDate(token["expiry"]) else {
            return LegacyFileTokenRead(accessToken: access, expiry: nil,
                                       failure: .unavailable(.schemaChanged))
        }
        return LegacyFileTokenRead(accessToken: access, expiry: expiry, failure: nil)
    }

    private func fileToken(at current: Date, read: LegacyFileTokenRead) -> TokenResult {
        guard let access = read.accessToken else {
            return .failure(read.failure ?? .unavailable(.schemaChanged))
        }
        guard let expiry = read.expiry else {
            return .failure(read.failure ?? .unavailable(.schemaChanged))
        }
        guard expiry > current else { return .failure(.unavailable(.signInExpired)) }
        return .token(access, projectID: nil)
    }

    private static func keychainRecord(_ data: Data) -> KeychainRecord? {
        guard data.count <= 64 * 1024,
              let object = UsageJSON.object(data),
              let clientID = UsageJSON.token(object["client_id"], max: 1024),
              let clientSecret = UsageJSON.token(object["client_secret"]),
              let refreshToken = UsageJSON.token(object["refresh_token"]),
              let tokenURI = UsageJSON.string(object["token_uri"]),
              let tokenURL = URL(string: tokenURI),
              let components = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "oauth2.googleapis.com",
              components.path == "/token", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let scopes = object["scopes"] as? [String], !scopes.isEmpty,
              scopes.count <= 32,
              scopes.allSatisfy({ UsageJSON.token($0, max: 512) != nil }),
              let project = UsageJSON.plainID(object["project_id"], max: 200) else { return nil }
        return KeychainRecord(clientID: clientID, clientSecret: clientSecret,
                              refreshToken: refreshToken, tokenURL: tokenURL, projectID: project)
    }
}

public final class AntigravityAccessTokenCache: @unchecked Sendable {
    struct Value: Sendable {
        let accessToken: String
        let validUntil: Date
        let projectID: String?
    }

    private let lock = NSLock()
    private var cached: Value?
    private var accountFingerprint: Data?

    public init() {}

    func value(at now: Date) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached, now < cached.validUntil else { return nil }
        return cached
    }

    func store(accessToken: String, validUntil: Date, projectID: String?) {
        lock.lock()
        cached = Value(accessToken: accessToken, validUntil: validUntil, projectID: projectID)
        lock.unlock()
    }

    func updateAccountFingerprint(_ fingerprint: Data, screenCache: AntigravityUsageScreenCache) {
        lock.lock()
        defer { lock.unlock() }
        guard let accountFingerprint else {
            self.accountFingerprint = fingerprint
            return
        }
        guard accountFingerprint != fingerprint else { return }
        cached = nil
        screenCache.clear()
        self.accountFingerprint = fingerprint
    }

    public func clear() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

public final class AntigravityUsageScreenCache: @unchecked Sendable {
    enum Decision {
        case read
        case cached([UsageWindow], Date)
        case throttled
    }

    private struct Success: Sendable {
        let windows: [UsageWindow]
        let readAt: Date
    }

    static let minimumInterval: TimeInterval = 9 * 60
    private let lock = NSLock()
    private var lastAttemptAt: Date?
    private var success: Success?

    public init() {}

    func acquire(at now: Date) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.minimumInterval {
            if let success, now.timeIntervalSince(success.readAt) < Self.minimumInterval {
                return .cached(success.windows, success.readAt)
            }
            return .throttled
        }
        lastAttemptAt = now
        return .read
    }

    func store(_ windows: [UsageWindow], readAt: Date) {
        lock.lock()
        lastAttemptAt = readAt
        success = Success(windows: windows, readAt: readAt)
        lock.unlock()
    }

    func recordFailure(at date: Date) {
        lock.lock()
        lastAttemptAt = date
        lock.unlock()
    }

    func clear() {
        lock.lock()
        success = nil
        lock.unlock()
    }
}
