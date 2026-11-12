import Foundation
import Testing
@testable import SwitcherCore

@Suite("Copilot usage")
struct CopilotUsageTests {
    private let gh = URL(fileURLWithPath: "/opt/homebrew/bin/gh")

    private func collector(enabled: Bool = true, cli: URL? = nil, cliExplicit: Bool = false,
                           runner: FakeUsageRunner, http: SpyTransport) -> CopilotUsageCollector {
        CopilotUsageCollector(enabled: enabled, http: http, runner: runner,
                              cli: cliExplicit ? cli : (cli ?? gh),
                              home: URL(fileURLWithPath: "/tmp/copilot-home"),
                              now: { Date(timeIntervalSince1970: 1_780_000_000) })
    }

    private func tokenRunner(token: String?) -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in
            guard let token else {
                return UsageProcessResult(lines: [], outcome: .exited(1))
            }
            return UsageProcessResult(lines: [token], outcome: .exited(0))
        }
        return runner
    }

    private var quotaJSON: String {
        #"{"login":"octocat","copilot_plan":"individual","access_type_sku":"free_limited_copilot","# +
        #""quota_reset_date_utc":"2026-12-01T00:00:00Z","quota_snapshots":{"# +
        #""chat":{"has_quota":true,"unlimited":false,"percent_remaining":80.0,"remaining":160,"entitlement":200},"# +
        #""completions":{"has_quota":true,"unlimited":false,"percent_remaining":95.0,"remaining":1900,"entitlement":2000},"# +
        #""premium_interactions":{"has_quota":true,"unlimited":false,"percent_remaining":50.0,"remaining":25,"entitlement":50}}}"#
    }

    @Test("disabled means no token ask and no request at all")
    func disabled() {
        let runner = tokenRunner(token: "gho_x")
        let http = SpyTransport()
        #expect(collector(enabled: false, runner: runner, http: http).collect() == [])
        #expect(runner.requests.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test("no gh binary means cliMissing with no token ask")
    func missingCLI() {
        let runner = tokenRunner(token: "gho_x")
        let http = SpyTransport()
        let rows = collector(cli: nil, cliExplicit: true, runner: runner, http: http).collect()
        #expect(rows.count == 1)
        #expect(rows[0].state == .unavailable(.cliMissing))
        #expect(runner.requests.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test("token comes from gh auth token on the trusted binary only")
    func tokenAsk() {
        let runner = tokenRunner(token: "gho_abc123")
        let http = SpyTransport()
        http.queue = [UsageHTTPResponse(status: 200, body: Data(quotaJSON.utf8))]
        let rows = collector(runner: runner, http: http).collect()
        #expect(rows.first?.state == .ok)
        let request = runner.requests.first
        #expect(request?.executable == gh)
        #expect(request?.arguments == ["auth", "token"])
        #expect(request?.stdinLines == nil)
    }

    @Test("gh auth token failing yields noSignIn and no network")
    func tokenFailure() {
        let runner = tokenRunner(token: nil)
        let http = SpyTransport()
        let rows = collector(runner: runner, http: http).collect()
        #expect(rows.first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("multi-line token output is a schema break, not a partial token")
    func tokenMultiline() {
        let runner = FakeUsageRunner()
        runner.respond = { _ in
            UsageProcessResult(lines: ["gho_one", "gho_two"], outcome: .exited(0))
        }
        let http = SpyTransport()
        let rows = collector(runner: runner, http: http).collect()
        #expect(rows.first?.state == .unavailable(.noSignIn))
        #expect(http.requests.isEmpty)
    }

    @Test("the request targets the fixed GitHub endpoint with the token")
    func endpoint() {
        let runner = tokenRunner(token: "gho_secret")
        let http = SpyTransport()
        http.queue = [UsageHTTPResponse(status: 200, body: Data(quotaJSON.utf8))]
        _ = collector(runner: runner, http: http).collect()
        let request = http.requests.first
        #expect(request?.url.absoluteString == "https://api.github.com/copilot_internal/user")
        #expect(request?.method == .get)
        #expect(request?.headers["Authorization"] == "token gho_secret")
    }

    @Test("quotas map to monthly windows with used percent and reset")
    func quotas() {
        let runner = tokenRunner(token: "gho_x")
        let http = SpyTransport()
        http.queue = [UsageHTTPResponse(status: 200, body: Data(quotaJSON.utf8))]
        let rows = collector(runner: runner, http: http).collect()
        let row = rows.first
        #expect(row?.state == .ok)
        #expect(row?.plan == "individual")
        #expect(row?.authentication == .subscription)
        #expect(row?.identityKey?.isEmpty == false)
        let byScope = Dictionary(uniqueKeysWithValues: (row?.windows ?? []).map { ($0.scope, $0) })
        #expect(byScope["chat"]?.usedPercent == 20)
        #expect(byScope["completions"]?.usedPercent == 5)
        #expect(byScope["premium_interactions"]?.usedPercent == 50)
        #expect(byScope["chat"]?.durationMinutes == 43200)
        #expect(byScope["chat"]?.resetsAt != nil)
    }

    @Test("unlimited pools and non-quota pools produce no window")
    func unlimitedPool() {
        let json = #"{"login":"o","copilot_plan":"business","# +
            #""quota_snapshots":{"chat":{"has_quota":false,"unlimited":true,"percent_remaining":100.0},"# +
            #""completions":{"has_quota":true,"unlimited":false,"percent_remaining":10.0}}}"#
        let runner = tokenRunner(token: "t")
        let http = SpyTransport()
        http.queue = [UsageHTTPResponse(status: 200, body: Data(json.utf8))]
        let row = collector(runner: runner, http: http).collect().first
        #expect(row?.state == .ok)
        #expect(row?.windows.count == 1)
        #expect(row?.windows.first?.scope == "completions")
        #expect(row?.windows.first?.usedPercent == 90)
    }

    @Test("no usable quota snapshot is notReporting, never a fabricated number")
    func emptySnapshots() {
        let json = #"{"login":"o","copilot_plan":"free","quota_snapshots":{"chat":{"unlimited":true,"has_quota":false,"percent_remaining":100.0}}}"#
        let runner = tokenRunner(token: "t")
        let http = SpyTransport()
        http.queue = [UsageHTTPResponse(status: 200, body: Data(json.utf8))]
        let row = collector(runner: runner, http: http).collect().first
        #expect(row?.state == .notReporting)
        #expect(row?.windows.isEmpty == true)
    }

    @Test("401 is signInRejected, 403 notEligible, 429 rateLimited")
    func statusMapping() {
        for (status, expected) in [(401, UsageState.failed(.signInRejected)),
                                   (403, UsageState.unavailable(.notEligible)),
                                   (429, UsageState.failed(.rateLimited)),
                                   (500, UsageState.failed(.network))] {
            let runner = tokenRunner(token: "t")
            let http = SpyTransport()
            http.queue = [UsageHTTPResponse(status: status, body: Data("{}".utf8))]
            let row = collector(runner: runner, http: http).collect().first
            #expect(row?.state == expected, "status \(status)")
        }
    }

    @Test("malformed quota snapshots are schemaChanged")
    func schemaBreak() {
        for json in [#"{"quota_snapshots":"nope"}"#,
                     #"{"quota_snapshots":{"chat":{"has_quota":true,"percent_remaining":"soon"}}}"#,
                     #"{"login":"o"}"#] {
            let runner = tokenRunner(token: "t")
            let http = SpyTransport()
            http.queue = [UsageHTTPResponse(status: 200, body: Data(json.utf8))]
            let row = collector(runner: runner, http: http).collect().first
            #expect(row?.state == .unavailable(.schemaChanged), "json: \(json)")
        }
    }
}
