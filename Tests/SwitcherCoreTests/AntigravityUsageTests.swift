import Darwin
import CryptoKit
import Foundation
import Testing
@testable import SwitcherCore

private struct FixedScreen: AntigravityUsageScreenReading {
    let result: AntigravityScreenResult

    func read(executable: URL?, now: Date) -> AntigravityScreenResult { result }
}

private final class CountingScreen: AntigravityUsageScreenReading, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [AntigravityScreenResult]
    private var index = 0
    private var count = 0

    init(_ results: [AntigravityScreenResult]) {
        self.results = results
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func read(executable: URL?, now: Date) -> AntigravityScreenResult {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        guard index < results.count else {
            return results.last ?? .failure(.failed(.timeout))
        }
        defer { index += 1 }
        return results[index]
    }
}

private struct FixedPTY: AntigravityPTYExecuting {
    let data: Data

    func run(executable: URL, workingDirectory: URL,
             environment: [String: String]) -> AntigravityPTYResult {
        AntigravityPTYResult(outcome: .completed, output: data, childPID: nil)
    }
}

private final class RecordingPTY: AntigravityPTYExecuting, @unchecked Sendable {
    let data: Data
    private(set) var workingDirectory: URL?

    init(data: Data) { self.data = data }

    func run(executable: URL, workingDirectory: URL,
             environment: [String: String]) -> AntigravityPTYResult {
        self.workingDirectory = workingDirectory
        return AntigravityPTYResult(outcome: .completed, output: data, childPID: nil)
    }
}

private final class MutableUsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        date.addTimeInterval(interval)
        lock.unlock()
    }
}

@Suite("Antigravity VT parser hardening (audit B-09)")
struct AntigravityVTParserTests {
    private func screen(_ bytes: String, columns: Int = 40, rows: Int = 4) -> AntigravityVTScreenBuffer {
        var buffer = AntigravityVTScreenBuffer(columns: columns, rows: rows)
        buffer.feed(Data(bytes.utf8))
        return buffer
    }

    @Test func hugeControlParametersAreClamped() {
        // Int.max parameters must not trap or corrupt the buffer — each value() read clamps
        // to 10,000 (audit B-09).
        let max_ = "\u{1b}[9223372036854775807"
        for final in ["C", "B", "A", "D", "G", "d", "H"] {
            var buffer = AntigravityVTScreenBuffer(columns: 40, rows: 4)
            buffer.feed(Data(("x" + max_ + final).utf8))
            _ = buffer.lines
        }
        // an unknown final marks the buffer untrusted instead of trusting a half-parsed screen
        var buffer = AntigravityVTScreenBuffer(columns: 40, rows: 4)
        buffer.feed(Data("\u{1b}[5z".utf8))
        #expect(buffer.untrusted)
    }

    @Test("the prompt marker row is seen (audit B-09)")
    func promptMarkerRow() {
        var buffer = AntigravityVTScreenBuffer(columns: 80, rows: 4)
        buffer.feed(Data("? for shortcuts\n".utf8))
        #expect(buffer.hasMainInputPrompt)
        #expect(!buffer.untrusted)
    }

    @Test("stage-by-stage capture state (audit B-09)")
    func captureStages() throws {
        let data = try Data(contentsOf:
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Antigravity/agy-usage-raw.bin"))
        var stage1 = AntigravityVTScreenBuffer()
        stage1.feed(data[0..<2980])
        #expect(!stage1.untrusted)
        #expect(stage1.hasMainInputPrompt)
        stage1.feed(data[2980..<3909])
        #expect(stage1.hasUsageInput)
        stage1.feed(data[3909..<6809])
        #expect(stage1.hasQuotaTitle)
    }

    @Test("the real capture leaves the buffer trusted (audit B-09)")
    func realCaptureStaysTrusted() throws {
        var buffer = AntigravityVTScreenBuffer()
        buffer.feed(try Data(contentsOf:
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Antigravity/agy-usage-raw.bin")))
        #expect(!buffer.untrusted)
    }

    @Test("safe sequences stay trusted, grid-changing ones do not")
    func trustedSequenceRules() {
        // ESC[31m SGR, ESC[>4;1m private, ESC[ q intermediate, ESC[?25l mode: all no-ops.
        for seq in ["\u{1b}[31m", "\u{1b}[>4;1m", "\u{1b}[ q", "\u{1b}[?25l"] {
            var buffer = AntigravityVTScreenBuffer(columns: 20, rows: 2)
            buffer.feed(Data(seq.utf8))
            #expect(!buffer.untrusted, "\(seq.debugDescription) marked untrusted")
        }
        // Unimplemented cursor/cell movement marks untrusted.
        for seq in ["\u{1b}[2L", "\u{1b}[3S"] {
            var buffer = AntigravityVTScreenBuffer(columns: 20, rows: 2)
            buffer.feed(Data(seq.utf8))
            #expect(buffer.untrusted, "\(seq.debugDescription) stayed trusted")
        }
    }

    @Test func eraseCharacterClearsCells() {
        // `> /usage` followed by stray text, then cursor back to col 9 + ESC[39X blanks the
        // trailing cells and the exact `/usage` row returns (audit B-09).
        var buffer = AntigravityVTScreenBuffer(columns: 80, rows: 4)
        buffer.feed(Data("> /usage garbage\u{1b}[9G\u{1b}[39X".utf8))
        let row = buffer.lines.first { $0.hasPrefix(">") } ?? ""
        #expect(row == "> /usage")
        #expect(buffer.hasUsageInput)
        // the real echo row carries a hint after whitespace — still the /usage command
        var hint = AntigravityVTScreenBuffer(columns: 80, rows: 4)
        hint.feed(Data("> /usage   View model quota usage".utf8))
        #expect(hint.hasUsageInput)
        // a different command sharing the prefix is not a match
        var other = AntigravityVTScreenBuffer(columns: 80, rows: 4)
        other.feed(Data("> /usage-report".utf8))
        #expect(!other.hasUsageInput)
    }

    @Test func deleteTabAndReverseIndexWork() {
        // DCH removes cells in place: "0123" + "6789".
        var dch = AntigravityVTScreenBuffer(columns: 20, rows: 2)
        dch.feed(Data("0123456789\u{1b}[5G\u{1b}[2P".utf8))
        #expect(dch.lines[0].hasPrefix("01236789"))
        // CBT from column 16 back two tab stops lands at column 0.
        var cbt = AntigravityVTScreenBuffer(columns: 40, rows: 2)
        cbt.feed(Data("aaaaaaaaaaaaaaaa\u{1b}[2ZX".utf8))
        #expect(cbt.lines[0].hasPrefix("X"))
        // RI at row 0 scrolls the screen content down one line.
        var ri = AntigravityVTScreenBuffer(columns: 10, rows: 3)
        ri.feed(Data("top\u{1b}M".utf8))
        #expect(ri.lines[1].hasPrefix("top"))
    }
}


@Suite("Antigravity screen parser")
struct AntigravityScreenTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Antigravity/agy-usage-raw.bin")
    }

    @Test("redacted agy capture produces the five quota windows")
    func capture() throws {
        let bytes = try Data(contentsOf: fixture)
        let windows = try #require(AntigravityUsageScreen.parse(
            bytes, now: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(windows.count == 5)
        #expect(windows.map(\.scope) == [
            "Gemini Models", "Gemini Models", "Claude And Gpt Models",
            "Claude And Gpt Models", "Gemini 4 Argon",
        ])
        #expect(windows.map(\.durationMinutes) == [10_080, 300, 10_080, 300, 10_080])
        #expect(windows.allSatisfy { $0.usedPercent == 0 && $0.resetsAt == nil })
    }

    @Test("remaining percentage is inverted to used percentage")
    func remainingPercentage() throws {
        let data = Data("""
        Models & Quota
        GEMINI MODELS
        Weekly Limit Remaining
        [████] 37.5%
        """.utf8)
        let windows = try #require(AntigravityUsageScreen.parse(data, now: Date()))
        #expect(windows.count == 1)
        #expect(windows[0].usedPercent == 62.5)
        #expect(windows[0].durationMinutes == 10_080)
    }

    @Test("unrecognized screen fails so the caller can use the API")
    func missingTitle() {
        let screen = AntigravityUsageScreen(runner: FixedPTY(data: Data("no quota here".utf8)))
        let result = screen.read(executable: URL(fileURLWithPath: "/bin/agy"), now: Date())
        #expect(result.state == .unavailable(.schemaChanged))
        #expect(result.windows.isEmpty)
    }

    @Test("cursor movement, overwrite, erase controls, and alternate-screen clearing")
    func terminalControls() {
        var terminal = AntigravityVTScreenBuffer(columns: 12, rows: 3)
        terminal.feed(Data("abc\u{1b}[2DXY".utf8))
        #expect(terminal.lines[0].hasPrefix("aXY"))
        terminal.feed(Data("\u{1b}[2G\u{1b}[K".utf8))
        #expect(terminal.lines[0] == "a")
        terminal.feed(Data("\u{1b}[2J".utf8))
        #expect(terminal.lines.allSatisfy { $0.isEmpty })
        terminal.feed(Data("abc\u{1b}[?1049hXY".utf8))
        #expect(terminal.lines[0] == "XY")
    }

    @Test("main input marker gates usage and trust prompt blocks it")
    func promptGate() {
        var input = AntigravityVTScreenBuffer()
        input.feed(Data("Welcome\n? for shortcuts\n> /usage".utf8))
        #expect(input.hasMainInputPrompt)
        #expect(input.hasUsageInput)
        #expect(!input.hasTrustPrompt)

        var trust = AntigravityVTScreenBuffer()
        trust.feed(Data("Do you trust the contents of this project?\n> Yes, I trust this folder".utf8))
        #expect(trust.hasTrustPrompt)
        #expect(!trust.hasMainInputPrompt)
        #expect(!trust.hasUsageInput)
    }

    @Test("agy screen reader uses the user's home directory")
    func homeDirectory() throws {
        let data = try Data(contentsOf: fixture)
        let runner = RecordingPTY(data: data)
        let reader = AntigravityUsageScreen(runner: runner)
        let result = reader.read(executable: URL(fileURLWithPath: "/bin/agy"), now: Date())
        #expect(result.state == .ok)
        #expect(runner.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test("unambiguous relative screen reset is parsed")
    func relativeReset() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data("""
        Models & Quota
        GEMINI MODELS
        Weekly Limit Remaining
        [████] 90%
        Resets in 1d 2h 3m
        """.utf8)
        let windows = try #require(AntigravityUsageScreen.parse(data, now: now))
        #expect(windows[0].resetsAt == now.addingTimeInterval(93_780))
    }
}

@Suite("Antigravity adapter", .serialized)
struct AntigravityUsageTests {
    private let home = URL(fileURLWithPath: "/tmp/antigravity-home")
    private let tokenPath = "/tmp/antigravity-home/.gemini/jetski-standalone-oauth-token"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func screen(_ state: UsageState = .failed(.timeout),
                        windows: [UsageWindow] = []) -> FixedScreen {
        FixedScreen(result: AntigravityScreenResult(state: state, windows: windows))
    }

    private func collector(_ http: SpyTransport, _ creds: SpyCredentials,
                           runner: FakeUsageRunner = FakeUsageRunner(),
                           screen: (any AntigravityUsageScreenReading)? = nil,
                           cache: AntigravityAccessTokenCache = AntigravityAccessTokenCache(),
                           screenCache: AntigravityUsageScreenCache = AntigravityUsageScreenCache(),
                           clock: MutableUsageClock? = nil,
                           agy: URL? = URL(fileURLWithPath: "/tmp/agy")) -> AntigravityUsageCollector {
        let fixedNow = self.now
        return AntigravityUsageCollector(
            enabled: true, http: http, credentials: creds, runner: runner,
            screen: screen ?? self.screen(), tokenCache: cache, screenCache: screenCache, home: home,
            agy: agy,
            now: { clock?.now() ?? fixedNow })
    }

    private func legacyToken(_ credentials: SpyCredentials, expiry: String = "2999-01-01T00:00:00Z") {
        credentials.files[tokenPath] =
            #"{"token":{"access_token":"access-only","expiry":"\#(expiry)"}}"#.data(using: .utf8)
    }

    private func project(_ id: String = "project-1") -> UsageHTTPResponse {
        UsageHTTPResponse(status: 200,
                          body: #"{"cloudaicompanionProject":"\#(id)"}"#.data(using: .utf8)!)
    }

    private func quota(_ body: String? = nil) -> UsageHTTPResponse {
        UsageHTTPResponse(status: 200, body: Data((body ?? Self.summary).utf8))
    }

    private static let summary = #"{"groups":[{"displayName":"Claude And Gpt Models","buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-11-15T03:13:50Z","remainingFraction":0.75},{"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","resetTime":"2026-11-08T08:13:50Z","remainingFraction":0.25},{"window":"daily","remainingFraction":0}] }]}"#

    @Test("disabled does no subprocess, file, or network access")
    func disabled() {
        let http = SpyTransport(); let credentials = SpyCredentials(); let runner = FakeUsageRunner()
        let disabled = AntigravityUsageCollector(enabled: false, http: http,
            credentials: credentials, runner: runner, home: home)
        #expect(disabled.collect().isEmpty)
        #expect(runner.requests.isEmpty && credentials.reads == 0 && http.requests.isEmpty)
    }

    @Test("maps real quota summary, skips unknown windows, and sends required headers")
    func mapsSummary() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota()]
        let row = collector(http, credentials, runner: missingKeychain()).collect().first
        #expect(row?.state == .ok)
        #expect(row?.windows.map(\.scope) == ["Claude And Gpt Models", "Claude And Gpt Models"])
        #expect(row?.windows.map(\.durationMinutes) == [10_080, 300])
        #expect(row?.windows.map(\.usedPercent) == [25, 75])
        #expect(row?.windows[0].resetsAt == UsageJSON.resetDateISO("2026-11-15T03:13:50Z"))
        #expect(http.requests.map(\.url.lastPathComponent)
                == ["v1internal:loadCodeAssist", "v1internal:retrieveUserQuotaSummary"])
        #expect(http.requests.allSatisfy { $0.headers["User-Agent"] == "antigravity" })
        #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer access-only" })
    }

    @Test("no valid summary buckets is schema changed")
    func noValidBuckets() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"daily","remainingFraction":1}]}]}"#)]
        #expect(collector(http, credentials, runner: missingKeychain()).collect().first?.state
                == .unavailable(.schemaChanged))
    }

    @Test("only fresh legacy access tokens are used when Keychain is absent")
    func expiredLegacyToken() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        credentials.files[tokenPath] =
            #"{"token":{"access_token":"old-access","expiry":"2020-01-01T00:00:00Z"}}"#.data(using: .utf8)
        let result = collector(http, credentials, runner: missingKeychain()).collect().first
        #expect(result?.state == .unavailable(.signInExpired))
        #expect(http.requests.isEmpty)
    }

    @Test("quota transport failure is a network failure")
    func transportFailure() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), nil]
        let result = collector(http, credentials, runner: missingKeychain()).collect().first
        #expect(result?.state == .failed(.network))
    }

    @Test("quota API status mapping", arguments: [401, 403, 429])
    func quotaStatus(_ status: Int) {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), UsageHTTPResponse(status: status, body: Data())]
        let result = collector(http, credentials, runner: missingKeychain()).collect().first
        #expect(result?.state == (status == 429 ? .failed(.rateLimited) : .failed(.signInRejected)))
    }

    @Test("quota API sign-in rejection wins over the screen result")
    func quotaRejectionPreferred() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), UsageHTTPResponse(status: 403, body: Data())]
        let result = collector(http, credentials, runner: missingKeychain()).collect().first
        #expect(result?.state == .failed(.signInRejected))
    }

    @Test("token-exchange authorization failures outrank a screen timeout", arguments: [400, 401])
    func tokenExchangeFailure(_ status: Int) {
        let http = SpyTransport(); let credentials = SpyCredentials()
        let runner = keychainRunner()
        http.queue = [UsageHTTPResponse(status: status, body: Data())]
        let result = collector(http, credentials, runner: runner).collect().first
        #expect(result?.state == .unavailable(.noSignIn))
        #expect(http.requests.first?.url.host == "oauth2.googleapis.com")
    }

    @Test("uses Keychain project id when loadCodeAssist fails")
    func projectFallback() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        let runner = keychainRunner()
        http.queue = [
            tokenResponse("access-from-grant"),
            UsageHTTPResponse(status: 500, body: Data()),
            quota(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":1,"resetTime":"2026-11-15T03:13:50Z"}]}]}"#),
        ]
        let row = collector(http, credentials, runner: runner).collect().first
        #expect(row?.state == .ok)
        #expect(String(data: http.requests.last?.body ?? Data(), encoding: .utf8) == #"{"project":"project-fallback"}"#)
    }

    @Test("refresh access token is cached until its safety expiry and response refresh token is ignored")
    func tokenCache() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        let runner = keychainRunner()
        let clock = MutableUsageClock(now)
        http.queue = [
            tokenResponse("access-one"),
            project(), quota(#"{"groups":[{"displayName":"Claude And Gpt Models","buckets":[{"window":"weekly","remainingFraction":1,"resetTime":"2026-11-15T03:13:50Z"}]}]}"#),
            project(), quota(#"{"groups":[{"displayName":"Claude And Gpt Models","buckets":[{"window":"weekly","remainingFraction":1,"resetTime":"2026-11-15T03:13:50Z"}]}]}"#),
            tokenResponse("access-two"),
            project(), quota(#"{"groups":[{"displayName":"Claude And Gpt Models","buckets":[{"window":"weekly","remainingFraction":1,"resetTime":"2026-11-15T03:13:50Z"}]}]}"#),
        ]
        let c = collector(http, credentials, runner: runner, cache: AntigravityAccessTokenCache(), clock: clock)
        #expect(c.collect().first?.state == .ok)
        #expect(c.collect().first?.state == .ok)
        clock.advance(3_541)
        #expect(c.collect().first?.state == .ok)
        let tokenRequests = http.requests.filter { $0.url.host == "oauth2.googleapis.com" }
        #expect(tokenRequests.count == 2)
        #expect(runner.requests.count == 3)
        let quotaRequests = http.requests.filter { $0.url.host == "cloudcode-pa.googleapis.com" }
        #expect(quotaRequests.count == 6)
        #expect(quotaRequests[0].headers["Authorization"] == "Bearer access-one")
        #expect(quotaRequests[2].headers["Authorization"] == "Bearer access-one")
        #expect(quotaRequests[4].headers["Authorization"] == "Bearer access-two")
        #expect(quotaRequests.allSatisfy { $0.headers["User-Agent"] == "antigravity" })
        #expect(!quotaRequests.contains { ($0.headers["Authorization"] ?? "").contains("response-refresh") })
    }

    @Test("account changes clear cached screen data but preserve the recent read throttle")
    func changedKeychainAccountClearsCaches() {
        let http = SpyTransport()
        http.queue = [
            tokenResponse("fresh-access"),
            project(),
            quota(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"weekly","remainingFraction":0.45,"resetTime":"2026-11-15T03:13:50Z"}]}]}"#),
        ]
        let credentials = SpyCredentials()
        let runner = keychainRunner(refreshToken: "new-refresh")
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        tokenCache.updateAccountFingerprint(refreshFingerprint("old-refresh"), screenCache: screenCache)
        tokenCache.store(accessToken: "old-access", validUntil: now.addingTimeInterval(3600),
                         projectID: "old-project")
        screenCache.store([UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                       usedPercent: 5, resetsAt: nil)],
                          readAt: now.addingTimeInterval(-60))
        let screen = CountingScreen([
            .success([UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                 usedPercent: 55, resetsAt: nil)])
        ])

        let row = collector(http, credentials, runner: runner, screen: screen,
                            cache: tokenCache, screenCache: screenCache).collect().first

        #expect(abs((row?.windows.first?.usedPercent ?? 0) - 55) < 0.0001)
        #expect(screen.readCount == 0)
        guard case .throttled = screenCache.acquire(at: now) else {
            Issue.record("expected screen data to be cleared while retaining the throttle")
            return
        }
        #expect(runner.requests.count == 1)
        let tokenRequest = try? #require(http.requests.first { $0.url.host == "oauth2.googleapis.com" })
        #expect(String(data: tokenRequest?.body ?? Data(), encoding: .utf8)?.contains("new-refresh") == true)
        let quotaRequest = http.requests.last
        #expect(quotaRequest?.headers["Authorization"] == "Bearer fresh-access")
    }

    @Test("unchanged refresh-token identity retains both caches")
    func unchangedKeychainAccountKeepsCaches() {
        let http = SpyTransport()
        http.queue = [project(), quota()]
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        tokenCache.updateAccountFingerprint(refreshFingerprint("old-refresh"), screenCache: screenCache)
        tokenCache.store(accessToken: "cached-access", validUntil: now.addingTimeInterval(3600),
                         projectID: "cached-project")
        screenCache.store([UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                       usedPercent: 15, resetsAt: nil)], readAt: now)
        let screen = CountingScreen([
            .success([UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                 usedPercent: 65, resetsAt: nil)])
        ])

        let row = collector(http, SpyCredentials(), runner: keychainRunner(refreshToken: "old-refresh"),
                            screen: screen, cache: tokenCache, screenCache: screenCache).collect().first

        #expect(row?.windows.first?.usedPercent == 15)
        #expect(screen.readCount == 0)
        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer cached-access" })
    }

    @Test("a Keychain failure does not publish the cached account (audit B-09)")
    func aKeychainFailureDoesNotPublishTheCachedAccount() {
        // An unverified keychain read returns .failed(.timeout): cached token and screen
        // values are not published — the screen cache itself is kept.
        let http = SpyTransport()
        http.queue = [tokenResponse("cached-access"), project(), quota(), project(), quota()]
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let cachedWindows = [UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                         usedPercent: 35, resetsAt: nil)]
        let screen = CountingScreen([.success(cachedWindows)])

        let first = collector(http, SpyCredentials(), runner: keychainRunner(),
                              screen: screen, cache: tokenCache, screenCache: screenCache)
            .collect().first
        let second = collector(http, SpyCredentials(), runner: timeoutKeychain(),
                               screen: screen, cache: tokenCache, screenCache: screenCache)
            .collect().first

        #expect(first?.windows == cachedWindows)
        #expect(second?.state != .ok)
        #expect(second?.state == .failed(.timeout))
        #expect(screen.readCount == 1) // the screen cache was not re-read or cleared
        let quotaRequests = http.requests.filter { $0.url.host == "cloudcode-pa.googleapis.com" }
        #expect(quotaRequests.count == 2) // no quota call on the unverified read
    }

    @Test("the same window has one scope on both read paths (audit B-09)")
    func theSameWindowHasOneScopeOnBothPaths() {
        // canonical keeps the screen spelling so pins stay valid; API-case variants fold in.
        #expect(AntigravityScope.canonical("Gemini Models") == "Gemini Models")
        #expect(AntigravityScope.canonical("gemini models") == "Gemini Models")
        #expect(AntigravityScope.canonical("GEMINI MODELS") == "Gemini Models")
        #expect(AntigravityScope.canonical("claude and gpt models") == "Claude And Gpt Models")
    }

    @Test("an expired cache on a transient Keychain failure does not use the legacy file")
    func expiredCacheDoesNotUseLegacyFileOnKeychainTimeout() {
        let http = SpyTransport()
        http.queue = [tokenResponse("cached-access"), project(), quota()]
        let credentials = SpyCredentials()
        legacyToken(credentials)
        let clock = MutableUsageClock(now)
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let screen = CountingScreen([.failure(.failed(.timeout))])

        let first = collector(http, credentials, runner: keychainRunner(), screen: screen,
                              cache: tokenCache, screenCache: screenCache, clock: clock)
            .collect().first
        let requestsAfterRecord = http.requests.count
        clock.advance(3_541)
        let second = collector(http, credentials, runner: timeoutKeychain(), screen: screen,
                               cache: tokenCache, screenCache: screenCache, clock: clock)
            .collect().first

        #expect(first?.state == .ok)
        #expect(second?.state == .failed(.timeout))
        #expect(http.requests.count == requestsAfterRecord)
        #expect(credentials.reads == 0)
        #expect(tokenCache.value(at: clock.now())?.accessToken == nil)
        #expect(screen.readCount == 1) // the unverified read returns before the screen runs
    }

    @Test("Keychain item not found clears old account caches when no file token exists")
    func keychainSignOutClearsCaches() {
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let screen = CountingScreen([
            .success([UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                  usedPercent: 35, resetsAt: nil)])
        ])
        let firstHTTP = SpyTransport()
        firstHTTP.queue = [tokenResponse("old-access"), project(), quota()]

        let first = collector(firstHTTP, SpyCredentials(),
                              runner: keychainRunner(refreshToken: "old-refresh"),
                              screen: screen, cache: tokenCache, screenCache: screenCache)
            .collect().first

        #expect(first?.state == .ok)
        #expect(tokenCache.value(at: now)?.accessToken == "old-access")
        #expect(first?.windows.first?.usedPercent == 35)

        let secondHTTP = SpyTransport()
        let noFileCredentials = SpyCredentials()
        let second = collector(secondHTTP, noFileCredentials, runner: missingKeychain(),
                                screen: screen, cache: tokenCache, screenCache: screenCache)
            .collect().first

        #expect(second?.state == .unavailable(.noSignIn))
        #expect(second?.windows.isEmpty == true)
        #expect(noFileCredentials.reads == 1)
        #expect(secondHTTP.requests.isEmpty)
        #expect(tokenCache.value(at: now)?.accessToken == nil)
        guard case .throttled = screenCache.acquire(at: now) else {
            Issue.record("expected the old screen windows to be cleared while preserving the throttle")
            return
        }
    }

    @Test("legacy file token changes clear screen windows and use the new token")
    func changedLegacyFileTokenIsUsed() {
        let credentials = SpyCredentials()
        credentials.files[tokenPath] =
            #"{"token":{"access_token":"file-access-a","expiry":"2999-01-01T00:00:00Z"}}"#.data(using: .utf8)
        let http = SpyTransport()
        http.queue = [project(), quota(), project(), quota()]
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let cachedWindows = [UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                         usedPercent: 88, resetsAt: nil)]
        let screen = CountingScreen([.success(cachedWindows)])

        let first = collector(http, credentials, runner: missingKeychain(), screen: screen,
                              cache: tokenCache, screenCache: screenCache).collect().first
        credentials.files[tokenPath] =
            #"{"token":{"access_token":"file-access-b","expiry":"2999-01-01T00:00:00Z"}}"#.data(using: .utf8)
        let second = collector(http, credentials, runner: missingKeychain(), screen: screen,
                               cache: tokenCache, screenCache: screenCache).collect().first

        #expect(first?.windows == cachedWindows)
        #expect(second?.windows.first?.scope == "Claude And Gpt Models")
        #expect(second?.windows.first?.usedPercent == 25)
        #expect(http.requests.map { $0.headers["Authorization"] } == [
            "Bearer file-access-a", "Bearer file-access-a",
            "Bearer file-access-b", "Bearer file-access-b",
        ])
        #expect(credentials.reads == 2)
        #expect(screen.readCount == 1)
        #expect(tokenCache.value(at: now)?.accessToken == nil)
        guard case .throttled = screenCache.acquire(at: now) else {
            Issue.record("expected changed legacy credentials to clear screen windows without resetting throttle")
            return
        }
    }

    @Test("the same legacy file token retains screen windows across reads")
    func sameLegacyFileIdentityKeepsScreenCache() {
        let credentials = SpyCredentials()
        legacyToken(credentials)
        let http = SpyTransport()
        http.queue = [project(), quota(), project(), quota()]
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let cachedWindows = [UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                         usedPercent: 88, resetsAt: nil)]
        let screen = CountingScreen([.success(cachedWindows)])

        let first = collector(http, credentials, runner: missingKeychain(), screen: screen,
                              cache: tokenCache, screenCache: screenCache).collect().first
        let second = collector(http, credentials, runner: missingKeychain(), screen: screen,
                               cache: tokenCache, screenCache: screenCache).collect().first

        #expect(first?.windows == cachedWindows)
        #expect(second?.windows == cachedWindows)
        #expect(credentials.reads == 2)
        #expect(screen.readCount == 1)
        #expect(http.requests.allSatisfy {
            $0.headers["Authorization"] == "Bearer access-only"
        })
    }

    @Test("Keychain refusal leaves both caches intact")
    func refusedKeychainReadKeepsCaches() {
        let http = SpyTransport()
        let tokenCache = AntigravityAccessTokenCache()
        let screenCache = AntigravityUsageScreenCache()
        let cachedWindows = [UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                         usedPercent: 25, resetsAt: nil)]
        tokenCache.updateAccountFingerprint(refreshFingerprint("old-refresh"), screenCache: screenCache)
        tokenCache.store(accessToken: "cached-access", validUntil: now.addingTimeInterval(3600),
                         projectID: "cached-project")
        screenCache.store(cachedWindows, readAt: now)

        let row = collector(http, SpyCredentials(), runner: refusedKeychain(),
                            screen: CountingScreen([]), cache: tokenCache,
                            screenCache: screenCache).collect().first

        #expect(row?.windows == cachedWindows)
        #expect(http.requests.isEmpty)
        #expect(tokenCache.value(at: now)?.accessToken == "cached-access")
        guard case .cached(let windows, _) = screenCache.acquire(at: now) else {
            Issue.record("expected cached screen windows to remain after Keychain refusal")
            return
        }
        #expect(windows == cachedWindows)
    }

    @Test("screen windows remain primary and receive matching API reset times")
    func merge() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota()]
        let screenWindow = UsageWindow(scope: "Claude And Gpt Models", durationMinutes: 10_080,
                                       usedPercent: 10, resetsAt: nil)
        let result = collector(http, credentials, runner: missingKeychain(),
                               screen: screen(.ok, windows: [screenWindow])).collect().first
        #expect(result?.state == .ok)
        #expect(result?.windows.count == 1)
        #expect(result?.windows[0].usedPercent == 10)
        #expect(result?.windows[0].resetsAt == UsageJSON.resetDateISO("2026-11-15T03:13:50Z"))
    }

    @Test("screen cache interval is below the verified age limit")
    func screenCacheIntervalBelowVerifiedAge() {
        #expect(AntigravityUsageScreenCache.minimumInterval < UsagePresentations.verifiedAgeLimit)
    }

    @Test("successful screen reads are reused for nine minutes with fresh API enrichment")
    func screenReadThrottle() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        let secondQuota = Self.summary.replacingOccurrences(
            of: "2026-11-15T03:13:50Z", with: "2026-11-16T03:13:50Z")
        let thirdQuota = Self.summary.replacingOccurrences(
            of: "2026-11-15T03:13:50Z", with: "2026-11-17T03:13:50Z")
        http.queue = [project(), quota(), project(), quota(secondQuota),
                      project(), quota(thirdQuota)]
        let firstWindow = UsageWindow(scope: "Claude And Gpt Models", durationMinutes: 10_080,
                                      usedPercent: 10, resetsAt: nil)
        let secondWindow = UsageWindow(scope: "Claude And Gpt Models", durationMinutes: 10_080,
                                       usedPercent: 20, resetsAt: nil)
        let screen = CountingScreen([.success([firstWindow]), .success([secondWindow])])
        let clock = MutableUsageClock(now)
        let collector = collector(http, credentials, runner: missingKeychain(), screen: screen,
                                  screenCache: AntigravityUsageScreenCache(), clock: clock)

        let first = collector.collect().first
        clock.advance(8 * 60)
        let cached = collector.collect().first
        #expect(screen.readCount == 1)
        #expect(cached?.windows.first?.usedPercent == 10)
        #expect(cached?.readAt == first?.readAt)
        #expect(cached?.windows.first?.resetsAt == UsageJSON.resetDateISO("2026-11-16T03:13:50Z"))

        clock.advance(1 * 60)
        let refreshed = collector.collect().first
        #expect(screen.readCount == 2)
        #expect(refreshed?.windows.first?.usedPercent == 20)
        #expect(refreshed?.readAt == now.addingTimeInterval(9 * 60))
        #expect(refreshed?.windows.first?.resetsAt == UsageJSON.resetDateISO("2026-11-17T03:13:50Z"))
        #expect(http.requests.count == 6)
    }

    @Test("a failed screen read is not retried within nine minutes")
    func failedScreenReadThrottle() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota(), project(), quota(), project(), quota()]
        let window = UsageWindow(scope: "Gemini Models", durationMinutes: 10_080,
                                 usedPercent: 5, resetsAt: nil)
        let screen = CountingScreen([
            .failure(.failed(.timeout)),
            .success([window]),
        ])
        let clock = MutableUsageClock(now)
        let collector = collector(http, credentials, runner: missingKeychain(), screen: screen,
                                  screenCache: AntigravityUsageScreenCache(), clock: clock)

        #expect(collector.collect().first?.state == .ok)
        clock.advance(8 * 60 + 59)
        let fallback = collector.collect().first
        #expect(fallback?.state == .ok)
        #expect(screen.readCount == 1)
        clock.advance(2)
        let retried = collector.collect().first
        #expect(retried?.state == .ok)
        #expect(screen.readCount == 2)
        #expect(retried?.windows.first?.usedPercent == 5)
    }

    @Test("missing screen marker falls back to the quota API")
    func screenFallback() {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota()]
        let screen = AntigravityUsageScreen(runner: FixedPTY(data: Data("startup only".utf8)))
        let result = collector(http, credentials, runner: missingKeychain(), screen: screen).collect().first
        #expect(result?.state == .ok && result?.windows.count == 2)
    }

    @Test("trust dialog receives no input and falls back to the quota API")
    func trustPromptFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-trust-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        let readyFile = directory.appendingPathComponent("ready")
        let goFile = directory.appendingPathComponent("go")
        let executable = directory.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        stty -echo -icanon -isig
        : > '\(inputFile.path)'
        (
          sleep 0.1
          : > '\(readyFile.path)'
          while [ ! -f '\(goFile.path)' ]; do :; done
          printf 'Do you trust the contents of this project?\\n> Yes, I trust this folder\\n> No, exit\\n'
        ) &
        writer=$!
        dd bs=1 of='\(inputFile.path)' 2>/dev/null
        wait "$writer"
        """
        try Data(script.utf8).write(to: executable)
        #expect(chmod(executable.path, mode_t(0o700)) == 0)

        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota()]
        let ptyTiming = AntigravityPTYTiming(
            promptQuiet: 0.05, promptTimeout: 15, commandPause: 0.05,
            screenQuiet: 0.05, screenTimeout: 1.5, totalTimeout: 24,
            interruptInterval: 0.01, terminateGrace: 0.1, killGrace: 0.1)
        let screen = AntigravityUsageScreen(runner: SystemAntigravityPTYRunner(timing: ptyTiming))
        let collector = collector(http, credentials, runner: missingKeychain(), screen: screen,
                                  agy: executable)
        let task = Task.detached { collector.collect().first }
        let deadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: readyFile.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path))
        try Data().write(to: goFile)

        let row = try #require(await task.value)
        #expect(row.state == .ok)
        #expect(row.windows.count == 2)
        #expect(http.requests.count == 2)
        #expect(try Data(contentsOf: inputFile).isEmpty)
    }

    @Test("snapshot never contains the fixture email or any token")
    func snapshotPrivacy() throws {
        let http = SpyTransport(); let credentials = SpyCredentials()
        legacyToken(credentials)
        http.queue = [project(), quota()]
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Antigravity/agy-usage-raw.bin"))
        let screen = AntigravityUsageScreen(runner: FixedPTY(data: bytes))
        let row = try #require(collector(http, credentials, runner: missingKeychain(),
                                         screen: screen).collect().first)
        let data = try JSONEncoder().encode(UsageSnapshot(usages: [row], generatedAt: now, showEmails: true))
        let json = String(decoding: data, as: UTF8.self)
        for value in ["user@example.com", "access-only", "unused-refresh", "response-refresh"] {
            #expect(!json.contains(value))
        }
    }

    private func missingKeychain() -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .exited(44)) }
        return runner
    }

    private func refusedKeychain() -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .cancelled) }
        return runner
    }

    private func timeoutKeychain() -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: [], outcome: .timedOut) }
        return runner
    }

    private func keychainRunner(refreshToken: String = "old-refresh") -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        let keychainJSON = Self.keychainJSON.replacingOccurrences(of: "old-refresh", with: refreshToken)
        runner.respond = { _ in UsageProcessResult(lines: [keychainJSON], outcome: .exited(0)) }
        return runner
    }

    private func refreshFingerprint(_ refreshToken: String) -> Data {
        Data(SHA256.hash(data: Data(refreshToken.utf8)))
    }

    private func tokenResponse(_ accessToken: String) -> UsageHTTPResponse {
        UsageHTTPResponse(status: 200, body: Data(
            #"{"access_token":"\#(accessToken)","expires_in":3600,"refresh_token":"response-refresh"}"#.utf8))
    }

    private static let keychainJSON =
        #"{"client_id":"client-id","client_secret":"client-secret","refresh_token":"old-refresh","token_uri":"https://oauth2.googleapis.com/token","scopes":["https://www.googleapis.com/auth/cloudcode"],"project_id":"project-fallback"}"#
}

@Suite("Antigravity PTY cleanup", .serialized)
struct AntigravityPTYTests {
    private func script(contents: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-pty-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("agy")
        try Data(contents.utf8).write(to: executable)
        #expect(chmod(executable.path, mode_t(0o700)) == 0)
        return (directory, executable)
    }

    private func timing(promptQuiet: TimeInterval = 0.05,
                        promptTimeout: TimeInterval = 0.3) -> AntigravityPTYTiming {
        AntigravityPTYTiming(promptQuiet: promptQuiet, promptTimeout: promptTimeout,
                             commandPause: 0.01, screenQuiet: 0.05, screenTimeout: 0.2,
                             totalTimeout: 1, interruptInterval: 0.01,
                             terminateGrace: 0.1, killGrace: 0.1)
    }

    @Test("flooding fake agy without a prompt is reaped without a zombie")
    func timeoutAndReap() throws {
        let (directory, executable) = try script(contents:
            "#!/bin/sh\ntrap '' INT TERM\nwhile :; do printf x; done\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = SystemAntigravityPTYRunner(timing: timing()).run(
            executable: executable, workingDirectory: directory, environment: [:])
        #expect(result.outcome == .promptNotReady)
        let pid = try #require(result.childPID)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test func enterIsWithheldWhenTheEchoIsNoLongerOnScreen() throws {
        // The echo is replaced by a modal before Enter is written (audit B-09): the sink
        // receives the typed command but never 0x0d.
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig\nprintf '? for shortcuts\n'\n"
            + "(sleep 0.05; printf '> /usage\n'; sleep 0.4; printf '\\rmenu overlay — pick a number: '\n) &\n"
            + "dd bs=1 of=\"$INPUT_FILE\" 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        var t = timing(promptQuiet: 0.05, promptTimeout: 0.5)
        t.commandPause = 0.8; t.totalTimeout = 4; t.screenTimeout = 0.3
        let result = SystemAntigravityPTYRunner(timing: t).run(
            executable: executable, workingDirectory: directory, environment: environment)
        let received = try Data(contentsOf: inputFile)
        #expect(!received.contains(0x0d))
        #expect(result.outcome != .completed)
    }

    @Test func enterNeedsTheExactCommandRow() throws {
        // `> /usage-report` is not `/usage` — Enter must not go in (audit B-09).
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig\nprintf '? for shortcuts\n> /usage-report\n'\n"
            + "dd bs=1 of=\"$INPUT_FILE\" 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        var t = timing(promptQuiet: 0.05, promptTimeout: 0.5)
        t.commandPause = 0.3; t.totalTimeout = 3
        let result = SystemAntigravityPTYRunner(timing: t).run(
            executable: executable, workingDirectory: directory, environment: environment)
        #expect(result.outcome == .promptNotReady)
        let received = try Data(contentsOf: inputFile)
        #expect(!received.contains(0x0d))
    }

    @Test func teardownSendsNoKeysIntoAnUnknownScreen() throws {
        // No main prompt marker: teardown uses signals only — no ESC or Ctrl-C in the sink.
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig\ntrap '' INT TERM\n"
            + "printf 'something entirely else\n'\n"
            + "dd bs=1 of=\"$INPUT_FILE\" 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        let result = SystemAntigravityPTYRunner(timing: timing()).run(
            executable: executable, workingDirectory: directory, environment: environment)
        let received = try Data(contentsOf: inputFile)
        #expect(!received.contains(0x1b))
        #expect(!received.contains(0x03))
        _ = result
    }

    @Test("the real capture completes through the live PTY flow (audit B-09)")
    func liveCaptureFlow() throws {
        // The redacted agy capture replayed as a real child: prompt, `/usage` echo and quota
        // screen all come from the bytes; Enter is written and the screen path wins.
        let capture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Antigravity/agy-usage-raw.bin")
        // Staged replay: the prompt and /usage echo are emitted plainly (the capture's own
        // echo frames are transient), then the capture's quota region (bytes 3909-6809,
        // before the teardown repaint) plays the real screen.
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig -icrnl\n"
            + "printf '? for shortcuts\n'\n"
            + "dd bs=1 count=6 of=\"$INPUT_FILE\" 2>/dev/null\n"
            + "printf '> /usage\n'\n"
            + "dd bs=1 count=1 of=\"$INPUT_FILE\" conv=notrunc 2>/dev/null\n"
            + "tail -c +3909 \"$CAPTURE_FILE\" | head -c 2900\n"
            + "dd bs=1 of=/dev/null 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        environment["CAPTURE_FILE"] = capture.path
        var t = timing(promptQuiet: 0.1, promptTimeout: 2)
        t.commandPause = 0.5; t.screenTimeout = 1; t.totalTimeout = 8
        let result = SystemAntigravityPTYRunner(timing: t).run(
            executable: executable, workingDirectory: directory, environment: environment)
        #expect(result.outcome == .completed)
        let windows = try #require(AntigravityUsageScreen.parse(result.output, now: Date()))
        #expect(windows.count == 5)
        let received = try Data(contentsOf: inputFile)
        #expect(received.contains(0x0d)) // Enter actually reached the child
    }

    @Test("missing input marker never types the usage command")
    func missingPromptMarker() throws {
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig\nprintf 'loading\\n'\n"
            + "dd bs=1 of=\"$INPUT_FILE\" 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        // Create the sink up front: the runner may kill the child before its
        // first `: > "$INPUT_FILE"` executes; the read must not race child startup.
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        var shortTiming = timing(promptQuiet: 0.05, promptTimeout: 0.9)
        shortTiming.totalTimeout = 9
        let result = SystemAntigravityPTYRunner(timing: shortTiming).run(
            executable: executable, workingDirectory: directory, environment: environment)
        #expect(result.outcome == .promptNotReady)
        let received = try Data(contentsOf: inputFile)
        #expect(received.isEmpty)
    }

    @Test("Enter is withheld when the typed usage command is not rendered")
    func usageEchoRequired() throws {
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nstty -echo -icanon -isig\nprintf '? for shortcuts\\n> '\n"
            + "dd bs=1 of=\"$INPUT_FILE\" 2>/dev/null\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputFile = directory.appendingPathComponent("input")
        try Data().write(to: inputFile)
        var environment = ProcessInfo.processInfo.environment
        environment["INPUT_FILE"] = inputFile.path
        let ptyTiming = AntigravityPTYTiming(
            promptQuiet: 0.05, promptTimeout: 3, commandPause: 0.5,
            screenQuiet: 0.05, screenTimeout: 1.5, totalTimeout: 15,
            interruptInterval: 0.01, terminateGrace: 0.1, killGrace: 0.1)
        let result = SystemAntigravityPTYRunner(timing: ptyTiming).run(
            executable: executable, workingDirectory: directory, environment: environment)
        #expect(result.outcome == .promptNotReady)
        let received = try Data(contentsOf: inputFile)
        #expect(String(decoding: received, as: UTF8.self).contains("/usage"))
        #expect(!received.contains(0x0d))
    }

    @Test("safe main prompt accepts usage only after its input is visible")
    func safePrompt() throws {
        let (directory, executable) = try script(contents:
            "#!/bin/sh\nprintf '? for shortcuts\\n> '\n"
            + "IFS= read -r command\n"
            + "if [ \"$command\" = \"/usage\" ]; then "
            + "printf '\\r\\nModels & Quota\\nGEMINI MODELS\\nWeekly Limit Remaining\\n[████] 100.00%%\\n'; fi\n"
            + "while :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ptyTiming = AntigravityPTYTiming(
            promptQuiet: 0.05, promptTimeout: 3, commandPause: 0.5,
            screenQuiet: 0.05, screenTimeout: 3, totalTimeout: 24,
            interruptInterval: 0.01, terminateGrace: 0.1, killGrace: 0.1)
        let screen = AntigravityUsageScreen(runner: SystemAntigravityPTYRunner(timing: ptyTiming))
        let result = screen.read(executable: executable, now: Date())
        #expect(result.state == .ok)
        try #require(result.windows.count == 1)
        #expect(result.windows[0].usedPercent == 0)
    }

    @Test("cancellation terminates and reaps fake agy promptly")
    func cancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-pty-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let contents = "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"\(pidFile.path)\"\nprintf 'ready\\n'\nwhile :; do :; done\n"
        let executable = directory.appendingPathComponent("agy")
        try Data(contents.utf8).write(to: executable)
        #expect(chmod(executable.path, mode_t(0o700)) == 0)
        var cancellationTiming = timing(promptQuiet: 2, promptTimeout: 30)
        cancellationTiming.totalTimeout = 40
        let runner = SystemAntigravityPTYRunner(timing: cancellationTiming)
        let task = Task.detached {
            runner.run(executable: executable, workingDirectory: directory, environment: [:])
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: pidFile.path))
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        let pid = try #require(result.childPID)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }
}
