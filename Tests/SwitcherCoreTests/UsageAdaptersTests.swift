import Foundation
import Testing
@testable import SwitcherCore

/// Spy transport: records every request, replays queued responses, never touches a network.
final class SpyTransport: UsageHTTPTransport, @unchecked Sendable {
    var requests: [UsageHTTPRequest] = []
    var queue: [UsageHTTPResponse?] = []
    func send(_ request: UsageHTTPRequest) -> UsageHTTPResponse? {
        requests.append(request)
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Spy credential reader: counts reads, serves synthetic files only.
final class SpyCredentials: UsageCredentialReading, @unchecked Sendable {
    var files: [String: Data] = [:]
    var reads = 0
    func read(_ url: URL) -> Data? { reads += 1; return files[url.path] }
}

private func expectRefusedWithoutRetainedWindows(_ reading: AccountUsage?) {
    #expect(reading?.state == .failed(.refused))
    #expect(reading?.windows.isEmpty == true)
    guard let reading else { return }
    let previous = AccountUsage(id: reading.id, provider: reading.provider,
        accountRef: reading.accountRef, label: reading.label, plan: reading.plan,
        windows: [UsageWindow(scope: nil, durationMinutes: 300, usedPercent: 50, resetsAt: nil)],
        state: .ok, readAt: Date(timeIntervalSince1970: 0), toolVersion: reading.toolVersion,
        authentication: reading.authentication, identityKey: reading.identityKey)
    #expect(reading.retainingWindows(from: previous).windows.isEmpty)
}

@Suite("HTTP transport")
struct UsageTransportTests {
    @Test("non-https and disallowed hosts never reach the network")
    func allowlist() {
        let t = SystemUsageHTTPTransport()
        let http = UsageHTTPRequest(url: URL(string: "http://api2.cursor.sh/x")!,
                                    method: .get, timeout: 1)
        #expect(t.send(http) == nil)
        let bad = UsageHTTPRequest(url: URL(string: "https://api.test/x")!,
                                   method: .get, timeout: 1)
        #expect(t.send(bad) == nil)
    }

    @Test("Google OAuth token endpoint is allowlisted for Antigravity")
    func antigravityTokenHost() {
        #expect(SystemUsageHTTPTransport.allowedHosts.contains("oauth2.googleapis.com"))
    }
}

@Suite("Grok adapter")
struct GrokAdapterTests {
    private let home = URL(fileURLWithPath: "/tmp/grok-home")
    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           enabled: Bool = true) -> GrokUsageCollector {
        GrokUsageCollector(enabled: enabled, http: http, credentials: creds,
                           home: home, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }
    private var authJSON: String {
        #"{"https://auth.x.ai":{"key":"k1","user_id":"u1","expires_at":"2999-01-01T00:00:00Z"}}"#
    }

    @Test("disabled does zero reads and zero requests")
    func disabled() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds, enabled: false).collect().isEmpty)
        #expect(creds.reads == 0 && http.requests.isEmpty)
    }

    @Test("happy path sends exact request and parses percentage + weekly period")
    func happy() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = authJSON.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2023-11-20T00:00:00Z"},"subscriptionTier":"x"}}"#.data(using: .utf8)!)]
        let rows = collector(http, creds).collect()
        #expect(rows.count == 1 && rows[0].state == .ok)
        #expect(rows[0].windows.first?.usedPercent == 40)
        #expect(http.requests.first?.url.host == "cli-chat-proxy.grok.com")
        #expect(http.requests.first?.method == .get)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer k1")
        #expect(http.requests.first?.headers["x-userid"] == "u1")
    }

    @Test("money-only response is notReporting, never healthy zero")
    func moneyOnly() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = authJSON.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"config":{"monthlyLimit":25,"used":4}}"#.data(using: .utf8)!)]
        #expect(collector(http, creds).collect().first?.state == .notReporting)
    }

    @Test("untrusted auth origin supplies no token")
    func untrusted() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = #"{"https://evil.example":{"key":"k1"}}"#.data(using: .utf8)
        let rows = collector(http, creds).collect()
        #expect(rows.count == 1 && rows[0].state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("expired token is sign-in, not refreshed")
    func expired() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = #"{"https://auth.x.ai":{"key":"k1","expires_at":"2020-01-01T00:00:00Z"}}"#.data(using: .utf8)
        #expect(collector(http, creds).collect().first?.state == .unavailable(.signInExpired))
        #expect(http.requests.isEmpty)
    }

    @Test("missing local credential is noSignIn")
    func missingCredential() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds).collect().first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("server 401 and 403 reject a present credential", arguments: [401, 403])
    func rejectedCredential(status: Int) {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = authJSON.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: status, body: Data())]
        expectRefusedWithoutRetainedWindows(collector(http, creds).collect().first)
    }
}

@Suite("Gemini adapter")
struct GeminiAdapterTests {
    private let home = URL(fileURLWithPath: "/tmp/gemini-home")
    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           enabled: Bool = true,
                           runner: FakeUsageRunner = FakeUsageRunner(),
                           environment: [String: String] = [:]) -> GeminiUsageCollector {
        GeminiUsageCollector(enabled: enabled, http: http, credentials: creds,
                             runner: runner, home: home, environment: environment,
                             now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test("disabled does zero reads and zero requests")
    func disabled() {
        let http = SpyTransport(); let creds = SpyCredentials()
        let runner = FakeUsageRunner()
        #expect(collector(http, creds, enabled: false, runner: runner).collect().isEmpty)
        #expect(creds.reads == 0 && http.requests.isEmpty && runner.requests.isEmpty)
    }

    @Test("reads the Gemini CLI 0.58 Keychain JSON shape before the legacy file")
    func keychainCredential() {
        let http = SpyTransport(); let creds = SpyCredentials(); let runner = FakeUsageRunner()
        let keychain = #"{"serverName":"main-account","token":{"accessToken":"keychain-access","refreshToken":"unused-refresh","tokenType":"Bearer","scope":"scope","expiresAt":9999999999999},"updatedAt":1700000000000}"#
        runner.respond = { _ in UsageProcessResult(lines: [keychain], outcome: .exited(0)) }
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"project-1"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.5,"resetTime":"2023-11-20T00:00:00Z"}]}"#.data(using: .utf8)!),
        ]
        let row = collector(http, creds, runner: runner).collect().first
        #expect(row?.state == .ok)
        #expect(creds.reads == 0)
        #expect(runner.requests.first?.arguments == [
            "find-generic-password", "-a", "main-account", "-s", "gemini-cli-oauth", "-w",
        ])
        #expect(http.requests.first?.headers["Authorization"] == "Bearer keychain-access")
    }

    @Test("expired Keychain credential is authoritative over the legacy file")
    func expiredKeychain() {
        let http = SpyTransport(); let creds = SpyCredentials(); let runner = FakeUsageRunner()
        let keychain = #"{"serverName":"main-account","token":{"accessToken":"expired","expiresAt":1}}"#
        runner.respond = { _ in UsageProcessResult(lines: [keychain], outcome: .exited(0)) }
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"file-token","expiry_date":9999999999999}"#.data(using: .utf8)
        #expect(collector(http, creds, runner: runner).collect().first?.state == .unavailable(.signInExpired))
        #expect(creds.reads == 0 && http.requests.isEmpty)
    }

    @Test("encrypted file storage is unsupported and treated as no sign-in")
    func encryptedStorage() {
        let http = SpyTransport(); let creds = SpyCredentials(); let runner = FakeUsageRunner()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"file-token","expiry_date":9999999999999}"#.data(using: .utf8)
        #expect(collector(http, creds, runner: runner,
                          environment: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE": "true"])
            .collect().first?.state == .unavailable(.noSignIn))
        #expect(creds.reads == 0 && runner.requests.isEmpty && http.requests.isEmpty)
    }

    @Test("two-step flow: project id then buckets, direction inverted once, nil duration")
    func happy() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] = #"{"access_token":"t1","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p-123"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: #"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.2,"resetTime":"2023-11-20T00:00:00Z"},{"modelId":"gemini-flash","remainingFraction":0.9,"resetTime":"2023-11-20T00:00:00Z"}]}"#.data(using: .utf8)!),
        ]
        let rows = collector(http, creds).collect()
        #expect(rows.count == 1 && rows[0].state == .ok)
        #expect(rows[0].windows.count == 2)
        #expect(abs((rows[0].windows[0].usedPercent) - 80) < 0.001)  // 1-0.2
        #expect(abs((rows[0].windows[1].usedPercent) - 10) < 0.001)  // 1-0.9
        #expect(rows[0].windows[0].durationMinutes == nil)
        #expect(rows[0].windows[0].scope == "gemini-pro")
        #expect(http.requests.count == 2)
        #expect(http.requests[0].url.absoluteString.contains("loadCodeAssist"))
        #expect(http.requests[1].url.absoluteString.contains("retrieveUserQuota"))
        #expect(String(data: http.requests[1].body ?? Data(), encoding: .utf8) == #"{"project":"p-123"}"#)
    }

    @Test("malformed bucket fails the collection, never silently drops")
    func malformed() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] = #"{"access_token":"t1","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: #"{"buckets":[{"modelId":"ok","remainingFraction":0.5},{"modelId":"bad"}]}"#.data(using: .utf8)!),
        ]
        #expect(collector(http, creds).collect().first?.state == .unavailable(.schemaChanged))
    }

    @Test("expired token is sign-in")
    func expired() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] = #"{"access_token":"t1","expiry_date":1}"#.data(using: .utf8)
        #expect(collector(http, creds).collect().first?.state == .unavailable(.signInExpired))
        #expect(http.requests.isEmpty)
    }

    @Test("malformed flat OAuth credential file is schema changed")
    func malformedLegacyCredentials() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":7,"expiry_date":"bad"}"#.data(using: .utf8)
        #expect(collector(http, creds).collect().first?.state == .unavailable(.schemaChanged))
        #expect(http.requests.isEmpty)
    }

    @Test("missing local credential is noSignIn")
    func missingCredential() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds).collect().first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("server 401 and 403 at project lookup are refused", arguments: [401, 403])
    func projectLookupRejected(status: Int) {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"t1","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: status, body: Data())]
        expectRefusedWithoutRetainedWindows(collector(http, creds).collect().first)
        #expect(http.requests.count == 1)
    }

    @Test("server 401 and 403 at quota lookup are refused", arguments: [401, 403])
    func quotaLookupRejected(status: Int) {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"t1","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: status, body: Data()),
        ]
        expectRefusedWithoutRetainedWindows(collector(http, creds).collect().first)
        #expect(http.requests.count == 2)
    }

    @Test("403 with the unsupported-service phrase is refused without retaining its body")
    func unsupported403() throws {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"t1","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 403, body: Data("API is no longer supported".utf8)),
        ]
        let row = try #require(collector(http, creds).collect().first)
        #expect(row.state == .failed(.refused))
        let snapshot = UsageSnapshot(usages: [row], generatedAt: Date(), showEmails: true)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            .contains("no longer supported"))
    }
}

@Suite("Devin adapter")
struct DevinAdapterTests {
    private let home = URL(fileURLWithPath: "/tmp/devin-home")
    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           runner: FakeRunner = FakeRunner(),
                           enabled: Bool = true) -> DevinUsageCollector {
        DevinUsageCollector(enabled: enabled, http: http, credentials: creds,
                            runner: runner, cli: URL(fileURLWithPath: "/usr/bin/devin"),
                            clientVersion: "1.0", home: home,
                            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }
    struct FakeRunner: UsageProcessRunner {
        var response = UsageProcessResult(lines: ["devin 2.3.4"], outcome: .exited(0))
        func run(_ request: UsageProcessRequest) -> UsageProcessResult { response }
    }
    private var toml: String { #"api_key = "d1""# }

    @Test("disabled does zero reads/requests/processes")
    func disabled() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds, enabled: false).collect().isEmpty)
        #expect(creds.reads == 0 && http.requests.isEmpty)
    }

    @Test("happy path: quota plan + remaining->used, daily+weekly windows, fixed host")
    func happy() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/devin-home/.local/share/devin/credentials.toml"] = toml.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":25,"dailyQuotaResetAtUnix":1700500000,"weeklyQuotaRemainingPercent":80,"weeklyQuotaResetAtUnix":1700900000,"planInfo":{"planName":"Solo","billingStrategy":"BILLING_STRATEGY_QUOTA"}}}}"#.data(using: .utf8)!)]
        let rows = collector(http, creds).collect()
        #expect(rows.count == 1 && rows[0].state == .ok && rows[0].plan == "Solo")
        #expect(rows[0].windows.count == 2)
        #expect(rows[0].windows[0].usedPercent == 75)   // 100-25 daily
        #expect(rows[0].windows[1].usedPercent == 20)   // 100-80 weekly
        #expect(http.requests.first?.url.host == "server.codeium.com")
        #expect(http.requests.first?.headers["Connect-Protocol-Version"] == "1")
        let body = String(data: http.requests.first?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"apiKey\":\"d1\""))
        #expect(body.contains("\"extensionName\":\"devin-cli\""))
        #expect(body.contains("\"extensionVersion\":\"2.3.4\""))
    }

    @Test("hidden windows are absent, not reported")
    func hidden() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/devin-home/.local/share/devin/credentials.toml"] = toml.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"userStatus":{"planStatus":{"hideDailyQuota":true,"weeklyQuotaRemainingPercent":80,"weeklyQuotaResetAtUnix":1700900000,"planInfo":{"billingStrategy":"BILLING_STRATEGY_QUOTA"}}}}"#.data(using: .utf8)!)]
        let rows = collector(http, creds).collect()
        #expect(rows[0].windows.count == 1 && rows[0].windows[0].scope == nil)
        #expect(rows[0].windows[0].durationMinutes == 10080)
    }

    @Test("proto3 omitted zero only on quota plan + valid reset")
    func omittedZero() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/devin-home/.local/share/devin/credentials.toml"] = toml.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"userStatus":{"planStatus":{"weeklyQuotaResetAtUnix":1700900000,"planInfo":{"billingStrategy":"BILLING_STRATEGY_QUOTA"}}}}"#.data(using: .utf8)!)]
        let rows = collector(http, creds).collect()
        #expect(rows[0].windows.count == 1 && rows[0].windows[0].usedPercent == 100)
    }

    @Test("arbitrary configured server fails closed, no request")
    func rogueServer() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/devin-home/.local/share/devin/credentials.toml"] = #"api_server_url = "https://evil.example""#.data(using: .utf8)
        let rows = collector(http, creds).collect()
        #expect(rows.first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("missing local credential is noSignIn")
    func missingCredential() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds).collect().first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("server 401 and 403 reject a present credential", arguments: [401, 403])
    func rejectedCredential(status: Int) {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/devin-home/.local/share/devin/credentials.toml"] = toml.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: status, body: Data())]
        expectRefusedWithoutRetainedWindows(collector(http, creds).collect().first)
        #expect(http.requests.count == 1)
    }
}

@Suite("OpenCode adapter")
struct OpenCodeAdapterTests {
    private let home = URL(fileURLWithPath: "/tmp/oc-home")
    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           enabled: Bool = true) -> OpenCodeUsageCollector {
        OpenCodeUsageCollector(enabled: enabled, http: http, credentials: creds,
                               home: home, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test("disabled does zero reads and zero requests")
    func disabled() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds, enabled: false).collect().isEmpty)
        #expect(creds.reads == 0 && http.requests.isEmpty)
    }

    @Test("happy path preserves all three windows")
    func happy() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/oc-home/.local/share/opencode/auth.json"] = #"{"opencode-go":{"type":"api","key":"g1"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"usage":{"rolling":{"percent":30,"resetsAt":"2023-11-15T00:00:00Z"},"weekly":{"percent":55,"resetsAt":"2023-11-20T00:00:00Z"},"monthly":{"percent":10,"resetsAt":null}}}"#.data(using: .utf8)!)]
        let rows = collector(http, creds).collect()
        #expect(rows.count == 1 && rows[0].state == .ok && rows[0].windows.count == 3)
        #expect(rows[0].windows[0].usedPercent == 30)
        #expect(http.requests.first?.url.absoluteString == "https://opencode.ai/zen/go/v1/usage")
        #expect(http.requests.first?.headers["Authorization"] == "Bearer g1")
    }

    @Test("server 401 rejects a present credential")
    func rejectedCredential() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/oc-home/.local/share/opencode/auth.json"] = #"{"opencode-go":{"type":"api","key":"g1"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 401, body: Data())]
        expectRefusedWithoutRetainedWindows(collector(http, creds).collect().first)
    }

    @Test("403 means no Go plan, not rejected sign-in")
    func noGoPlan() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/oc-home/.local/share/opencode/auth.json"] = #"{"opencode-go":{"type":"api","key":"g1"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 403, body: Data())]
        let row = collector(http, creds).collect().first
        #expect(row?.state == .notReporting)
        #expect(row?.windows.isEmpty == true)
    }

    @Test("missing local credential is noSignIn")
    func missingCredential() {
        let http = SpyTransport(); let creds = SpyCredentials()
        #expect(collector(http, creds).collect().first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("other-provider key is ignored")
    func foreignKey() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/oc-home/.local/share/opencode/auth.json"] = #"{"anthropic":{"type":"api","key":"x"}}"#.data(using: .utf8)
        #expect(collector(http, creds).collect().first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }
}

/// Offline protocol stub for transport tests — no real network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data)) = { _ in (200, Data()) }
    /// Optional headers so tests can exercise the Content-Length fast path.
    nonisolated(unsafe) static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        var fields = Self.headers
        if fields["Content-Length"] == nil && fields["Transfer-Encoding"] == nil {
            fields["Content-Length"] = String(body.count)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: fields)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        // deliver in chunks to exercise the streaming bound
        let half = body.count / 2
        client?.urlProtocol(self, didLoad: body.prefix(half))
        client?.urlProtocol(self, didLoad: body.suffix(body.count - half))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbed() -> SystemUsageHTTPTransport {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubProtocol.self]
    return SystemUsageHTTPTransport(configuration: c)
}

@Suite("Transport streaming bounds", .serialized)
struct TransportStreamTests {
    @Test("a real 200 JSON response passes through the delegate path")
    func success() {
        let body = #"{"ok":true,"v":42}"#.data(using: .utf8)!
        StubProtocol.handler = { _ in (200, body) }
        let req = UsageHTTPRequest(url: URL(string: "https://api2.cursor.sh/x")!,
                                 method: .get, timeout: 5)
        let r = stubbed().send(req)
        #expect(r?.status == 200)
        #expect(r?.body == body)
    }

    @Test("Content-Length above cap is rejected before any bytes arrive")
    func tooBig() {
        // declared oversized length is refused at the response stage, not after body
        StubProtocol.headers = ["Content-Length": "2000000"]
        StubProtocol.handler = { _ in (200, Data(repeating: 1, count: 16)) }
        let req = UsageHTTPRequest(url: URL(string: "https://api2.cursor.sh/x")!,
                                 method: .get, timeout: 5)
        #expect(stubbed().send(req) == nil)
        StubProtocol.headers = [:]
    }

    @Test("chunks crossing the cap mid-stream cancel")
    func crossing() {
        // two ~600KiB chunks land past the 1MiB bound together
        StubProtocol.headers = ["Transfer-Encoding": "chunked"]
        defer { StubProtocol.headers = [:] }
        StubProtocol.handler = { _ in (200, Data(repeating: 1, count: 1_200_000)) }
        let req = UsageHTTPRequest(url: URL(string: "https://api2.cursor.sh/x")!,
                                 method: .get, timeout: 5)
        #expect(stubbed().send(req) == nil)
    }
}

@Suite("Adapter error normalization")
struct AdapterStatusTests {
    private let home = URL(fileURLWithPath: "/tmp/x")
    @Test("429 and 500 normalize to failed, never a fake reading", arguments: [429, 500])
    func statuses(_ status: Int) {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/x/.grok/auth.json"] = #"{"https://auth.x.ai":{"key":"k"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: status, body: Data())]
        let rows = GrokUsageCollector(enabled: true, http: http, credentials: creds,
                                      home: home).collect()
        #expect(rows.first?.state != .ok && rows.first?.windows.isEmpty == true)
    }
}

private final class RedirectTargetFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var hit = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return hit }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; hit = value }
}

final class RedirectProtocol: URLProtocol, @unchecked Sendable {
    fileprivate static let targetHit = RedirectTargetFlag()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "evil.example" {
            Self.targetHit.set(true)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                headerFields: ["Location": "https://evil.example"])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.example")!),
                            redirectResponse: r)
    }
    override func stopLoading() {}
}

@Suite("Provider edge regressions")
struct ProviderEdgeTests {
    private let home = URL(fileURLWithPath: "/tmp/e")

    @Test("redirect refusal: nil response AND the target was never invoked")
    func redirect() {
        RedirectProtocol.targetHit.set(false)
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [RedirectProtocol.self]
        let t = SystemUsageHTTPTransport(configuration: c)
        let req = UsageHTTPRequest(url: URL(string: "https://api2.cursor.sh/x")!,
                                 method: .get, timeout: 5)
        #expect(t.send(req) == nil)
        #expect(RedirectProtocol.targetHit.value == false)
    }

    @Test("grok lookalike auth origin supplies no token")
    func grokLookalike() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.grok/auth.json"] = #"{"https://auth.x.ai.evil":{"key":"k"}}"#.data(using: .utf8)
        let rows = GrokUsageCollector(enabled: true, http: http, credentials: creds, home: home).collect()
        #expect(rows.first?.state == .unavailable(.noSignIn) && http.requests.isEmpty)
    }

    @Test("grok multiple trusted entries with no selection fail closed")
    func grokAmbiguous() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.grok/auth.json"] = #"{"https://auth.x.ai":{"key":"k1"},"https://auth.x.ai::other":{"key":"k2"}}"#.data(using: .utf8)
        let rows = GrokUsageCollector(enabled: true, http: http, credentials: creds, home: home).collect()
        #expect(rows.first?.state == .unavailable(.noSignIn) && http.requests.isEmpty)
    }

    @Test("gemini same model with two tokenTypes stays distinct; contradiction fails")
    func geminiTokenTypes() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.gemini/oauth_creds.json"] = #"{"access_token":"t","expiry_date":9999999999999}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: #"{"buckets":[{"modelId":"g","tokenType":"input","remainingFraction":0.5,"resetTime":"2025-01-01T00:00:00Z"},{"modelId":"g","tokenType":"output","remainingFraction":0.7,"resetTime":"2025-01-01T00:00:00Z"}]}"#.data(using: .utf8)!),
        ]
        let rows = GeminiUsageCollector(enabled: true, http: http, credentials: creds,
                                        runner: FakeUsageRunner(), home: home).collect()
        #expect(rows.first?.windows.count == 2)
        #expect(rows.first?.windows.first?.scope == "g [input]")
        // contradictory duplicate for the same scope fails the whole read
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"cloudaicompanionProject":"p"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: #"{"buckets":[{"modelId":"g","tokenType":"input","remainingFraction":0.5,"resetTime":"2025-01-01T00:00:00Z"},{"modelId":"g","tokenType":"input","remainingFraction":0.9,"resetTime":"2025-01-01T00:00:00Z"}]}"#.data(using: .utf8)!),
        ]
        #expect(GeminiUsageCollector(enabled: true, http: http, credentials: creds,
                                     runner: FakeUsageRunner(), home: home)
            .collect().first?.state == .unavailable(.schemaChanged))
    }

    @Test("devin malformed preferred file never falls to weaker candidate; zero probe")
    func devinAuthoritative() {
        struct Runner: UsageProcessRunner {
            func run(_ r: UsageProcessRequest) -> UsageProcessResult {
                UsageProcessResult(lines: ["devin 2.3.4"], outcome: .exited(0))
            }
        }
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.local/share/devin/credentials.toml"] = #"api_key = "broken\"#.data(using: .utf8)
        creds.files["/tmp/e/.config/devin/credentials.toml"] = #"api_key = "weaker""#.data(using: .utf8)
        let rows = DevinUsageCollector(enabled: true, http: http, credentials: creds,
                                       runner: Runner(), cli: URL(fileURLWithPath: "/usr/bin/devin"),
                                       clientVersion: "1.0", home: home).collect()
        #expect(rows.first?.state != .ok && http.requests.isEmpty)
    }

    @Test("devin banner noise version produces no request")
    func devinBadVersion() {
        struct Runner: UsageProcessRunner {
            func run(_ r: UsageProcessRequest) -> UsageProcessResult {
                UsageProcessResult(lines: ["banner noise no version"], outcome: .exited(0))
            }
        }
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.local/share/devin/credentials.toml"] = #"api_key = "k""#.data(using: .utf8)
        let rows = DevinUsageCollector(enabled: true, http: http, credentials: creds,
                                       runner: Runner(), cli: URL(fileURLWithPath: "/usr/bin/devin"),
                                       clientVersion: "1.0", home: home).collect()
        #expect(rows.first?.state == .unavailable(.cliMissing) && http.requests.isEmpty)
    }

    @Test("opencode override data dir reads <dir>/auth.json directly")
    func opencodeOverride() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/override/auth.json"] = #"{"opencode-go":{"type":"api","key":"g"}}"#.data(using: .utf8)
        let c = OpenCodeUsageCollector(enabled: true, http: http, credentials: creds, home: home,
                                       environment: ["OPENCODE_DATA_DIR": "/tmp/override"])
        #expect(c.collect().first?.state != .unavailable(.noSignIn))
    }

    @Test("opencode successful read is subscription Go")
    func opencodeGo() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/e/.local/share/opencode/auth.json"] = #"{"opencode-go":{"type":"api","key":"g"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"usage":{"weekly":{"percent":40,"resetsAt":null}}}"#.data(using: .utf8)!)]
        let row = OpenCodeUsageCollector(enabled: true, http: http, credentials: creds, home: home)
            .collect().first
        #expect(row?.state == .ok && row?.plan == "Go" && row?.authentication == .subscription)
    }

    @Test("credential reader rejects Int.max limit and non-regular paths")
    func readerBounds() {
        #expect(UsageFileCredentialReader(limit: Int.max).read(URL(fileURLWithPath: "/tmp/e")) == nil)
        #expect(UsageFileCredentialReader().read(URL(fileURLWithPath: "/tmp")) == nil)
    }
}

@Suite("Cursor bounded credentials")
struct CursorCredentialTests {
    private let home = URL(fileURLWithPath: "/tmp/cx")

    @Test("disabled does zero keychain probes and zero file reads")
    func disabled() {
        let runner = FakeUsageRunner(); let creds = SpyCredentials()
        let c = CursorUsageCollector(enabled: false, runner: runner,
                                   http: FakeUsageHTTP(), home: home, credentials: creds)
        #expect(c.collect().isEmpty)
        #expect(creds.reads == 0)
        #expect(runner.requests.isEmpty)
    }

    @Test("keychain overflow is authoritative-bad, no file fallback")
    func overflow() {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .outputLimit) }
        let creds = SpyCredentials()
        creds.files["/tmp/cx/.cursor/auth.json"] = #"{"accessToken":"filetoken"}"#.data(using: .utf8)
        let c = CursorUsageCollector(enabled: true, runner: runner,
                                   http: FakeUsageHTTP(), home: home, credentials: creds)
        let rows = c.collect()
        #expect(rows.first?.state == .unavailable(.noSignIn))
        #expect(creds.reads == 0) // never reached the file
    }

    @Test("malformed nonempty keychain token is authoritative-bad, no fallback")
    func malformed() {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: ["bad\ntoken"], outcome: .exited(0)) }
        let creds = SpyCredentials()
        creds.files["/tmp/cx/.cursor/auth.json"] = #"{"accessToken":"filetoken"}"#.data(using: .utf8)
        let c = CursorUsageCollector(enabled: true, runner: runner,
                                   http: FakeUsageHTTP(), home: home, credentials: creds)
        let rows = c.collect()
        #expect(rows.first?.state == .unavailable(.noSignIn))
        #expect(creds.reads == 0)
    }

    @Test("ordinary keychain failure falls back to bounded auth file")
    func fallback() {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .failedToStart) }
        let creds = SpyCredentials()
        creds.files["/tmp/cx/.cursor/auth.json"] = #"{"accessToken":"filetoken"}"#.data(using: .utf8)
        let c = CursorUsageCollector(enabled: true, runner: runner,
                                   http: FakeUsageHTTP(), home: home, credentials: creds)
        _ = c.collect()
        #expect(creds.reads == 1)
    }

    @Test("missing local credential is noSignIn")
    func missingCredential() {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .failedToStart) }
        let creds = SpyCredentials()
        let http = FakeUsageHTTP()
        let c = CursorUsageCollector(enabled: true, runner: runner,
            http: http, home: home, credentials: creds)
        #expect(c.collect().first?.state == .unavailable(.noSignIn))
        #expect(http.calls.isEmpty)
    }

    @Test("server 401 and 403 reject a present credential", arguments: [401, 403])
    func rejectedCredential(status: Int) {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .failedToStart) }
        let creds = SpyCredentials()
        creds.files["/tmp/cx/.cursor/auth.json"] = #"{"accessToken":"filetoken"}"#.data(using: .utf8)
        let http = FakeUsageHTTP()
        http.respond = { _ in (status: status, body: Data()) }
        let c = CursorUsageCollector(enabled: true, runner: runner,
            http: http, home: home, credentials: creds)
        expectRefusedWithoutRetainedWindows(c.collect().first)
        #expect(http.calls.count == 1)
    }
}

extension GrokAdapterTests {
    @Test("one expired plus one valid entry still uses the valid token")
    func expiredPlusValid() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/grok-home/.grok/auth.json"] = #"{"https://auth.x.ai":{"key":"old","expires_at":"2020-01-01T00:00:00Z"},"https://auth.x.ai::b":{"key":"k1","expires_at":"2999-01-01T00:00:00Z"}}"#.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 200, body: #"{"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2023-11-20T00:00:00Z"},"subscriptionTier":"x"}}"#.data(using: .utf8)!)]
        let row = collector(http, creds).collect().first
        #expect(row?.state == .ok)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer k1")
    }
}

@Suite("Sign-in reason text")
struct SignInReasonTests {
    @Test("noSignIn names the provider; signInExpired names the CLI command")
    func reasons() {
        L10n.language = .en
        #expect(UsageText.problem(.noSignIn, provider: .grok).contains("Grok"))
        #expect(UsageText.problem(.signInExpired, provider: .gemini).contains("gemini"))
        #expect(UsageText.cliCommand(.cursor) == "cursor-agent login")
        #expect(UsageText.cliCommand(.antigravity) == "agy")
    }
}


final class FakeGeminiClientFinder: GeminiOAuthClientFinding, @unchecked Sendable {
    var client: (id: String, secret: String)?
    init(_ client: (id: String, secret: String)? = nil) { self.client = client }
    func client(for cli: URL?) -> (id: String, secret: String)? { client }
}

/// Synthetic OAuth client shapes, assembled at runtime so no source literal looks like a credential.
private enum FakeGoogleClient {
    static let host = ["apps", "googleusercontent", "com"].joined(separator: ".")
    static func id(_ prefix: String) -> String { "\(prefix).\(host)" }
    static let secret = ["GOCSPX", String(repeating: "x", count: 28)].joined(separator: "-")
}

@Suite("Gemini token refresh")
struct GeminiRefreshTests {
    private let home = URL(fileURLWithPath: "/tmp/gemini-refresh-home")
    private let expiredFile = #"{"access_token":"old","expiry_date":1,"refresh_token":"r1"}"#
    private let assist = #"{"cloudaicompanionProject":"p"}"#
    private let quota = #"{"buckets":[{"modelId":"g","remainingFraction":0.5,"resetTime":"2023-11-20T00:00:00Z"}]}"#
    private let client = (id: FakeGoogleClient.id("1-abc"), secret: FakeGoogleClient.secret)

    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           allowed: Bool = true,
                           finder: GeminiOAuthClientFinding = FakeGeminiClientFinder(nil),
                           cache: GeminiAccessTokenCache = GeminiAccessTokenCache()) -> GeminiUsageCollector {
        GeminiUsageCollector(enabled: true, http: http, credentials: creds,
                             runner: FakeUsageRunner(), home: home,
                             refreshAllowed: allowed, cli: URL(fileURLWithPath: "/x/@google/gemini-cli/bin/gemini"),
                             clientFinder: finder, tokenCache: cache,
                             now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test("expired token exchanges once and reuses the cache; different refresh key re-exchanges")
    func exchangeAndCache() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-refresh-home/.gemini/oauth_creds.json"] = expiredFile.data(using: .utf8)
        let cache = GeminiAccessTokenCache()
        let finder = FakeGeminiClientFinder(client)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"access_token":"new-access","expires_in":3600,"refresh_token":"ignored"}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: assist.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: quota.data(using: .utf8)!),
        ]
        let first = collector(http, creds, finder: finder, cache: cache).collect().first
        #expect(first?.state == .ok)
        #expect(http.requests.count == 3)
        #expect(http.requests[0].url.host == "oauth2.googleapis.com")
        let form = String(decoding: http.requests[0].body ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token") && form.contains("client_id=\(FakeGoogleClient.id("1-abc"))"))
        #expect(http.requests[1].headers["Authorization"] == "Bearer new-access")
        // second collect inside the lifetime: cached token, no new exchange
        http.queue = [
            UsageHTTPResponse(status: 200, body: assist.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: quota.data(using: .utf8)!),
        ]
        let second = collector(http, creds, finder: finder, cache: cache).collect().first
        #expect(second?.state == .ok && http.requests.count == 5)
        // a different refresh token keys a different cache entry → re-exchange
        creds.files["/tmp/gemini-refresh-home/.gemini/oauth_creds.json"] =
            #"{"access_token":"old","expiry_date":1,"refresh_token":"r2"}"#.data(using: .utf8)
        http.queue = [
            UsageHTTPResponse(status: 200, body: #"{"access_token":"newer","expires_in":3600}"#.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: assist.data(using: .utf8)!),
            UsageHTTPResponse(status: 200, body: quota.data(using: .utf8)!),
        ]
        _ = collector(http, creds, finder: finder, cache: cache).collect()
        #expect(http.requests.count == 8)
    }

    @Test("exchange 400 reports signInExpired; no client or no permission sends zero requests")
    func failureModes() {
        let http = SpyTransport(); let creds = SpyCredentials()
        creds.files["/tmp/gemini-refresh-home/.gemini/oauth_creds.json"] = expiredFile.data(using: .utf8)
        http.queue = [UsageHTTPResponse(status: 400, body: Data())]
        #expect(collector(http, creds, finder: FakeGeminiClientFinder(client)).collect().first?.state
                == .unavailable(.signInExpired))
        #expect(http.requests.count == 1)
        http.queue = []
        #expect(collector(http, creds).collect().first?.state == .unavailable(.signInExpired))
        #expect(http.requests.count == 1)
        #expect(collector(http, creds, allowed: false,
                        finder: FakeGeminiClientFinder(client)).collect().first?.state
                == .unavailable(.signInExpired))
        #expect(http.requests.count == 1)
    }
}

@Suite("Gemini OAuth client scan")
struct GeminiOAuthScanTests {
    private func package(_ files: [(name: String, body: String, sizePad: Int)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcli-\(UUID().uuidString)/@google/gemini-cli")
        let bundle = dir.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for f in files {
            try (f.body + String(repeating: " ", count: f.sizePad)).write(
                to: bundle.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
        }
        return dir.appendingPathComponent("bin/gemini")
    }

    private let id = FakeGoogleClient.id("123-abc")
    private let secret = FakeGoogleClient.secret

    @Test("three identical copies are accepted and cached")
    func identical() throws {
        let body = #"var OAUTH_CLIENT_ID = "\#(id)"; var OAUTH_CLIENT_SECRET = "\#(secret)";"#
        let cli = try package([("a.js", body, 0), ("b.js", body, 0), ("c.js", body, 0)])
        #expect(GeminiOAuthClientFinder().client(for: cli)?.id == id)
    }

    @Test("an in-place bundle rewrite is rescanned by the same finder")
    func rescansInPlaceUpdate() throws {
        let cli = try package([("a.js", #"OAUTH_CLIENT_ID = "\#(id)"; OAUTH_CLIENT_SECRET = "\#(secret)";"#, 0)])
        let finder = GeminiOAuthClientFinder()
        #expect(finder.client(for: cli)?.id == id)
        let file = cli.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bundle/a.js")
        let other = FakeGoogleClient.id("456-def")
        try #"OAUTH_CLIENT_ID = "\#(other)"; OAUTH_CLIENT_SECRET = "\#(secret)";"#
            .write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: file.path)
        #expect(finder.client(for: cli)?.id == other)
    }

    @Test("two different values or malformed shapes are rejected")
    func rejects() throws {
        let a = #"OAUTH_CLIENT_ID = "\#(id)"; OAUTH_CLIENT_SECRET = "\#(secret)";"#
        let b = #"OAUTH_CLIENT_ID = "\#(FakeGoogleClient.id("999-zzz"))"; OAUTH_CLIENT_SECRET = "\#(secret)";"#
        let bad = #"OAUTH_CLIENT_ID = "not-an-id"; OAUTH_CLIENT_SECRET = "not-a-secret";"#
        #expect(GeminiOAuthClientFinder().client(for: try package([("a.js", a, 0), ("b.js", b, 0)])) == nil)
        #expect(GeminiOAuthClientFinder().client(for: try package([("a.js", bad, 0)])) == nil)
        // an oversized file is skipped — the valid pair in the small file still wins
        let cli = try package([("big.js", bad, 33 * 1024 * 1024), ("a.js", a, 0)])
        #expect(GeminiOAuthClientFinder().client(for: cli)?.id == id)
    }
}


@Suite("Gemini refresh consent pair")
struct GeminiConsentPairTests {
    @Test("extra entry pairs with the provider; unknown values never enable providers")
    func pair() {
        // grant stores the pair; the extra entry alone can never enable the provider
        let granted = SwitcherSettings(usageConnections: ["gemini", "gemini.tokenRefresh"])
        #expect(granted.geminiTokenRefreshAllowed)
        #expect(granted.enabledUsageProviders.contains(.gemini))
        let extraOnly = SwitcherSettings(usageConnections: ["gemini.tokenRefresh", "bogus.x"])
        #expect(extraOnly.geminiTokenRefreshAllowed)
        #expect(extraOnly.enabledUsageProviders.isEmpty)
        // revoke removes both — neither entry remains
        let revoked = SwitcherSettings(usageConnections: nil)
        #expect(!revoked.geminiTokenRefreshAllowed)
        #expect(revoked.enabledUsageProviders.isEmpty)
    }
}


@Suite("usageConnections persistence")
struct UsageConnectionsValueTests {
    @Test("gemini grant pairs the refresh entry; unrelated toggles preserve it")
    func builder() {
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.gemini], geminiTokenRefresh: true)
                == ["gemini", "gemini.tokenRefresh"])
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.gemini, .grok], geminiTokenRefresh: true)
                == ["gemini", "gemini.tokenRefresh", "grok"])
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.gemini], geminiTokenRefresh: true)
                == ["gemini", "gemini.tokenRefresh"])
        #expect(SwitcherSettings.usageConnectionsValue(providers: [], geminiTokenRefresh: false) == nil)
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.grok], geminiTokenRefresh: true)
                == ["grok"])
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.gemini], geminiTokenRefresh: false)
                == ["gemini"])
    }
}
