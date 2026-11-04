import Foundation
@testable import SwitcherCore

// MARK: - Channel output fixtures
//
// The test target has no resource bundle, so the version-stamped contract fixtures live here as
// string literals. Each note names the fields the parser relies on; when a vendor version changes
// shape, add its fixture and a test (plan §6).

enum UsageFixture {
    /// codex app-server 0.152.1: relies on `rateLimitsByLimitId.codex` (fallback `rateLimits`),
    /// primary/secondary {usedPercent, windowDurationMins, resetsAt}, planType. accountId is already
    /// redacted; credits/reset-credits/upsell are present to prove they are ignored.
    static let codex_0_152_1 = """
        {"id":1,"result":{"userAgent":"usageswitch/0.152.1"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1788626797},"secondary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1788752527},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":"rate_limit_reached"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1788626797},"secondary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1788752527},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"plus","rateLimitReachedType":"rate_limit_reached"}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"RateLimitResetCredit_redacted_1","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":0,"title":"Full reset (Weekly + 5 hr)","description":"redacted"}]},"accountId":"00000000-0000-0000-0000-000000000000","rateLimitUpsell":{"banner_type":"plus_rate_limit_reached","title":"redacted","description":"redacted","ctas":[],"reset_at":1788626797,"referral":null,"request_url":null}}}
        {"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}
        """

    /// codex app-server 0.166.0-alpha.5.1 (live capture, redacted): same fields as 0.152.1; primary is
    /// the weekly window here (windowDurationMins 10080, secondary null) — classified by duration,
    /// never by slot. accountId redacted, rateLimitResetCredits/rateLimitUpsell dropped.
    static let codex_0_166_0 = """
        {"id":1,"result":{"userAgent":"usageswitch/0.166.0-alpha.5.1 (Mac OS 26.5.2; arm64) unknown (usageswitch; 2.0.0)","codexHome":"/Users/test/.codex","platformFamily":"unix","platformOs":"macos"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled","serverName":"test-host","installationId":null,"environmentId":null},"emittedAtMs":1793784625532}
        {"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1794301834},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"normalModelSlug":null,"primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1794301834},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"spendControlReached":false,"planType":"prolite","rateLimitReachedType":null}},"accountId":"00000000-0000-0000-0000-000000000000","rateLimitUpsell":null}}
        {"method":"account/updated","params":{"authMode":"chatgpt","planType":"prolite"},"emittedAtMs":1793784626099}
        """

    /// The legacy shape with no `rateLimitsByLimitId`: relies on the `rateLimits` fallback.
    static let codexLegacyRateLimits = """
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1788626797},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1788752527},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"pro"}}}
        """

    /// claude 2.1.317 `claude -p /usage` stream-json (live capture reduced to the fields relied on):
    /// system/init, assistant with message.model "<synthetic>", result with type/subtype/is_error/
    /// num_turns/total_cost_usd and the panel text in `result`. Session ids, uuids, tool lists and
    /// account fields dropped. The "What's contributing" percentages prove they are not windows.
    static let claude_2_1_317 = ##"""
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"model":"<synthetic>"}}
        {"type":"result","subtype":"success","is_error":false,"num_turns":0,"total_cost_usd":0,"result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent week (all models): 75% used · resets Nov 6 at 12:59pm (Asia/Seoul)\nCurrent week (Fable): 3% used · resets Nov 6 at 12:59pm (Asia/Seoul)\n\nWhat's contributing to your usage?\nApproximate · sessions on this machine only · shares overlap\n\nLast 24h · 3152 requests · 45 sessions\n  89%  Start fresh when you switch tasks · run /clear\n  72%  Save max effort for hard tasks\n\nLast 7d · 37550 requests · 753 sessions\n  87%  Start fresh when you switch tasks · run /clear\n  46%  Give \"general-purpose\" subagents a cheaper model"}
        """##

    /// GetCurrentPeriodUsage with split pools: relies on billingCycleStart/billingCycleEnd as string
    /// int64 ms, planUsage.autoPercentUsed/apiPercentUsed (scopes "Auto"/"API"), totalPercentUsed.
    static let cursorSplit = """
        {"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{"autoPercentUsed":42.5,"apiPercentUsed":7,"totalPercentUsed":30},"membershipType":"pro"}
        """

    /// GetCurrentPeriodUsage on a merged plan + GetPlanInfo `isMerged`: one window from the total.
    static let cursorMergedUsage = """
        {"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{"totalPercentUsed":61}}
        """
    static let cursorMergedPlanInfo = """
        {"isMerged":true,"planName":"pro"}
        """

    /// Total only, no GetPlanInfo answer: still one window.
    static let cursorTotalOnly = """
        {"billingCycleStart":1767225600000,"billingCycleEnd":1769817600000,"planUsage":{"totalPercentUsed":88}}
        """

    /// No percentages reported at all.
    static let cursorNoPercentages = """
        {"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{}}
        """
}

// MARK: - Fakes

/// Records every request and answers with `respond`; tests never touch real binaries.
final class FakeUsageRunner: UsageProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [UsageProcessRequest] = []
    var respond: @Sendable (UsageProcessRequest) -> UsageProcessResult = { _ in
        UsageProcessResult(lines: [], outcome: .exited(0))
    }

    var requests: [UsageProcessRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func run(_ request: UsageProcessRequest) -> UsageProcessResult {
        lock.lock(); _requests.append(request); lock.unlock()
        return respond(request)
    }
}

/// Records calls (without the token — nothing should ever inspect it back) and answers with `respond`.
final class FakeUsageHTTP: UsageHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    var respond: @Sendable (URL) -> (status: Int, body: Data)? = { _ in nil }

    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return _calls }

    func post(url: URL, bearer: String, timeout: TimeInterval) -> (status: Int, body: Data)? {
        lock.lock(); _calls.append(url); lock.unlock()
        return respond(url)
    }
}
