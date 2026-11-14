import Foundation
import Testing
@testable import SwitcherCore
@testable import VendorDrift

/// A home folder with fake CLIs, and a `DriftRun` over it that can only reach `FakeRunner`.
struct DriftRig {
    let folder = TempFolder()
    let home: URL
    let bin: URL
    let work: URL

    init() {
        home = folder.folder("home")
        bin = folder.folder("home/bin")
        work = folder.folder("work")
    }

    func cli(_ name: String, containing contracts: [StringContract] = []) -> URL {
        let text = contracts.map { String(decoding: $0.alternatives[0], as: UTF8.self) }.joined(separator: "\u{0}")
        return folder.write(Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(text.utf8), to: "home/bin/\(name)", executable: true)
    }

    func signIntoCodex() { folder.write("", to: "home/.codex/auth.json") }

    func run(_ runner: FakeRunner, frozen: CodexProtocolSnapshot? = nil, bundledCodexCLI: URL? = nil,
             gemini: any GeminiOAuthClientFinding = GeminiOAuthClientFinder()) -> DriftRun {
        var run = DriftRun(home: home, path: "", bundledCodexCLI: bundledCodexCLI, frozen: frozen,
                           workDirectory: work, runner: runner,
                           searchRoots: UsageSearchRoots(executableDirectories: [bin], applicationDirectories: []),
                           geminiClient: gemini, now: { Date(timeIntervalSince1970: 1_794_000_000) })
        run.claudeManaged = ClaudeManagedSettings(folder: folder.url.appendingPathComponent("no-managed"),
                                                  preferences: folder.url.appendingPathComponent("no-preferences"))
        return run
    }
}

func text(of finding: DriftFinding) -> String {
    ([finding.check, finding.summary] + finding.details).joined(separator: "\n")
}

@Suite("Live Claude checks")
struct LiveClaudeChecksTests {
    let rig = DriftRig()

    private func read(_ lines: [String], outcome: UsageProcessResult.Outcome = .stopped) -> DriftRun.ClaudeRead {
        let runner = FakeRunner { _ in UsageProcessResult(lines: lines, outcome: outcome) }
        return rig.run(runner).claudeUsage(rig.cli("claude"))
    }

    @Test("a panel the app's parser reads is ok, shown without a single value")
    func readablePanel() throws {
        let runner = FakeRunner { _ in UsageProcessResult(lines: Sample.claudeStream(Sample.claudePanel), outcome: .stopped) }
        let cli = rig.cli("claude")
        let read = rig.run(runner).claudeUsage(cli)
        #expect(read.finding.status == .ok)
        #expect(read.finding.summary == "The app's parser read 3 usage windows.")
        #expect(read.finding.details == [
            "`Current session: N% used · resets N:Npm (Zone)`",
            "`Current week (all models): N% used · resets Mon N at N:Npm (Zone)`",
            "`Current week (…): N% used · resets Mon N at N:Npm (Zone)`",
        ])
        // The request is the one the app's collector builds, not a copy of it.
        let request = try #require(read.request)
        #expect(request.executable == cli)
        #expect(request.arguments == ClaudeUsageCollector.arguments)
        #expect(request.environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(request.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(request.workingDirectory == rig.work)
        #expect(runner.requests.count == 1)
    }

    @Test("a Current line the parser no longer matches is drift")
    func changedLine() {
        let read = read(Sample.claudeStream("Current week: 75% used, resets soon"))
        #expect(read.finding.status == .drift)
        #expect(read.finding.details == ["`Current week: N% used, resets …`"])
    }

    @Test("no Current line is only drift when the panel still reports usage elsewhere")
    func noCurrentLine() {
        #expect(read(Sample.claudeStream("You are not signed in")).finding.status == .attention)
        let renamed = read(Sample.claudeStream("Weekly limit: 40% used · resets Nov 6"))
        #expect(renamed.finding.status == .drift)
        #expect(renamed.finding.details.isEmpty)
    }

    @Test("a run that did work is drift; a missing result line is worth a look")
    func discardedOutput() {
        let worked = read([#"{"type":"assistant","message":{"model":"a-real-model"}}"#,
                           #"{"type":"result","is_error":false,"num_turns":1,"total_cost_usd":0.2,"result":"x"}"#])
        #expect(worked.finding.status == .drift)
        #expect(worked.finding.summary.contains("did more than answer"))
        let empty = read([#"{"type":"system","subtype":"init"}"#], outcome: .exited(1))
        #expect(empty.finding.status == .attention)
        #expect(empty.finding.summary.contains("no clean result line"))
    }

    @Test("a run that never answers settles nothing")
    func noAnswer() {
        #expect(read([], outcome: .timedOut).finding.status == .attention)
        #expect(read([], outcome: .failedToStart).finding.status == .attention)
        #expect(read([], outcome: .outputLimit).finding.status == .attention)
    }

    @Test("under managed Claude Code settings nothing is run, as in the app")
    func managedSettings() {
        let runner = FakeRunner { _ in UsageProcessResult(lines: [], outcome: .stopped) }
        var run = rig.run(runner)
        run.claudeManaged = ClaudeManagedSettings(folder: rig.folder.folder("managed"),
                                                  preferences: rig.folder.url.appendingPathComponent("none"))
        rig.folder.write("{}", to: "managed/managed-settings.json")
        let read = run.claudeUsage(rig.cli("claude"))
        #expect(read.finding.status == .skipped)
        #expect(read.request == nil)
        #expect(runner.requests.isEmpty)
    }

    @Test("nothing from the answer reaches the finding")
    func nothingLeaks() {
        for panel in [Sample.claudePanel, "Current plan: \(Sample.email) (\(Sample.accountId))"] {
            let finding = read(Sample.claudeStream(panel)).finding
            for secret in [Sample.email, Sample.accountId, "Asia/Seoul", "private-server", "Fable", "75"] {
                #expect(!text(of: finding).contains(secret))
            }
        }
    }

    // MARK: - auth status

    private func usageRequest() -> UsageProcessRequest {
        UsageProcessRequest(executable: rig.cli("claude"), arguments: ClaudeUsageCollector.arguments,
                            environment: ["HOME": rig.home.path, "DISABLE_AUTOUPDATER": "1"],
                            workingDirectory: rig.work, timeout: 60)
    }

    private func authStatus(_ output: String, outcome: UsageProcessResult.Outcome = .exited(0)) -> DriftFinding {
        let runner = FakeRunner { _ in UsageProcessResult(lines: output.components(separatedBy: "\n"), outcome: outcome) }
        return rig.run(runner).claudeAuthStatus(usageRequest())
    }

    @Test("the sign-in status is asked the way the app asks it")
    func authStatusRequest() throws {
        let runner = FakeRunner { _ in UsageProcessResult(lines: [Sample.authStatus()], outcome: .exited(0)) }
        let usage = usageRequest()
        #expect(rig.run(runner).claudeAuthStatus(usage).status == .ok)
        let request = try #require(runner.requests.first)
        #expect(request.arguments == ["auth", "status", "--json"])
        #expect(request.executable == usage.executable)
        #expect(request.environment == usage.environment)
        #expect(request.workingDirectory == usage.workingDirectory)
        #expect(request.stdinLines == nil)
    }

    @Test("a signed-out status without identity keys is still the shape the app reads")
    func signedOutStatus() {
        #expect(authStatus(#"{"loggedIn":false,"analyticsDisabled":false}"#, outcome: .exited(1)).status == .ok)
    }

    @Test("a status the app's parser rejects is drift, described by key names only")
    func changedStatus() {
        let finding = authStatus(Sample.authStatus(dropping: "orgId"))
        #expect(finding.status == .drift)
        #expect(finding.details.contains("`email: string`"))
        #expect(finding.details.contains("`loggedIn: boolean`"))
        #expect(!finding.details.contains { $0.contains("orgId") })
        for secret in [Sample.email, Sample.accountId, "Someone's Org", "/Users/someone"] {
            #expect(!text(of: finding).contains(secret))
        }
    }

    @Test("a key nobody has vetted is never printed: it may itself be an id")
    func unknownStatusKeys() {
        let finding = authStatus(#"{"loggedIn":"yes","org-AbCdEf123456":{"\#(Sample.email)":1},"acctName":"x"}"#)
        #expect(finding.status == .drift)
        #expect(finding.details == ["`*: object`", "`*: string`", "`loggedIn: string`"])
    }

    @Test("every key in the sign-in status contract is one the app's parser requires")
    func statusContractMatchesParser() {
        #expect(ClaudeProfileUsageCollector.understandsAuthStatus(Data(Sample.authStatus().utf8)))
        for key in ClaudeAuthStatusContract.keys {
            #expect(!ClaudeProfileUsageCollector.understandsAuthStatus(Data(Sample.authStatus(dropping: key).utf8)),
                    "\(key) is listed but the parser doesn't require it")
        }
    }

    @Test("output that isn't JSON is drift; a command that doesn't finish settles nothing")
    func unusableStatus() {
        let garbage = authStatus("Signed in as \(Sample.email)")
        #expect(garbage.status == .drift)
        #expect(garbage.summary.hasSuffix("It is not a JSON object."))
        #expect(!text(of: garbage).contains(Sample.email))
        #expect(authStatus("", outcome: .timedOut).status == .attention)
        #expect(authStatus("", outcome: .failedToStart).status == .attention)
    }
}

@Suite("Live Codex check")
struct LiveCodexCheckTests {
    let rig = DriftRig()

    private func read(_ lines: [String], outcome: UsageProcessResult.Outcome = .stopped) -> DriftFinding {
        rig.signIntoCodex()
        let runner = FakeRunner { _ in UsageProcessResult(lines: lines, outcome: outcome) }
        return rig.run(runner).codexRateLimits(DriftRun.CodexCLI(label: "test", url: rig.cli("codex"), version: "1.2.3"))
    }

    private func error(_ message: String, code: Int = -32000) -> [String] {
        [#"{"id":2,"error":{"code":\#(code),"message":"\#(message)"}}"#]
    }

    @Test("without a sign-in in ~/.codex nothing is started")
    func signedOutHome() {
        let runner = FakeRunner { _ in UsageProcessResult(lines: [], outcome: .stopped) }
        let finding = rig.run(runner).codexRateLimits(DriftRun.CodexCLI(label: "test", url: rig.cli("codex"), version: nil))
        #expect(finding.status == .skipped)
        #expect(runner.requests.isEmpty)
    }

    @Test("the server is asked exactly what the app asks, and nothing that changes state")
    func request() throws {
        rig.signIntoCodex()
        let runner = FakeRunner { _ in UsageProcessResult(lines: Sample.codexAnswer(), outcome: .stopped) }
        let cli = rig.cli("codex")
        let finding = rig.run(runner).codexRateLimits(DriftRun.CodexCLI(label: "test", url: cli, version: "1.2.3"))
        #expect(finding.status == .ok)
        #expect(finding.summary == "The app's parser read 1 usage window.")
        #expect(finding.details == ["plan name: present", "account attribution: present"])
        #expect(runner.requests.count == 1)
        let request = try #require(runner.requests.first)
        #expect(request.executable == cli)
        #expect(request.arguments == ["--disable", "plugins", "app-server"])
        #expect(request.environment["CODEX_HOME"] == rig.home.appendingPathComponent(".codex").path)
        let sent = try #require(request.stdinLines)
        #expect(sent == CodexUsageCollector.stdinLines(version: ProductInfo.fallbackVersion))
        #expect(!sent.joined().contains("rateLimitResetCredit"))
        #expect(!sent.joined().contains("login") && !sent.joined().contains("logout"))
    }

    @Test("an answer the app's parser rejects is drift, described by key names only")
    func changedAnswer() {
        let finding = read(Sample.codexAnswer(window: ["usedPercent": "31%", "windowDurationMins": 10080]))
        #expect(finding.status == .drift)
        #expect(finding.details.contains("`rateLimitsByLimitId.*.primary.usedPercent: string`"))
        #expect(finding.details.contains("`accountId: string`"))
        #expect(finding.details.contains("`rateLimits.*: string`"))
        for secret in [Sample.accountId, "other-limit", "31%", "plus", "limitId", "codex"] {
            #expect(!text(of: finding).contains(secret))
        }
    }

    @Test("errors the app maps to a sign-in state are not drift")
    func signInStates() {
        #expect(read(error("chatgpt authentication required")).status == .skipped)
        #expect(read(error("authentication required")).status == .skipped)
        #expect(read(error("please retry later", code: -32001)).status == .attention)
        #expect(read(error("something else for \(Sample.email)")).status == .attention)
        #expect(!text(of: read(error("something else for \(Sample.email)"))).contains(Sample.email))
    }

    @Test("a method the server no longer knows is drift")
    func unknownMethod() {
        #expect(read(error("Method not found", code: -32601)).status == .drift)
    }

    @Test("a server that never answers settles nothing")
    func noAnswer() {
        #expect(read([#"{"id":1,"result":{}}"#], outcome: .exited(0)).status == .attention)
        #expect(read([], outcome: .timedOut).status == .attention)
        #expect(read([], outcome: .failedToStart).status == .attention)
    }

    @Test("the keys of an answer show only names the contract or the snapshot knows")
    func answerKeys() {
        let run = rig.run(FakeRunner { _ in UsageProcessResult(lines: [], outcome: .stopped) })
        #expect(Set(run.answerKeys(Sample.codexAnswer())) == [
            "accountId: string",
            "rateLimits: object", "rateLimits.*: string", "rateLimits.planType: string",
            "rateLimits.primary: object", "rateLimits.primary.resetsAt: number",
            "rateLimits.primary.usedPercent: number", "rateLimits.primary.windowDurationMins: number",
            "rateLimits.secondary: null",
            "rateLimitsByLimitId: object", "rateLimitsByLimitId.*: object", "rateLimitsByLimitId.*.*: string",
            "rateLimitsByLimitId.*.planType: string", "rateLimitsByLimitId.*.primary: object",
            "rateLimitsByLimitId.*.primary.resetsAt: number", "rateLimitsByLimitId.*.primary.usedPercent: number",
            "rateLimitsByLimitId.*.primary.windowDurationMins: number", "rateLimitsByLimitId.*.secondary: null",
        ])
        #expect(run.answerKeys(["not json", #"{"id":1,"result":{"a":1}}"#]).isEmpty)
        // A name the frozen snapshot carries is known too.
        var frozen = run
        frozen.frozen = CodexProtocolSnapshot(cliVersion: nil, requests: [:], clientNotifications: [:],
                                              notifications: [:], types: ["RateLimitSnapshot": ["limitId": "string"]])
        #expect(frozen.answerKeys(Sample.codexAnswer()).contains("rateLimits.limitId: string"))
    }
}
