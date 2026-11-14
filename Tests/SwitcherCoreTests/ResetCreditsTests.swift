import Foundation
import Testing
@testable import SwitcherCore

@Suite("Codex reset credits")
struct ResetCreditsTests {
    static let readAt = Date(timeIntervalSince1970: 1_794_600_000)
    static let firstExpiry = 1_796_163_888
    static let secondExpiry = 1_797_114_045

    /// The 0.167.0 answer shape, with details: two available "Full reset" credits and one redeemed.
    static let detailed = #"""
    {"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":{"planType":"promax","primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1794727914}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"RateLimitResetCredit_b","resetType":"codexRateLimits","status":"available","grantedAt":1794522045,"expiresAt":1797114045,"title":"Full reset","description":"secret-ish text"},{"id":"RateLimitResetCredit_a","resetType":"codexRateLimits","status":"available","grantedAt":1793571888,"expiresAt":1796163888,"title":"Full reset","description":null},{"id":"RateLimitResetCredit_c","resetType":"codexRateLimits","status":"redeemed","grantedAt":1790000000,"expiresAt":1795000000,"title":null,"description":null}]}}}
    """#

    static func countOnly(_ count: Int) -> String {
        #"{"id":2,"result":{"rateLimits":{"planType":"promax","primary":{"usedPercent":99,"windowDurationMins":10080,"resetsAt":1794727914}},"rateLimitResetCredits":{"availableCount":\#(count),"credits":null}}}"#
    }

    func account() -> CodexAccount {
        CodexAccount(id: "a1", kind: .standard, label: "Codex a1", customName: nil,
                     defaultName: "a1@example.com", home: "/tmp/codex-home", homePath: "~/.codex",
                     identity: CodexIdentity(mode: .chatgpt, email: "a1@example.com", accountId: "acct-a"),
                     state: .signedIn, pids: [])
    }

    func collector(_ runner: FakeUsageRunner, cache: CodexResetCreditCache,
                   now: @escaping @Sendable () -> Date = { ResetCreditsTests.readAt }) -> CodexUsageCollector {
        let status = CodexStatus(installed: true, version: "0.167.0", accounts: [account()], found: [], hiddenCount: 0)
        return CodexUsageCollector(status: { status }, runner: runner, codexCLI: URL(fileURLWithPath: "/fake/codex"),
                                   workingDirectory: FileManager.default.temporaryDirectory,
                                   resetCredits: cache, now: now)
    }

    /// Answers each request in turn with the next line; the last line repeats.
    func runner(_ answers: [String]) -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        let counter = Counter()
        runner.respond = { _ in
            let index = min(counter.next(), answers.count - 1)
            return UsageProcessResult(lines: [answers[index]], outcome: .stopped)
        }
        return runner
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    // MARK: - Parser

    @Test("a detailed answer gives the count and the available credits' expiries, earliest first")
    func detailedAnswer() throws {
        let parsed = try CodexRateLimitsParser.read([Self.detailed]).get()
        #expect(parsed.windows.map(\.usedPercent) == [99])
        #expect(parsed.resetCreditDetails)
        #expect(parsed.resetCredits == UsageResetCredits(available: 2, expiries: [
            Date(timeIntervalSince1970: TimeInterval(Self.firstExpiry)),
            Date(timeIntervalSince1970: TimeInterval(Self.secondExpiry)),
        ]))
    }

    @Test("a count-only answer (credits: null) gives the count without expiries")
    func countOnlyAnswer() throws {
        let parsed = try CodexRateLimitsParser.read([Self.countOnly(2)]).get()
        #expect(!parsed.resetCreditDetails)
        #expect(parsed.resetCredits == UsageResetCredits(available: 2))
    }

    @Test("no reset credits, or an unknown shape, leaves credits out without failing the windows",
          arguments: [
            "",
            #","rateLimitResetCredits":null"#,
            #","rateLimitResetCredits":{"availableCount":"2"}"#,
            #","rateLimitResetCredits":{"availableCount":-1,"credits":null}"#,
            #","rateLimitResetCredits":[1,2]"#,
          ])
    func absentOrMalformed(field: String) throws {
        let line = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1780003600}}\#(field)}}"#
        let parsed = try CodexRateLimitsParser.read([line]).get()
        #expect(parsed.windows.count == 1)
        #expect(parsed.resetCredits == nil)
    }

    @Test("credit entries with a bad expiry are skipped, the count still stands")
    func badExpiries() throws {
        let line = #"{"id":2,"result":{"rateLimits":{"primary":null},"rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":null},{"status":"available","expiresAt":"soon"},{"status":"available","expiresAt":9999999999}]}}}"#
        let parsed = try CodexRateLimitsParser.read([line]).get()
        #expect(parsed.resetCredits == UsageResetCredits(available: 2))
        #expect(parsed.resetCreditDetails)
    }

    @Test("the request asks for details only when told to")
    func stdinDetails() {
        #expect(CodexUsageCollector.stdinLines(version: "1")[2].contains(#""excludeResetCreditDetails":true"#))
        #expect(CodexUsageCollector.stdinLines(version: "1", resetCreditDetails: true)[2]
            .contains(#""excludeResetCreditDetails":false"#))
    }

    // MARK: - Cache

    @Test("details are asked for first, then not again until they age out")
    func cacheLifetime() {
        let cache = CodexResetCreditCache()
        let now = Self.readAt
        #expect(cache.wantsDetails(account: "a1", now: now))
        _ = cache.merge(account: "a1", read: UsageResetCredits(available: 1), detailed: true, now: now)
        #expect(!cache.wantsDetails(account: "a1", now: now.addingTimeInterval(300)))
        #expect(cache.wantsDetails(account: "a1", now: now.addingTimeInterval(CodexResetCreditCache.detailLifetime)))
        #expect(cache.wantsDetails(account: "a1", now: now.addingTimeInterval(-60)))  // clock went back
        #expect(cache.wantsDetails(account: "other", now: now))
    }

    @Test("a count-only read keeps the expiries while the count matches and drops them when it changes")
    func cacheMerge() {
        let cache = CodexResetCreditCache()
        let expiry = Self.readAt.addingTimeInterval(86_400)
        let detailed = UsageResetCredits(available: 2, expiries: [expiry])
        _ = cache.merge(account: "a1", read: detailed, detailed: true, now: Self.readAt)
        #expect(cache.merge(account: "a1", read: UsageResetCredits(available: 2), detailed: false, now: Self.readAt) == detailed)
        let used = cache.merge(account: "a1", read: UsageResetCredits(available: 1), detailed: false, now: Self.readAt)
        #expect(used == UsageResetCredits(available: 1))
        #expect(cache.wantsDetails(account: "a1", now: Self.readAt))
    }

    // MARK: - Collector

    @Test("the first poll asks for details; the next skips them and still shows the expiry")
    func collectorPolls() throws {
        let cache = CodexResetCreditCache()
        let runner = runner([Self.detailed, Self.countOnly(2)])
        let first = try #require(collector(runner, cache: cache).collect().first)
        let second = try #require(collector(runner, cache: cache).collect().first)
        let lines = runner.requests.compactMap { $0.stdinLines?.last }
        #expect(lines.count == 2)
        #expect(lines[0].contains(#""excludeResetCreditDetails":false"#))
        #expect(lines[1].contains(#""excludeResetCreditDetails":true"#))
        #expect(first.resetCredits?.available == 2)
        #expect(second.resetCredits == first.resetCredits)
        #expect(second.resetCredits?.nextExpiry(now: Self.readAt)
            == Date(timeIntervalSince1970: TimeInterval(Self.firstExpiry)))
    }

    @Test("a detailed request answered with the count alone still counts as detailed")
    func detailedRequestCountOnlyAnswer() throws {
        let cache = CodexResetCreditCache()
        let runner = runner([Self.countOnly(1)])
        _ = collector(runner, cache: cache).collect()
        _ = collector(runner, cache: cache).collect()
        let lines = runner.requests.compactMap { $0.stdinLines?.last }
        #expect(lines.map { $0.contains(#""excludeResetCreditDetails":true"#) } == [false, true])
    }

    @Test("a read attributed to another login carries no credits and forgets the kept ones")
    func mismatchForgets() throws {
        let cache = CodexResetCreditCache()
        _ = cache.merge(account: "a1", read: UsageResetCredits(available: 3), detailed: true, now: Self.readAt)
        let other = #"{"id":2,"result":{"accountId":"acct-b","rateLimits":{"primary":null},"rateLimitResetCredits":{"availableCount":5,"credits":null}}}"#
        let usage = try #require(collector(runner([other]), cache: cache).collect().first)
        #expect(usage.state == .failed(.accountMismatch))
        #expect(usage.resetCredits == nil)
        #expect(cache.wantsDetails(account: "a1", now: Self.readAt))
    }

    @Test("a failed re-read of the same login keeps the last known credits with its windows")
    func retainedOnFailure() throws {
        let cache = CodexResetCreditCache()
        let ok = try #require(collector(runner([Self.detailed]), cache: cache).collect().first)
        let failed = try #require(collector(runner([#"{"id":2,"error":{"code":-32001,"message":"busy"}}"#]),
                                            cache: cache).collect().first)
        #expect(failed.resetCredits == nil)
        let shown = failed.retainingWindows(from: ok, now: Self.readAt)
        #expect(shown.windows == ok.windows)
        #expect(shown.resetCredits == ok.resetCredits)
    }

    // MARK: - Text and snapshot

    @Test("the row text gives the count, and the first expiry when known")
    func rowText() {
        let now = Self.readAt
        #expect(UsageText.resetCredits(nil, now: now) == nil)
        #expect(UsageText.resetCredits(UsageResetCredits(available: 0), now: now) == nil)
        #expect(UsageText.resetCredits(UsageResetCredits(available: 2), now: now) == L10n.t(.usageResetCredits, 2))
        let expiry = now.addingTimeInterval(3 * 86_400 + 2 * 3600)
        let past = now.addingTimeInterval(-60)
        #expect(UsageText.resetCredits(UsageResetCredits(available: 2, expiries: [past, expiry]), now: now)
            == L10n.t(.usageResetCreditsExpiry, 2, UsageText.countdown(to: expiry, from: now)))
    }

    @Test("the snapshot carries the count and next expiry, and older files without them still load")
    func snapshot() throws {
        let expiry = Self.readAt.addingTimeInterval(86_400)
        let usage = AccountUsage(id: "codex:a1", provider: .codex, accountRef: "a1", label: "Work", plan: "pro",
                                 windows: [], state: .ok, readAt: Self.readAt, toolVersion: nil,
                                 resetCredits: UsageResetCredits(available: 2, expiries: [expiry]))
        let snapshot = UsageSnapshot(usages: [usage], generatedAt: Self.readAt, showEmails: false)
        #expect(snapshot.accounts.first?.resetCredits
            == UsageSnapshot.ResetCredits(available: 2, nextExpiry: expiry))
        #expect(snapshot.masked().accounts.first?.resetCredits == snapshot.accounts.first?.resetCredits)

        let old = #"{"generatedAt":"2026-11-14T00:00:00Z","accounts":[{"id":"codex#1","provider":"codex","label":"Work","state":"ok","readAt":"2026-11-14T00:00:00Z","windows":[]}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(UsageSnapshot.self, from: Data(old.utf8))
        #expect(loaded.accounts.first?.resetCredits == nil)
    }
}
