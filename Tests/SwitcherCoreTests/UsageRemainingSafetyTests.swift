import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage remaining safety")
struct UsageRemainingSafetyTests {
    @Test("unterminated stdout stops at the byte budget, not the deadline")
    func unterminatedOutput() {
        let request = UsageProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do printf 12345678; done"],
            environment: [:], workingDirectory: FileManager.default.temporaryDirectory,
            maxOutputBytes: 64, timeout: 3)
        let start = Date()
        let result = SystemUsageProcessRunner().run(request)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(result.outcome == .outputLimit)
    }

    @Test("Grok skips tokens expiring before the next refresh")
    func nearExpiryGrok() {
        let credentials = SpyCredentials()
        credentials.files["/tmp/expiry/.grok/auth.json"] = Data(
            #"{"https://auth.x.ai":{"key":"fake","expires_at":"2023-11-14T22:15:00Z"}}"#.utf8)
        let http = SpyTransport()
        let rows = GrokUsageCollector(
            enabled: true, http: http, credentials: credentials,
            home: URL(fileURLWithPath: "/tmp/expiry"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }).collect()
        #expect(http.requests.isEmpty)
        #expect(rows.first?.state == .unavailable(.signInExpired))
    }

    @Test("a tokenless authoritative Devin file cannot select a different account")
    func tokenlessDevin() {
        let credentials = SpyCredentials()
        credentials.files["/tmp/authority/.local/share/devin/credentials.toml"] = Data("# no sign-in\n".utf8)
        credentials.files["/tmp/authority/.config/devin/credentials.toml"] = Data(#"api_key = "other-account""#.utf8)
        let runner = VersionSpy()
        let http = SpyTransport()
        let rows = DevinUsageCollector(
            enabled: true, http: http, credentials: credentials, runner: runner,
            cli: URL(fileURLWithPath: "/fake/devin"), clientVersion: "1.0",
            home: URL(fileURLWithPath: "/tmp/authority")).collect()
        #expect(runner.calls == 0)
        #expect(http.requests.isEmpty)
        #expect(rows.first?.state == .unavailable(.noSignIn))
    }
}

private final class VersionSpy: UsageProcessRunner, @unchecked Sendable {
    private(set) var calls = 0

    func run(_ request: UsageProcessRequest) -> UsageProcessResult {
        calls += 1
        return UsageProcessResult(lines: ["devin 2.3.4"], outcome: .exited(0))
    }
}
