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
        let labels: [String] = contracts.map { (contract: StringContract) -> String in
            String(decoding: contract.alternatives[0], as: UTF8.self)
        }
        let content: Data = bytes(machOMagic, then: labels.joined(separator: "\u{0}"))
        return folder.write(content, to: "home/bin/\(name)", executable: true)
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
    var parts: [String] = [finding.check, finding.summary]
    parts.append(contentsOf: finding.details)
    return parts.joined(separator: "\n")
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

    @Test("a model limit the app's Guide maps to no model is drift, shown without its name")
    func unmappedModelLimit() {
        let panel = """
            Current session: 40% used · resets 7:40pm (Asia/Seoul)
            Current week (all models): 75% used · resets Nov 6 at 12:59pm (Asia/Seoul)
            Current week (Sonnet only): 100% used · resets Nov 6 at 12:59pm (Asia/Seoul)
            Current week (Nimbus preview): 12% used · resets Nov 6 at 1pm (Asia/Seoul)
            """
        let finding = read(Sample.claudeStream(panel)).finding
        #expect(finding.status == .drift)
        #expect(finding.summary.hasPrefix("The app's parser read 4 usage windows, but the Guide maps 1 model limit to no model"))
        // Only the line the Guide can't place; the limits it maps are not listed.
        #expect(finding.details == ["`Current week (…): N% used · resets Mon N at Npm (Zone)`"])
        #expect(!text(of: finding).contains("Nimbus"))
    }

    @Test("the model limits the app's Guide maps are ok")
    func mappedModelLimits() {
        let panel = """
            Current week (all models): 75% used · resets Nov 6 at 12:59pm (Asia/Seoul)
            Current week (Fable): 3% used · resets Nov 6 at 12:59pm (Asia/Seoul)
            Current week (Sonnet only): 100% used · resets Nov 6 at 12:59pm (Asia/Seoul)
            """
        let finding = read(Sample.claudeStream(panel)).finding
        #expect(finding.status == .ok)
        #expect(finding.summary == "The app's parser read 3 usage windows.")
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

    // MARK: - usage_report

    private let unreadCheck = "Claude `/usage` fields the app does not read (live)"

    private func unreadFields(rateLimits: [String: Any]?) -> DriftFinding? {
        let report: [String: Any] = Sample.usageReport(rateLimits: rateLimits)
        return read(Sample.claudeStream(Sample.claudePanel, usageReport: report)).unreadFields
    }

    @Test("a usage_report in the shape this tool knows adds no finding")
    func knownReportShape() {
        #expect(read(Sample.claudeStream(Sample.claudePanel)).unreadFields == nil)
        // An account with no limit listed shows none of a limit's keys; that is not a change.
        var noLimits: [String: Any] = Sample.rateLimits
        noLimits["limits"] = [[String: Any]]()
        #expect(unreadFields(rateLimits: noLimits) == nil)
    }

    @Test("a new key beside the limits is worth a look, and one named like a limit reset is pointed out")
    func newRateLimitsKey() throws {
        var rateLimits: [String: Any] = Sample.rateLimits
        rateLimits["limit_resets"] = ["available": 4, "next_grant_at": "2027-01-02T03:04:05Z"] as [String: Any]
        rateLimits["tier"] = "private-tier"
        let finding = try #require(unreadFields(rateLimits: rateLimits))
        #expect(finding.section == .live)
        #expect(finding.check == unreadCheck)
        #expect(finding.status == .attention)
        let summary: String = "The answer's `usage_report` has 2 fields this tool has not seen before; "
            + "the app reads none of it. It may be the limit resets an account holds, which the app can't "
            + "show for Claude yet. Named like a limit reset: 1."
        #expect(finding.summary == summary)
        #expect(finding.details == [
            "**named like a limit reset** — added `usage_report.rate_limits.limit_resets`",
            "added `usage_report.rate_limits.tier`",
        ])
    }

    @Test("a new key inside a limit is found in whichever limit carries it")
    func newLimitKey() throws {
        var limit: [String: Any] = Sample.usageLimit(scopedTo: "Fable")
        limit["window_minutes"] = 10080
        var rateLimits: [String: Any] = Sample.rateLimits
        rateLimits["limits"] = [Sample.usageLimit(), limit]
        let finding = try #require(unreadFields(rateLimits: rateLimits))
        #expect(finding.status == .attention)
        let summary: String = "The answer's `usage_report` has 1 field this tool has not seen before; "
            + "the app reads none of it. It may be the limit resets an account holds, which the app can't "
            + "show for Claude yet."
        #expect(finding.summary == summary)
        #expect(finding.details == ["added `usage_report.rate_limits.limits[].window_minutes`"])
    }

    @Test("a new key is found at every position this tool knows, and nothing is looked at anywhere else")
    func watchedPositions() throws {
        let model: [String: Any] = ["display_name": "Fable", "family": "x"]
        let surface: [String: Any] = ["display_name": "private-surface", "channel": "x"]
        let scope: [String: Any] = ["model": model, "surface": surface, "origin": "x"]
        var limit: [String: Any] = Sample.usageLimit()
        limit["scope"] = scope
        limit["grants_left"] = 2
        var rateLimits: [String: Any] = Sample.rateLimits
        rateLimits["limits"] = [limit]
        var extra: [String: Any] = rateLimits["extra_usage"] as? [String: Any] ?? [:]
        extra["credit_balance"] = 5
        rateLimits["extra_usage"] = extra
        rateLimits["plan"] = "x"
        var report: [String: Any] = Sample.usageReport(rateLimits: rateLimits)
        // The session totals are keyed by model name; nobody has vetted what lies in there.
        let byModel: [String: Any] = ["private-model": ["cost": 1] as [String: Any]]
        report["session"] = ["model_usage": byModel, "private_total": 1] as [String: Any]
        report["notices"] = ["x"]
        let finding = try #require(read(Sample.claudeStream(Sample.claudePanel, usageReport: report)).unreadFields)
        #expect(finding.status == .attention)
        #expect(finding.details == [
            "**named like a limit reset** — added `usage_report.rate_limits.extra_usage.credit_balance`",
            "**named like a limit reset** — added `usage_report.rate_limits.limits[].grants_left`",
            "added `usage_report.notices`",
            "added `usage_report.rate_limits.limits[].scope.model.family`",
            "added `usage_report.rate_limits.limits[].scope.origin`",
            "added `usage_report.rate_limits.limits[].scope.surface.channel`",
            "added `usage_report.rate_limits.plan`",
        ])
    }

    @Test("only the name of a new key is shown: never a value, a name below it, or a key that may be an id")
    func unreadFieldsLeakNothing() throws {
        var rateLimits: [String: Any] = Sample.rateLimits
        rateLimits["limit_resets"] = ["granted_to": Sample.email, "next_grant_at": "2027-01-02T03:04:05Z",
                                      "available": 4] as [String: Any]
        rateLimits["org-AbCdEf123456"] = ["used": 1] as [String: Any]
        rateLimits[Sample.accountId] = "x"
        rateLimits["credit9f8e7d6c"] = 1
        let finding = try #require(unreadFields(rateLimits: rateLimits))
        #expect(finding.details == [
            "**named like a limit reset** — added `usage_report.rate_limits.*`",
            "**named like a limit reset** — added `usage_report.rate_limits.limit_resets`",
            "added `usage_report.rate_limits.*`",
        ])
        for secret in [Sample.email, Sample.accountId, "AbCdEf", "9f8e7d6c", "2027-01-02", "granted_to",
                       "next_grant_at", "available", "Fable", "2026-11-20", "weekly_scoped", "normal", "53"] {
            #expect(!text(of: finding).contains(secret))
        }
    }

    @Test("a known key that is absent adds no finding: several are optional, and the app reads none")
    func absentReportKeys() throws {
        var limit: [String: Any] = Sample.usageLimit()
        limit["scope"] = nil
        limit["severity"] = nil
        var rateLimits: [String: Any] = Sample.rateLimits
        rateLimits["limits"] = [limit]
        rateLimits["extra_usage"] = nil
        #expect(unreadFields(rateLimits: rateLimits) == nil)
        rateLimits["limits"] = NSNull()
        #expect(unreadFields(rateLimits: rateLimits) == nil)
        // What is new is still reported, and only that.
        rateLimits["overage"] = "x"
        let finding = try #require(unreadFields(rateLimits: rateLimits))
        #expect(finding.details == ["added `usage_report.rate_limits.overage`"])
    }

    @Test("an answer without usage_report can't be watched: worth a look when the panel was read, else nothing")
    func missingReport() throws {
        let finding = try #require(read(Sample.claudeStream(Sample.claudePanel, usageReport: nil)).unreadFields)
        #expect(finding.check == unreadCheck)
        #expect(finding.status == .attention)
        let summary: String = "The answer carries no `usage_report.rate_limits` to compare, so a new field "
            + "there (the limit resets an account holds, say) would go unnoticed. The app reads the panel text "
            + "and is not affected."
        #expect(finding.summary == summary)
        #expect(finding.details.isEmpty)
        #expect(unreadFields(rateLimits: nil) == finding)
        // When the read itself settled nothing, its own finding already says so.
        #expect(read(Sample.claudeStream("You are not signed in", usageReport: nil)).unreadFields == nil)
        #expect(read([], outcome: .timedOut).unreadFields == nil)
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
        #expect(finding.details == ["plan name: present", "account attribution: present",
                                    "reset credits: present, with details"])
        #expect(runner.requests.count == 1)
        let request = try #require(runner.requests.first)
        #expect(request.executable == cli)
        #expect(request.arguments == ["--disable", "plugins", "app-server"])
        #expect(request.environment["CODEX_HOME"] == rig.home.appendingPathComponent(".codex").path)
        let sent = try #require(request.stdinLines)
        // Each run is an account's first read, which is the one where the app also asks for the
        // reset-credit details.
        #expect(sent == CodexUsageCollector.stdinLines(version: ProductInfo.fallbackVersion, resetCreditDetails: true))
        #expect(!sent.joined().contains("rateLimitResetCredit"))
        #expect(!sent.joined().contains("login") && !sent.joined().contains("logout"))
    }

    @Test("with or without reset-credit details, what the app sends only reads", arguments: [false, true])
    func requestOnlyReads(details: Bool) throws {
        let lines: [String] = CodexUsageCollector.stdinLines(version: "1.0", resetCreditDetails: details)
        let messages: [[String: Any]] = lines.compactMap { (line: String) -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let methods: [String] = messages.compactMap { (message: [String: Any]) -> String? in
            message["method"] as? String
        }
        #expect(methods == ["initialize", "initialized", "account/rateLimits/read"])
        // The two forms differ in one flag of the same read and nothing else.
        let read = try #require(messages.last?["params"] as? [String: Any])
        #expect(Array(read.keys) == ["excludeResetCreditDetails"])
        #expect(read["excludeResetCreditDetails"] as? Bool == !details)
        // Spending a reset credit is never among them.
        for line in lines {
            #expect(!line.contains(CodexAppContract.neverCalled))
            #expect(!line.contains("rateLimitResetCredit"))
            #expect(!line.lowercased().contains("consume"))
        }
    }

    @Test("reset credits are reported by presence only")
    func resetCredits() {
        let countOnly: [String: Any] = ["availableCount": 2]
        #expect(read(Sample.codexAnswer(resetCredits: countOnly)).details.last == "reset credits: count only")
        #expect(read(Sample.codexAnswer(resetCredits: nil)).details.last == "reset credits: absent")
        let detailed = read(Sample.codexAnswer())
        #expect(detailed.status == .ok)
        for secret in ["Private credit title", "RateLimitResetCredit_private_1", "1795000000", "codexRateLimits"] {
            #expect(!text(of: detailed).contains(secret))
        }
    }

    @Test("reset credits the app's parser silently drops are drift, not a clean read")
    func unreadableResetCredits() {
        var changed: [String: Any] = Sample.defaultResetCredits
        changed["availableCount"] = "one"
        let finding = read(Sample.codexAnswer(resetCredits: changed))
        #expect(finding.status == .drift)
        #expect(finding.summary.contains("reset credits the app's parser no longer reads"))
        #expect(finding.details.contains("`rateLimitResetCredits.availableCount: string`"))
        #expect(finding.details.contains("`rateLimitResetCredits.credits: array`"))
        for secret in ["Private credit title", "RateLimitResetCredit_private_1", Sample.accountId] {
            #expect(!text(of: finding).contains(secret))
        }
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
            "rateLimitResetCredits: object", "rateLimitResetCredits.availableCount: number",
            "rateLimitResetCredits.credits: array",
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
