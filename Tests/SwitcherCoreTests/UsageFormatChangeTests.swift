import Foundation
import Testing
@testable import SwitcherCore

/// A vendor answer that reports usage in a shape this build can't read is a failed read
/// (`schemaChanged`), never "not reporting usage" — that state is for an account with nothing to
/// report (audit B2-U-01).
@Suite("A changed vendor format is not 'not reporting'")
struct UsageFormatChangeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func ok(_ json: String) -> UsageHTTPResponse {
        UsageHTTPResponse(status: 200, body: Data(json.utf8))
    }

    // MARK: - Grok

    private func grok(_ json: String) -> UsageState? {
        let http = SpyTransport(); let credentials = SpyCredentials()
        credentials.files["/tmp/grok-format/.grok/auth.json"] = Data(
            #"{"https://auth.x.ai":{"key":"k1","user_id":"u1","expires_at":"2999-01-01T00:00:00Z"}}"#.utf8)
        http.queue = [ok(json)]
        return GrokUsageCollector(enabled: true, http: http, credentials: credentials,
                                  home: URL(fileURLWithPath: "/tmp/grok-format"), now: { now }).collect().first?.state
    }

    @Test("Grok: a percentage under a period type this build doesn't know is a changed format")
    func grokUnknownPeriodType() {
        #expect(grok(#"{"config":{"creditUsagePercent":40,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_DAILY","end":"2023-11-20T00:00:00Z"}}}"#)
            == .unavailable(.schemaChanged))
        #expect(grok(#"{"config":{"creditUsagePercent":40,"currentPeriod":{"kind":"weekly"}}}"#)
            == .unavailable(.schemaChanged))
    }

    @Test("Grok: a percentage with no period at all is a changed format")
    func grokPercentWithoutPeriod() {
        #expect(grok(#"{"config":{"creditUsagePercent":40}}"#) == .unavailable(.schemaChanged))
        #expect(grok(#"{"config":{"creditUsagePercent":40,"currentPeriod":"weekly"}}"#) == .unavailable(.schemaChanged))
    }

    @Test("Grok: an answer without a percentage still reports nothing")
    func grokMoneyOnly() {
        #expect(grok(#"{"config":{"monthlyLimit":25,"used":4}}"#) == .notReporting)
        #expect(grok(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_DAILY"}}}"#) == .notReporting)
    }

    // MARK: - Devin

    private func devin(planStatus: String) -> UsageState? {
        let http = SpyTransport(); let credentials = SpyCredentials()
        credentials.files["/tmp/devin-format/.local/share/devin/credentials.toml"] = Data(#"api_key = "d1""#.utf8)
        http.queue = [ok(#"{"userStatus":{"planStatus":\#(planStatus)}}"#)]
        return DevinUsageCollector(enabled: true, http: http, credentials: credentials,
                                   runner: DevinAdapterTests.FakeRunner(), cli: URL(fileURLWithPath: "/usr/bin/devin"),
                                   clientVersion: "1.0", home: URL(fileURLWithPath: "/tmp/devin-format"),
                                   now: { now }).collect().first?.state
    }

    @Test("Devin: a quota plan whose quota keys are gone is a changed format")
    func devinQuotaPlanWithoutWindows() {
        let quota = #""planInfo":{"planName":"Solo","billingStrategy":"BILLING_STRATEGY_QUOTA"}"#
        #expect(devin(planStatus: "{\(quota)}") == .unavailable(.schemaChanged))
        #expect(devin(planStatus: #"{"dailyRemainingPercent":25,"dailyResetAt":1700500000,\#(quota)}"#)
            == .unavailable(.schemaChanged))
        // One window hidden and the other one gone is still a window the plan should have shown.
        #expect(devin(planStatus: #"{"hideDailyQuota":true,\#(quota)}"#) == .unavailable(.schemaChanged))
    }

    @Test("Devin: a plan that hides both quotas, or has none, still reports nothing")
    func devinNothingToReport() {
        let quota = #""planInfo":{"billingStrategy":"BILLING_STRATEGY_QUOTA"}"#
        #expect(devin(planStatus: #"{"hideDailyQuota":true,"hideWeeklyQuota":true,\#(quota)}"#) == .notReporting)
        #expect(devin(planStatus: #"{"planInfo":{"planName":"Team","billingStrategy":"BILLING_STRATEGY_CREDITS"}}"#)
            == .notReporting)
        #expect(devin(planStatus: "{}") == .notReporting)
    }

    // MARK: - OpenCode

    private func openCode(_ json: String) -> UsageState? {
        let http = SpyTransport(); let credentials = SpyCredentials()
        credentials.files["/tmp/oc-format/.local/share/opencode/auth.json"] = Data(
            #"{"opencode-go":{"type":"api","key":"g1"}}"#.utf8)
        http.queue = [ok(json)]
        return OpenCodeUsageCollector(enabled: true, http: http, credentials: credentials,
                                      home: URL(fileURLWithPath: "/tmp/oc-format"), now: { now }).collect().first?.state
    }

    @Test("OpenCode: usage under window names this build doesn't know is a changed format")
    func openCodeUnknownWindows() {
        #expect(openCode(#"{"usage":{"fiveHour":{"percent":30,"resetsAt":"2023-11-15T00:00:00Z"}}}"#)
            == .unavailable(.schemaChanged))
        #expect(openCode(#"{"usage":{"daily":{"percent":30}}}"#) == .unavailable(.schemaChanged))
    }

    @Test("OpenCode: an empty usage object still reports nothing")
    func openCodeEmptyUsage() {
        #expect(openCode(#"{"usage":{}}"#) == .notReporting)
    }

    // MARK: - Copilot

    private func copilot(_ json: String) -> UsageState? {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: ["t"], outcome: .exited(0)) }
        let http = SpyTransport()
        http.queue = [ok(json)]
        return CopilotUsageCollector(enabled: true, http: http, runner: runner,
                                     cli: URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
                                     home: URL(fileURLWithPath: "/tmp/copilot-format"),
                                     now: { now }).collect().first?.state
    }

    @Test("Copilot: quota snapshots under names this build doesn't know are a changed format")
    func copilotUnknownSnapshots() {
        #expect(copilot(#"{"login":"o","quota_snapshots":{"agent":{"has_quota":true,"unlimited":false,"percent_remaining":10.0}}}"#)
            == .unavailable(.schemaChanged))
    }

    @Test("Copilot: known pools without a quota still report nothing")
    func copilotUnlimitedPools() {
        #expect(copilot(#"{"login":"o","quota_snapshots":{"chat":{"unlimited":true,"has_quota":false,"percent_remaining":100.0}}}"#)
            == .notReporting)
    }

    // MARK: - What the user reads

    @Test("the reason shown for a changed format says the read failed, in every language",
          arguments: [UsageProvider.grok, .devin, .opencode, .copilot, .claude])
    func reasonIsAFailedRead(_ provider: UsageProvider) {
        for language in AppLanguage.allCases {
            let failed = L10n.string(.usageReasonSchemaChanged, language: language, [UsageText.providerName(provider)])
            #expect(failed != L10n.string(.usageReasonNotReporting, language: language))
            #expect(failed.contains(UsageText.providerName(provider)))
        }
        #expect(L10n.string(.usageReasonSchemaChanged, language: .ko, ["Grok"])
            == "사용량을 읽지 못했습니다 — 이 Grok 버전은 UsageSwitch 업데이트가 필요할 수 있습니다")
    }
}
