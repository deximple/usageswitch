import Foundation
import Testing
@testable import SwitcherCore

@Suite("Codex usage")
struct CodexUsageTests {
    let cli = URL(fileURLWithPath: "/fake/codex")

    /// The redacted account the recorded fixtures attribute their reads to.
    static let fixtureAccountId = "00000000-0000-0000-0000-000000000000"

    func account(_ id: String, mode: CodexIdentity.Mode = .chatgpt, home: String = "/tmp/codex-home") -> CodexAccount {
        CodexAccount(id: id, kind: .standard, label: "Codex \(id)", customName: nil,
                     defaultName: "\(id)@example.com", home: home, homePath: "~/.codex",
                     identity: CodexIdentity(mode: mode, accountId: Self.fixtureAccountId), state: .signedOut, pids: [])
    }

    func status(_ accounts: [CodexAccount], found: [CodexAccount] = [], version: String? = "0.166.0") -> CodexStatus {
        CodexStatus(installed: true, version: version, accounts: accounts, found: found, hiddenCount: 0)
    }

    func collector(_ status: CodexStatus, runner: FakeUsageRunner) -> CodexUsageCollector {
        CodexUsageCollector(status: { status }, runner: runner, codexCLI: cli, now: { Date(timeIntervalSince1970: 1_780_000_000) })
    }

    static func lines(_ fixture: String) -> [String] {
        fixture.split(whereSeparator: \.isNewline).map(String.init)
    }

    func fakeRunner(answering lines: [String], outcome: UsageProcessResult.Outcome = .stopped) -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in UsageProcessResult(lines: lines, outcome: outcome) }
        return runner
    }

    @Test("0.152.1 fixture: session and weekly windows, plus plan")
    func fixture152() {
        let runner = fakeRunner(answering: Self.lines(UsageFixture.codex_0_152_1))
        let usages = collector(status([account("a1")]), runner: runner).collect()
        #expect(usages.count == 1)
        let usage = try? #require(usages.first)
        #expect(usage?.state == .ok)
        #expect(usage?.plan == "plus")
        #expect(usage?.toolVersion == "0.166.0")
        #expect(usage?.windows.count == 2)
        #expect(usage?.windows[0].kind == .session)
        #expect(usage?.windows[0].usedPercent == 100)
        #expect(usage?.windows[0].resetsAt == Date(timeIntervalSince1970: 1_788_626_797))
        #expect(usage?.windows[1].kind == .weekly)
        #expect(usage?.windows[1].usedPercent == 76)
    }

    @Test("0.166.0 fixture: primary is the weekly window — one window total")
    func fixture166() {
        let runner = fakeRunner(answering: Self.lines(UsageFixture.codex_0_166_0))
        let usage = collector(status([account("a1")]), runner: runner).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.plan == "prolite")
        #expect(usage?.windows.count == 1)
        #expect(usage?.windows.first?.kind == .weekly)
        #expect(usage?.windows.first?.durationMinutes == 10080)
        #expect(usage?.windows.first?.usedPercent == 31)
    }

    static func attributedAnswer(_ accountId: String) -> String {
        #"{"id":2,"result":{"accountId":\#(accountId),"rateLimits":{"planType":"plus","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1780003600}}}}"#
    }

    func attributed(_ accountId: String?) -> CodexAccount {
        CodexAccount(id: "a1", kind: .standard, label: "Codex a1", customName: nil,
                     defaultName: "a1@example.com", home: "/tmp/codex-home", homePath: "~/.codex",
                     identity: CodexIdentity(mode: .chatgpt, email: "a1@example.com", accountId: accountId),
                     state: .signedIn, pids: [])
    }

    func read(_ home: CodexAccount, answering accountId: String) -> AccountUsage? {
        collector(status([home]), runner: fakeRunner(answering: [Self.attributedAnswer(accountId)])).collect().first
    }

    @Test("a read attributed to the home's own account is kept")
    func attributedToSameAccount() {
        let runner = fakeRunner(answering: [Self.attributedAnswer(#""acct-a""#)])
        let usage = collector(status([attributed("acct-a")]), runner: runner).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.map(\.usedPercent) == [42])
    }

    @Test("a read attributed to another account fails closed with no windows",
          arguments: [Optional("acct-a"), nil])
    func attributedToOtherAccount(homeAccount: String?) {
        let runner = fakeRunner(answering: [Self.attributedAnswer(#""acct-b""#)])
        let usage = collector(status([attributed(homeAccount)]), runner: runner).collect().first
        #expect(usage?.state == .failed(.refused))
        #expect(usage?.windows.isEmpty == true)
        #expect(usage?.plan == nil)
    }

    @Test("a mismatched read keeps no earlier windows or plan for that login")
    func mismatchDropsRetention() throws {
        let home = attributed("acct-a")
        let previous = try #require(read(home, answering: #""acct-a""#))
        #expect(previous.state == .ok && previous.identityKey != nil && !previous.windows.isEmpty)
        let mismatched = try #require(read(home, answering: #""acct-b""#))
        #expect(mismatched.identityKey == nil)
        let shown = mismatched.retainingWindows(from: previous)
        #expect(shown.state == .failed(.refused))
        #expect(shown.windows.isEmpty)
        #expect(shown.plan == nil)
    }

    @Test("an empty reported accountId never matches, even an empty home id")
    func emptyAccountIdFailsClosed() {
        let usage = read(attributed(""), answering: String(repeating: "\"", count: 2))
        #expect(usage?.state == .failed(.refused))
        #expect(usage?.windows.isEmpty == true)
    }

    @Test("an answer without the accountId key still reads for an attributed home")
    func missingAccountIdKey() {
        let line = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1780003600}}}}"#
        let usage = collector(status([attributed("acct-a")]), runner: fakeRunner(answering: [line])).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.identityKey != nil)
    }

    @Test("an older server without accountId still reads")
    func unattributedAnswer() {
        let runner = fakeRunner(answering: [Self.attributedAnswer("null")])
        let usage = collector(status([attributed("acct-a")]), runner: runner).collect().first
        #expect(usage?.state == .ok)
        #expect(CodexRateLimitsParser.read([Self.attributedAnswer("null")]).map(\.accountId) == .success(nil))
    }

    @Test("a non-string accountId means the schema changed", arguments: ["7", "true", #"{"x":1}"#])
    func malformedAccountId(value: String) {
        #expect(CodexRateLimitsParser.read([Self.attributedAnswer(value)]) == .failure(.schemaChanged))
    }

    @Test("legacy rateLimits-only shape still reads")
    func legacyShape() {
        let runner = fakeRunner(answering: Self.lines(UsageFixture.codexLegacyRateLimits))
        let usage = collector(status([account("a1")]), runner: runner).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.plan == "pro")
        #expect(usage?.windows.map(\.kind) == [.session, .weekly])
    }

    @Test("server error messages map to problems, their text never surfacing",
          arguments: [
            (#"{"id":2,"error":{"code":-32603,"message":"chatgpt authentication required: x@y.z"}}"#, UsageState.notReporting),
            (#"{"id":2,"error":{"code":-32603,"message":"401 Unauthorized"}}"#, .unavailable(.noSignIn)),
            (#"{"id":2,"error":{"code":-32000,"message":"authentication required"}}"#, .unavailable(.noSignIn)),
            (#"{"id":2,"error":{"code":-32601,"message":"method not found"}}"#, .unavailable(.schemaChanged)),
            (#"{"id":2,"error":{"code":-32000,"message":"unknown variant `rateLimitsV3`"}}"#, .unavailable(.schemaChanged)),
            (#"{"id":2,"error":{"code":-32001,"message":"busy"}}"#, .failed(.rateLimited)),
            (#"{"id":2,"error":{"code":-32000,"message":"retry later"}}"#, .failed(.rateLimited)),
            (#"{"id":2,"error":{"code":-32000,"message":"anything else with a secret"}}"#, .failed(.refused)),
          ])
    func errorMapping(line: String, expected: UsageState) {
        let runner = fakeRunner(answering: [line])
        let usage = collector(status([account("a1")]), runner: runner).collect().first
        #expect(usage?.state == expected)
        #expect(usage?.windows.isEmpty == true)
    }

    @Test("out-of-range values mean the schema changed, never a guessed number")
    func outOfRange() {
        let bad = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":101,"windowDurationMins":300,"resetsAt":1788626797},"secondary":null,"planType":"plus"}}}"#
        let runner = fakeRunner(answering: [bad])
        #expect(collector(status([account("a1")]), runner: runner).collect().first?.state == .unavailable(.schemaChanged))
    }

    @Test("runner outcomes map to states")
    func runnerOutcomes() {
        let account = account("a1")
        var runner = fakeRunner(answering: [], outcome: .timedOut)
        #expect(collector(status([account]), runner: runner).collect().first?.state == .failed(.timeout))
        runner = fakeRunner(answering: [], outcome: .failedToStart)
        #expect(collector(status([account]), runner: runner).collect().first?.state == .unavailable(.cliMissing))
        runner = fakeRunner(answering: [], outcome: .exited(1))
        #expect(collector(status([account]), runner: runner).collect().first?.state == .failed(.refused))
    }

    @Test("api-key and unsigned accounts report without running; found homes are skipped")
    func nonChatGPTAccounts() {
        let runner = fakeRunner(answering: Self.lines(UsageFixture.codex_0_152_1))
        let status = status([account("a1", mode: .apiKey), account("a2", mode: .chatgpt)],
                            found: [account("f1", mode: .chatgpt)])
        let usages = collector(status, runner: runner).collect()
        #expect(usages.map(\.state) == [.notReporting, .ok])
        #expect(usages.map(\.accountRef) == ["a1", "a2"])
        #expect(runner.requests.count == 1) // only the chatgpt-listed account ran; found never runs
    }

    @Test("the request is exactly the plan's argv, CODEX_HOME env and three stdin lines")
    func requestShape() throws {
        let runner = fakeRunner(answering: [])
        _ = collector(status([account("a1", home: "/tmp/codex-home")]), runner: runner).collect()
        let request = try #require(runner.requests.first)
        #expect(request.executable == cli)
        #expect(request.arguments == ["--disable", "plugins", "app-server"])
        #expect(request.environment["CODEX_HOME"] == "/tmp/codex-home")
        #expect(request.stdinLines == CodexUsageCollector.stdinLines(version: "2.0.0"))
        #expect(request.stdinLines?.first?.contains(#""version":"2.0.0""#) == true)
        #expect(request.timeout == 15)
        #expect(FileManager.default.fileExists(atPath: request.workingDirectory.path) == false) // removed after the run
    }

    @Test("stopWhen matches only the id-2 answer")
    func stopPredicate() throws {
        let runner = fakeRunner(answering: [])
        _ = collector(status([account("a1")]), runner: runner).collect()
        let stop = try #require(runner.requests.first?.stopWhen)
        #expect(stop(#"{"id":2,"result":{}}"#))
        #expect(!stop(#"{"id":1,"result":{}}"#))
        #expect(!stop(#"{"method":"account/updated","params":{}}"#))
        #expect(!stop("not json"))
    }
}
