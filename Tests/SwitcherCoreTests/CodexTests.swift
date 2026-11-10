import Darwin
import Foundation
import Testing
@testable import SwitcherCore

// MARK: - Fakes

/// Processes for the Codex tests: Codex windows and helpers with an optional CODEX_HOME.
final class CodexProcessTable: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var procs: [ProcInfo] = []
    private var homes: [pid_t: String] = [:]
    private var appData: [pid_t: String] = [:]

    func add(pid: pid_t, path: String, ppid: pid_t = 1, comm: String? = nil, codexHome: String? = nil, appDataPath: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        procs.append(ProcInfo(pid: pid, ppid: ppid, pgid: pid, comm: comm ?? (path as NSString).lastPathComponent,
                              path: path, startTime: Date()))
        homes[pid] = codexHome
        appData[pid] = appDataPath
    }

    func remove(pid: pid_t) { lock.lock(); procs.removeAll { $0.pid == pid }; lock.unlock() }

    /// The same pid now belongs to a different process (pid reuse).
    func reuse(pid: pid_t, path: String) {
        lock.lock(); defer { lock.unlock() }
        procs.removeAll { $0.pid == pid }
        procs.append(ProcInfo(pid: pid, ppid: 1, pgid: pid, comm: (path as NSString).lastPathComponent, path: path,
                              startTime: Date().addingTimeInterval(60)))
    }

    func all() -> [ProcInfo] { lock.lock(); defer { lock.unlock() }; return procs }

    func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var values: [String: String] = [:]
        if keys.contains("CODEX_HOME"), let home = homes[pid] { values["CODEX_HOME"] = home }
        if keys.contains("CODEX_ELECTRON_USER_DATA_PATH"), let data = appData[pid] { values["CODEX_ELECTRON_USER_DATA_PATH"] = data }
        return values
    }
}

/// Records what the Codex tab asked of Codex; `login` decides what a `codex login` run does.
final class FakeCodexControl: CodexAppControl, @unchecked Sendable {
    struct Launch: Equatable { let home: String?; let appDataDir: String? }
    struct CLIRun: Equatable { let arguments: [String]; let home: String }

    private let lock = NSLock()
    private var _launches: [Launch] = []
    private var _activated: [pid_t] = []
    private var _quitRequests: [pid_t] = []
    private var _terminated: [pid_t] = []
    private var _cliRuns: [CLIRun] = []
    private var _trashed: [URL] = []
    private var _forceKilled: [pid_t] = []
    private var _stopAllCalls = 0
    let table: CodexProcessTable
    let trashDir: URL
    /// Whether a quit request really closes the window, and whether a running window can be brought forward.
    var quitWorks = true
    var activateWorks = true
    /// Whether `codex logout` really removes the sign-in, and whether SIGTERM ends a helper.
    var logoutWorks = true
    var terminateWorks = true
    /// What `codex login` does: usually writes a sign-in into the home and exits 0.
    var login: @Sendable (URL, @Sendable (String) -> Void, @Sendable () -> Bool) -> CodexCLIOutcome = { _, _, _ in .exited(0) }

    init(table: CodexProcessTable, trashDir: URL) { self.table = table; self.trashDir = trashDir }

    var launches: [Launch] { lock.lock(); defer { lock.unlock() }; return _launches }
    var activated: [pid_t] { lock.lock(); defer { lock.unlock() }; return _activated }
    var quitRequests: [pid_t] { lock.lock(); defer { lock.unlock() }; return _quitRequests }
    var terminated: [pid_t] { lock.lock(); defer { lock.unlock() }; return _terminated }
    var cliRuns: [CLIRun] { lock.lock(); defer { lock.unlock() }; return _cliRuns }
    var trashed: [URL] { lock.lock(); defer { lock.unlock() }; return _trashed }
    var forceKilled: [pid_t] { lock.lock(); defer { lock.unlock() }; return _forceKilled }
    var stopAllCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopAllCalls }

    func launch(appURL: URL, home: URL?, appDataDir: URL?) throws {
        lock.lock(); _launches.append(Launch(home: home?.path, appDataDir: appDataDir?.path)); lock.unlock()
    }

    func activate(pid: pid_t) -> Bool {
        lock.lock(); _activated.append(pid); lock.unlock()
        return activateWorks && table.all().contains { $0.pid == pid }
    }

    func requestQuit(pid: pid_t) -> Bool {
        lock.lock(); _quitRequests.append(pid); lock.unlock()
        if quitWorks { table.remove(pid: pid) }
        return true
    }

    func signalTerminate(pid: pid_t) -> Bool {
        lock.lock(); _terminated.append(pid); lock.unlock()
        if terminateWorks { table.remove(pid: pid) }
        return true
    }

    func forceKill(pid: pid_t) -> Bool {
        lock.lock(); _forceKilled.append(pid); lock.unlock()
        table.remove(pid: pid)
        return true
    }

    func stopAllCommands(grace: TimeInterval) { lock.lock(); _stopAllCalls += 1; lock.unlock() }

    func runCLI(_ cli: URL, arguments: [String], home: URL, timeout: TimeInterval,
                shouldStop: @escaping @Sendable () -> Bool, onOutput: @escaping @Sendable (String) -> Void) -> CodexCLIOutcome {
        lock.lock(); _cliRuns.append(CLIRun(arguments: arguments, home: home.path)); lock.unlock()
        if arguments.first == "logout" {
            guard logoutWorks else { return .exited(1) }
            try? FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))
            return .exited(0)
        }
        return login(home, onOutput, shouldStop)
    }

    func moveToTrash(_ url: URL) throws {
        lock.lock(); _trashed.append(url); lock.unlock()
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString))
    }

    func bundleVersion(appURL: URL) -> String? { "26.0" }
}

// MARK: - Fixture

struct CodexRig {
    let sandbox: Sandbox
    let table = CodexProcessTable()
    let control: FakeCodexControl
    let manager: CodexManager
    var env: SwitcherEnvironment { manager.env }
    var appExecutable: String { env.codexAppURL.appendingPathComponent("Contents/MacOS/ChatGPT").path }

    init(installed: Bool = true) throws {
        sandbox = try Sandbox()
        var env = sandbox.env
        env.codexAppURL = sandbox.root.appendingPathComponent("Applications/Codex.app", isDirectory: true)
        if installed {
            let cli = env.codexCLI
            try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: cli)
            try FileManager.default.createDirectory(at: env.codexAppURL.appendingPathComponent("Contents/MacOS"),
                                                    withIntermediateDirectories: true)
        }
        control = FakeCodexControl(table: table, trashDir: sandbox.root.appendingPathComponent("Trash", isDirectory: true))
        var options = CodexManager.Options()
        options.quitTimeout = 0.5
        options.pollInterval = 0.02
        manager = CodexManager(env: env, table: table, control: control, options: options)
    }

    func home(_ name: String) -> URL { env.home.appendingPathComponent(name, isDirectory: true) }

    /// A Codex home signed in with ChatGPT as `email` (or with an API key when `email` is nil).
    @discardableResult
    func makeHome(_ name: String, email: String?, plan: String = "pro") throws -> URL {
        let url = home(name)
        try CodexFixture.writeAuth(into: url, email: email, plan: plan)
        return url
    }

    /// Adds found homes to the list (found homes are only suggested until then).
    func adopt(_ ids: String...) throws { for id in ids { try manager.adopt(id) } }

    func cleanup() { sandbox.remove() }
}

enum CodexFixture {
    static func jwt(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return part(["alg": "none"]) + "." + part(claims) + ".FAKE-SIGNATURE"
    }

    static func writeAuth(into home: URL, email: String?, plan: String = "pro") throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var object: [String: Any] = ["last_refresh": "2026-10-18T00:00:00Z"]
        if let email {
            object["auth_mode"] = "chatgpt"
            object["OPENAI_API_KEY"] = NSNull()
            object["tokens"] = [
                "id_token": jwt(["email": email, "name": "Fake User",
                                 "https://api.openai.com/auth": ["chatgpt_plan_type": plan, "chatgpt_account_id": "acct-\(email.prefix(4))"]]),
                "access_token": "FAKE-ACCESS-TOKEN", "refresh_token": "FAKE-REFRESH-TOKEN", "account_id": "acct-fallback",
            ]
        } else {
            object["auth_mode"] = "apikey"
            object["OPENAI_API_KEY"] = "FAKE-API-KEY"
        }
        try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent("auth.json"))
    }
}

// MARK: - Tests

@Suite("Codex tab")
struct CodexTests {
    @Test func accountIdFollowsTheTokensAccountIdCodexAttributesReadsTo() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        func write(_ name: String, tokenAccountId: String?) throws -> URL {
            let url = rig.home(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var tokens: [String: Any] = ["id_token": CodexFixture.jwt([
                "email": "alex@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct-stale-claim"]])]
            tokens["account_id"] = tokenAccountId
            try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens])
                .write(to: url.appendingPathComponent("auth.json"))
            return url
        }
        // After a workspace switch the id token keeps the old claim; tokens.account_id is current.
        #expect(CodexIdentity.read(home: try write(".codex-switched", tokenAccountId: "acct-workspace-b"))?.accountId
                == "acct-workspace-b")
        #expect(CodexIdentity.read(home: try write(".codex-claim-only", tokenAccountId: nil))?.accountId
                == "acct-stale-claim")
        #expect(CodexIdentity.read(home: try write(".codex-empty-token-id", tokenAccountId: ""))?.accountId
                == "acct-stale-claim")
    }

    @Test func identityComesFromTheIdTokenClaimsAndTokensAccountId() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let chatgpt = try rig.makeHome(".codex", email: "alex@example.com", plan: "team")
        let identity = try #require(CodexIdentity.read(home: chatgpt))
        #expect(identity == CodexIdentity(mode: .chatgpt, email: "alex@example.com", name: "Fake User", plan: "team",
                                          accountId: "acct-fallback"))
        let encoded = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        #expect(!encoded.contains("FAKE-ACCESS-TOKEN") && !encoded.contains("FAKE-REFRESH-TOKEN") && !encoded.contains("FAKE-SIGNATURE"))

        let apiKey = try rig.makeHome(".codex_second", email: nil)
        #expect(CodexIdentity.read(home: apiKey) == CodexIdentity(mode: .apiKey))
        #expect(CodexIdentity.read(home: rig.home(".codex-nothing")) == nil)
        try rig.sandbox.write("{not json", to: rig.home(".codex-bad").appendingPathComponent("auth.json"))
        #expect(CodexIdentity.read(home: rig.home(".codex-bad")) == CodexIdentity(mode: .unknown))
    }

    @Test func foundHomesAreOnlySuggestedUntilAdded() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.makeHome(".codex_second", email: nil)
        try rig.sandbox.write("model = \"x\"\n", to: rig.home(".codex-old").appendingPathComponent("config.toml"))
        try rig.makeHome(".codexfoo", email: "no@example.com")                  // not a Codex home name
        try FileManager.default.createDirectory(at: rig.home(".codex-empty"), withIntermediateDirectories: true)
        try rig.sandbox.write("x", to: rig.home(".codex-file"))                 // a file, not a folder

        var status = rig.manager.status()
        #expect(status.installed && status.version == "26.0")
        #expect(status.accounts.map(\.id) == ["standard"])
        #expect(status.found.map(\.id) == ["found:.codex-old", "found:.codex-work", "found:.codex_second"])
        // Nothing can be done to a suggestion except adding or hiding it.
        #expect(switcherError { _ = try rig.manager.open("found:.codex-work") } == .unknownAccount("found:.codex-work"))
        #expect(switcherError { _ = try rig.manager.reauthenticate("found:.codex-work") } == .unknownAccount("found:.codex-work"))

        try rig.manager.adopt(".codex-work")              // by folder name
        try rig.manager.adopt("found:.codex_second")
        try rig.manager.dismiss(".codex-old")
        status = rig.manager.status()
        #expect(status.accounts.map(\.id) == ["standard", "found:.codex-work", "found:.codex_second"])
        #expect(status.found.isEmpty && status.hiddenCount == 1)
        let byID = Dictionary(uniqueKeysWithValues: status.accounts.map { ($0.id, $0) })
        #expect(byID["standard"]?.label == "alex@example.com" && byID["standard"]?.homePath == "~/.codex")
        #expect(byID["found:.codex-work"]?.state == .signedIn && byID["found:.codex-work"]?.identity?.plan == "pro")
        #expect(byID["found:.codex_second"]?.label == L10n.t(.codexApiKeyName, ".codex_second"))
        try rig.manager.unhideAll()
        #expect(rig.manager.status().found.map(\.id) == ["found:.codex-old"])
    }

    @Test func openWindowsAreMatchedByTheirCodexHome() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.adopt("found:.codex-work")
        rig.table.add(pid: 501, path: rig.appExecutable)                                   // standard window
        rig.table.add(pid: 502, path: rig.appExecutable, codexHome: work.path, appDataPath: "/d/work")
        rig.table.add(pid: 503, path: rig.env.codexAppURL.appendingPathComponent(
            "Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler").path)   // helper, not a window
        rig.table.add(pid: 504, path: rig.appExecutable, ppid: 501)                      // a child, not a window
        let byID = Dictionary(uniqueKeysWithValues: rig.manager.status().accounts.map { ($0.id, $0) })
        #expect(byID["standard"]?.pids == [501] && byID["standard"]?.state == .running)
        #expect(byID["found:.codex-work"]?.pids == [502])
        #expect(rig.manager.status().runningCount == 2)
    }

    @Test func openBringsAWindowForwardOrStartsTheRightInstance() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")
        let second = try rig.makeHome(".codex_second", email: nil)
        let ownData = rig.env.home.appendingPathComponent("Library/Application Support/Codex_Second", isDirectory: true)
        try FileManager.default.createDirectory(at: ownData, withIntermediateDirectories: true)
        try rig.adopt("found:.codex-work", "found:.codex_second")

        try rig.manager.open("standard")
        try rig.manager.open("alex@work.example.com")    // by email
        try rig.manager.open("found:.codex_second")
        let workData = rig.env.codexAppDataDir.appendingPathComponent(".codex-work")
        #expect(rig.control.launches == [
            .init(home: nil, appDataDir: nil),
            .init(home: work.path, appDataDir: workData.path),
            .init(home: second.path, appDataDir: ownData.path),   // keeps the app data its window already had
        ])
        #expect(exists(workData) && posixPermissions(workData) == 0o700)
        rig.table.add(pid: 777, path: rig.appExecutable, codexHome: work.path, appDataPath: workData.path)
        try rig.manager.open("found:.codex-work")
        #expect(rig.control.activated == [777])
        #expect(rig.control.launches.count == 3)
    }

    @Test func aWindowThatCantComeForwardNeverGetsASecondInstance() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.adopt("found:.codex-work")
        rig.table.add(pid: 780, path: rig.appExecutable, codexHome: work.path, appDataPath: "/d/work")
        rig.control.activateWorks = false
        #expect(switcherError { _ = try rig.manager.open("found:.codex-work") } == .codexCannotShow("alex@work.example.com"))
        #expect(rig.control.launches.isEmpty)
    }

    @Test func codexsStandardAppDataIsNeverUsedTwice() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        let second = try rig.makeHome(".codex_second", email: nil)
        // A window started by a hand-made launcher: its own CODEX_HOME but Codex's standard app data.
        rig.table.add(pid: 790, path: rig.appExecutable, codexHome: second.path)
        #expect(switcherError { _ = try rig.manager.open("standard") } == .codexDefaultDataInUse)
        #expect(rig.control.launches.isEmpty)
        rig.table.remove(pid: 790)
        rig.table.add(pid: 791, path: rig.appExecutable, codexHome: second.path, appDataPath: "/d/second")   // its own data
        try rig.manager.open("standard")
        #expect(rig.control.launches == [.init(home: nil, appDataDir: nil)])
    }

    @Test func openArgumentsMatchCodexsOwnSecondInstanceLaunch() {
        let app = URL(fileURLWithPath: "/Applications/Codex.app")
        #expect(SystemCodexAppControl.openArguments(appURL: app, home: nil, appDataDir: nil) == ["-n", "-a", app.path])
        #expect(SystemCodexAppControl.openArguments(appURL: app, home: URL(fileURLWithPath: "/h/.codex-work"),
                                                   appDataDir: URL(fileURLWithPath: "/d/work"))
            == ["-n", "--env", "CODEX_HOME=/h/.codex-work", "--env", "CODEX_ELECTRON_USER_DATA_PATH=/d/work",
                "-a", app.path, "--args", "--user-data-dir=/d/work"])
        let environment = SystemCodexAppControl.environment(home: URL(fileURLWithPath: "/h/.codex-work"))
        #expect(environment["CODEX_HOME"] == "/h/.codex-work")
        #expect(SystemCodexAppControl.environment(home: nil)["CODEX_HOME"] == nil)
    }

    @Test func addingAnAccountSignsInThroughCodex() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let links = Counter()
        rig.control.login = { home, output, _ in
            output("Starting local login server on http://localhost:1455")
            output("If your browser did not open, navigate to this URL to authenticate: https://auth.openai.com/oauth/authorize?state=FAKE")
            try? CodexFixture.writeAuth(into: home, email: "new@example.com")
            return .exited(0)
        }
        let account = try rig.manager.addAccount(onLink: { link in
            if link.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize") { _ = links.next() }
        })
        #expect(account.kind == .managed && account.label == "new@example.com" && account.state == .signedIn)
        #expect(links.current == 1)
        let home = rig.env.codexManagedDir.appendingPathComponent(account.id).appendingPathComponent("home")
        #expect(String(decoding: fileData(home.appendingPathComponent("config.toml")) ?? Data(), as: UTF8.self)
            == "cli_auth_credentials_store = \"file\"\n")
        #expect(rig.control.cliRuns == [.init(arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""], home: home.path)])
        #expect(rig.control.launches.isEmpty)   // opening is a separate step
        try rig.manager.open(account.id)
        #expect(rig.control.launches == [.init(home: home.path, appDataDir: home.deletingLastPathComponent()
            .appendingPathComponent("app-data").path)])
    }

    @Test func anUnfinishedAddLeavesNothingBehindButASavedSignInIsKept() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        rig.control.login = { _, _, shouldStop in shouldStop() ? .stopped : .exited(1) }
        #expect(switcherError { _ = try rig.manager.addAccount(shouldStop: { true }) } == .codexSignInCancelled)
        #expect(switcherError { _ = try rig.manager.addAccount() } == .codexSignInFailed(L10n.t(.reasonCodexExitCode, 1)))
        rig.control.login = { _, _, _ in .timedOut }
        #expect(switcherError { _ = try rig.manager.addAccount() } == .codexSignInFailed(L10n.t(.reasonCodexTimedOut, 600)))
        rig.control.login = { _, _, _ in .failedToStart("no such file") }
        #expect(switcherError { _ = try rig.manager.addAccount() } == .codexSignInFailed(L10n.t(.reasonCodexNotStarted, "no such file")))
        #expect(rig.manager.status().accounts.map(\.id) == ["standard"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.env.codexManagedDir.path)) ?? []).isEmpty)

        // Codex wrote a sign-in but then reported a failure: the account stays (it can be removed).
        rig.control.login = { home, _, _ in try? CodexFixture.writeAuth(into: home, email: "half@example.com"); return .exited(2) }
        _ = switcherError { _ = try rig.manager.addAccount() }
        #expect(rig.manager.status().accounts.map(\.label).contains("half@example.com"))
        // Codex reported success without a sign-in file (e.g. it keeps it elsewhere): kept, shown as signed out.
        rig.control.login = { _, _, _ in .exited(0) }
        let kept = try rig.manager.addAccount()
        #expect(kept.state == .signedOut && kept.label == L10n.t(.codexNewAccount))
        #expect(rig.control.launches.isEmpty)
    }

    @Test func signingInAgainClosesTheWindowFirstAndReopensIt() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let work = try rig.makeHome(".codex-work", email: "old@example.com")
        try rig.adopt("found:.codex-work")
        rig.table.add(pid: 610, path: rig.appExecutable, codexHome: work.path, appDataPath: "/d/work")
        rig.control.login = { home, _, _ in
            try? CodexFixture.writeAuth(into: home, email: "again@example.com")
            return .exited(0)
        }
        let account = try rig.manager.reauthenticate("found:.codex-work")
        #expect(account.label == "again@example.com")
        #expect(rig.control.quitRequests == [610])
        #expect(rig.control.cliRuns == [.init(arguments: ["login"], home: work.path)])   // a found home keeps its own settings
        #expect(rig.control.launches.map(\.home) == [work.path])

        // A cancelled sign-in still reopens the window it closed.
        rig.table.add(pid: 611, path: rig.appExecutable, codexHome: work.path, appDataPath: "/d/work")
        rig.control.login = { _, _, _ in .stopped }
        #expect(switcherError { _ = try rig.manager.reauthenticate("found:.codex-work") } == .codexSignInCancelled)
        #expect(rig.control.launches.map(\.home) == [work.path, work.path])
    }

    @Test func aWindowThatWontCloseStopsTheSignIn() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let work = try rig.makeHome(".codex-work", email: "old@example.com")
        try rig.adopt("found:.codex-work")
        rig.table.add(pid: 620, path: rig.appExecutable, codexHome: work.path, appDataPath: "/d/work")
        rig.control.quitWorks = false
        #expect(switcherError { _ = try rig.manager.reauthenticate("found:.codex-work") } == .codexStillRunning("old@example.com"))
        #expect(rig.control.cliRuns.filter { $0.arguments.contains("logout") }.isEmpty)
    }

    @Test func removingFollowsWhoOwnsTheHome() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.adopt("found:.codex-work")
        #expect(switcherError { _ = try rig.manager.remove("standard") } == .codexCannotRemoveStandard)

        // Found: leaves the list (and the suggestions); the folder and its sign-in stay.
        let before = fileData(work.appendingPathComponent("auth.json"))
        try rig.manager.remove("found:.codex-work")
        let afterRemoval = rig.manager.status()
        #expect(!afterRemoval.accounts.contains { $0.id == "found:.codex-work" } && afterRemoval.found.isEmpty)
        #expect(afterRemoval.hiddenCount == 1)
        #expect(fileData(work.appendingPathComponent("auth.json")) == before)
        try rig.manager.unhideAll()
        #expect(rig.manager.status().found.map(\.id) == ["found:.codex-work"])

        // Added: window closed, helpers stopped, signed out, folder to the Trash, records cleaned.
        rig.control.login = { home, _, _ in try? CodexFixture.writeAuth(into: home, email: "side@example.com"); return .exited(0) }
        let added = try rig.manager.addAccount()
        try rig.manager.renameAccount(added.id, to: "Side")
        let folder = rig.env.codexManagedDir.appendingPathComponent(added.id, isDirectory: true)
        let home = folder.appendingPathComponent("home")
        rig.table.add(pid: 700, path: rig.appExecutable, codexHome: home.path, appDataPath: folder.appendingPathComponent("app-data").path)
        rig.table.add(pid: 701, path: home.appendingPathComponent("packages/app-server-daemon/bin/codex").path)
        rig.table.add(pid: 702, path: "/opt/fake/bin/codex", ppid: 99, codexHome: home.path)
        rig.table.add(pid: 703, path: "/opt/fake/bin/codex", ppid: 99, codexHome: work.path)   // another home: untouched
        try rig.manager.remove("Side")
        #expect(rig.control.quitRequests == [700])
        #expect(Set(rig.control.terminated) == [701, 702])
        #expect(rig.control.cliRuns.last == .init(arguments: ["logout"], home: home.path))
        #expect(rig.control.trashed == [folder])
        #expect(!exists(folder))
        #expect(!rig.manager.status().accounts.contains { $0.id == added.id })
        #expect(rig.manager.loadRegistry() == CodexRegistry(hidden: []))
    }

    @Test func aLiveSignInNeverGoesToTheTrash() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        rig.control.login = { home, _, _ in try? CodexFixture.writeAuth(into: home, email: "side@example.com"); return .exited(0) }
        let added = try rig.manager.addAccount()
        rig.control.logoutWorks = false
        try rig.manager.remove(added.id)
        let trashed = try #require(try FileManager.default.contentsOfDirectory(at: rig.control.trashDir, includingPropertiesForKeys: nil).first)
        #expect(!exists(trashed.appendingPathComponent("home/auth.json")))
        #expect(exists(trashed.appendingPathComponent("home/config.toml")))
    }

    @Test func codexNamesFollowTheSameRules() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.adopt("found:.codex-work")
        let work = try rig.manager.renameAccount("found:.codex-work", to: "  Work  ")
        #expect(work.label == "Work" && work.customName == "Work")
        #expect(try rig.manager.resolve("WORK").id == "found:.codex-work")
        #expect(switcherError { _ = try rig.manager.renameAccount("standard", to: "work") } == .duplicateAccountName("work"))
        #expect(switcherError { _ = try rig.manager.renameAccount("standard", to: "alex@work.example.com") }
            == .duplicateAccountName("alex@work.example.com"))
        // Another account's id would make lookups ambiguous.
        #expect(switcherError { _ = try rig.manager.renameAccount("found:.codex-work", to: "standard") } == .duplicateAccountName("standard"))
        #expect(try rig.manager.renameAccount("found:.codex-work", to: nil).label == "alex@work.example.com")
        #expect(switcherError { _ = try rig.manager.resolve("nobody") } == .unknownAccount("nobody"))
    }

    @Test func oneEmailInTwoHomesGetsTwoNames() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "same@example.com")
        try rig.makeHome(".codex-work", email: "same@example.com")
        try rig.adopt("found:.codex-work")
        let labels = rig.manager.status().accounts.map(\.label)
        #expect(labels == ["same@example.com · .codex", "same@example.com · .codex-work"])
        #expect(switcherError { _ = try rig.manager.resolve("same@example.com") } == .ambiguousAccount("same@example.com"))
    }

    @Test func withoutCodexNothingIsLaunched() throws {
        let rig = try CodexRig(installed: false); defer { rig.cleanup() }
        try rig.makeHome(".codex", email: "alex@example.com")
        #expect(!rig.manager.status().installed)
        #expect(switcherError { _ = try rig.manager.open("standard") } == .codexNotInstalled)
        #expect(switcherError { _ = try rig.manager.addAccount() } == .codexNotInstalled)
        #expect(rig.control.launches.isEmpty && rig.control.cliRuns.isEmpty)
    }

    @Test func removeChecksTheFolderBeforeAnythingIrreversible() throws {
        // A managed folder replaced by a symlink out of the store: remove fails before
        // windows close, sessions end, or anything reaches the trash (audit B-10).
        let rig = try CodexRig(); defer { rig.cleanup() }
        rig.control.login = { home, _, _ in
            try? CodexFixture.writeAuth(into: home, email: "new@example.com")
            return .exited(0)
        }
        let account = try rig.manager.addAccount()
        let folder = rig.env.codexManagedDir.appendingPathComponent(account.id, isDirectory: true)
        let outside = rig.sandbox.root.appendingPathComponent("outside-the-store", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: outside.path)
        #expect(switcherError { _ = try rig.manager.remove(account.id) } == .forbiddenWrite(folder.path))
        #expect(rig.control.cliRuns.filter { $0.arguments.contains("logout") }.isEmpty)
        #expect(rig.control.quitRequests.isEmpty)
        #expect(rig.control.trashed.isEmpty)
        #expect(fileData(outside.appendingPathComponent("keep.txt")) == Data("keep".utf8))
    }

    @Test func aHomeLinkedOutsideTheStoreIsNotLoggedOut() throws {
        // <id>/home pointing at another home: logout and every write must not run (audit B-10).
        let rig = try CodexRig(); defer { rig.cleanup() }
        rig.control.login = { home, _, _ in
            try? CodexFixture.writeAuth(into: home, email: "new@example.com")
            return .exited(0)
        }
        let account = try rig.manager.addAccount()
        let folder = rig.env.codexManagedDir.appendingPathComponent(account.id, isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let victim = try rig.makeHome(".codex", email: "alex@example.com")
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createSymbolicLink(atPath: home.path, withDestinationPath: victim.path)
        #expect(switcherError { _ = try rig.manager.remove(account.id) } == .forbiddenWrite(home.path))
        #expect(rig.control.cliRuns.filter { $0.arguments.contains("logout") }.isEmpty)
        #expect(rig.control.quitRequests.isEmpty)
        #expect(rig.control.trashed.isEmpty)
        #expect(fileData(victim.appendingPathComponent("auth.json")) != nil)
    }

    @Test func anUnreadableRegistryIsReportedInStatus() throws {
        // A registry that can't be decoded flags status and surfaces no found homes, so
        // homes the user hid don't reappear (audit B-10).
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.sandbox.write("{broken", to: rig.env.codexRegistryFile)
        let status = rig.manager.status()
        #expect(status.registryUnreadable)
        #expect(status.found.isEmpty)
    }

    @Test func anUnreadableRecordIsNeverOverwritten() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        try rig.makeHome(".codex-work", email: "alex@work.example.com")
        try rig.sandbox.write("{broken", to: rig.env.codexRegistryFile)
        guard case .io = switcherError({ _ = try rig.manager.adopt("found:.codex-work") }) else { Issue.record("expected io"); return }
        #expect(fileData(rig.env.codexRegistryFile) == Data("{broken".utf8))
    }

    @Test func handEditedIdsAreIgnored() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let snapshots = rig.env.snapshotsDir
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try rig.sandbox.write("""
            {"managed": ["x/../../snapshots", "M-ABCDEF12", "m-1234567"], "adopted": ["found:../evil", "found:.codex-work/../x"],
             "hidden": [], "names": {}}
            """, to: rig.env.codexRegistryFile)
        let status = rig.manager.status()
        #expect(status.accounts.map(\.id) == ["standard"])
        #expect(switcherError { _ = try rig.manager.remove("x/../../snapshots") } == .unknownAccount("x/../../snapshots"))
        #expect(exists(snapshots) && rig.control.trashed.isEmpty)
        #expect(CodexRegistry.isManagedID("m-0a1b2c3d") && !CodexRegistry.isManagedID("m-0A1B2C3D"))
    }

    @Test func addingFoundHomesWorksForHiddenOnesPathsAndWarnsAboutCopies() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let standard = try rig.makeHome(".codex", email: "alex@example.com")
        let backup = try rig.makeHome(".codex-backup", email: "alex@example.com")   // a copy of the standard home?
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")
        _ = standard
        // A copy of a listed home never shows exactly the same name.
        let names = Dictionary(uniqueKeysWithValues: (rig.manager.status().accounts + rig.manager.status().found).map { ($0.id, $0.label) })
        #expect(names["standard"] == "alex@example.com · .codex" && names["found:.codex-backup"] == "alex@example.com · .codex-backup")
        #expect(try rig.manager.listedAccount(sameAs: ".codex-backup")?.id == "standard")
        #expect(try rig.manager.listedAccount(sameAs: ".codex-work") == nil)

        try rig.manager.dismiss(".codex-work")
        #expect(rig.manager.status().found.map(\.id) == ["found:.codex-backup"])
        try rig.manager.adopt(work.path)          // a hidden home, by its full path
        #expect(rig.manager.status().accounts.map(\.id) == ["standard", "found:.codex-work"])
        #expect(rig.manager.status().hiddenCount == 0)
        _ = backup
    }

    @Test func anAddedHomeStaysListedWhenSignedOut() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let work = try rig.makeHome(".codex-work", email: "alex@work.example.com")   // auth.json only, no config.toml
        try rig.adopt("found:.codex-work")
        try FileManager.default.removeItem(at: work.appendingPathComponent("auth.json"))   // `codex logout`
        let row = try #require(rig.manager.status().accounts.first { $0.id == "found:.codex-work" })
        #expect(row.state == .signedOut)
        rig.control.login = { home, _, _ in try? CodexFixture.writeAuth(into: home, email: "back@example.com"); return .exited(0) }
        #expect(try rig.manager.reauthenticate("found:.codex-work").label == "back@example.com")
    }

    @Test func dashAndUnderscoreHomesNeverShareAppData() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        let support = rig.env.home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Codex_Work"), withIntermediateDirectories: true)
        #expect(rig.manager.appDataDir(forFound: ".codex_work").lastPathComponent == "Codex_Work")
        #expect(rig.manager.appDataDir(forFound: ".codex-work").path == rig.env.codexAppDataDir.appendingPathComponent(".codex-work").path)
    }

    @Test func helpersAreForceQuitOnlyWhileTheyAreStillTheSameProcess() throws {
        let rig = try CodexRig(); defer { rig.cleanup() }
        var options = CodexManager.Options()
        options.helperExitTimeout = 0.1
        options.pollInterval = 0.02
        let manager = CodexManager(env: rig.env, table: rig.table, control: rig.control, options: options)
        let home = rig.env.codexManagedDir.appendingPathComponent("m-0a1b2c3d/home", isDirectory: true)
        rig.control.terminateWorks = false   // they ignore SIGTERM
        rig.table.add(pid: 810, path: "/opt/fake/bin/codex", ppid: 99, codexHome: home.path)
        rig.table.add(pid: 811, path: "/opt/fake/bin/codex", ppid: 99, codexHome: home.path)
        rig.table.reuse(pid: 811, path: "/usr/bin/other")   // 811 ended; the pid now belongs to something else
        manager.stopHelpers(using: home)
        #expect(rig.control.terminated == [810])
        #expect(rig.control.forceKilled == [810])
        manager.stopRunningCommands()
        #expect(rig.control.stopAllCalls == 1)
    }

    @Test func homeNamesAndSignInLinks() {
        #expect(CodexManager.isCodexHomeName(".codex-work") && CodexManager.isCodexHomeName(".codex_second"))
        #expect(!CodexManager.isCodexHomeName(".codex") && !CodexManager.isCodexHomeName(".codexfoo")
            && !CodexManager.isCodexHomeName(".codex-"))
        #expect(CodexManager.signInLink(in: "navigate to this URL: https://auth.openai.com/oauth/authorize?x=1 now")?.absoluteString
            == "https://auth.openai.com/oauth/authorize?x=1")
        #expect(CodexManager.signInLink(in: "Starting local login server on http://localhost:1455") == nil)
    }
}

/// The real process runner, with small shell scripts standing in for Codex's command-line tool.
@Suite("Codex command runner")
struct CodexCommandRunnerTests {
    static func script(_ body: String, in sandbox: Sandbox) throws -> URL {
        let url = try sandbox.scratch("bin").appendingPathComponent("fake-codex-\(UUID().uuidString.prefix(6))")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        _ = chmod(url.path, 0o755)
        return url
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    @Test func exitCodesOutputLinesAndTheHomeComeThrough() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let cli = try Self.script("""
            echo "home=$CODEX_HOME"
            printf 'If your browser did not open: https://auth.openai.com/oauth/authorize?x=1\\npartial'
            exit 3
            """, in: sb)
        let lines = Lines()
        let outcome = SystemCodexAppControl().runCLI(cli, arguments: ["login"], home: URL(fileURLWithPath: "/tmp/h"),
                                                     timeout: 10, shouldStop: { false }, onOutput: lines.add)
        #expect(outcome == .exited(3))
        #expect(lines.all.first == "home=/tmp/h")
        #expect(lines.all.contains { CodexManager.signInLink(in: $0)?.absoluteString == "https://auth.openai.com/oauth/authorize?x=1" })
    }

    @Test func stoppingAndTimingOutEndTheProcess() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let cli = try Self.script("sleep 30", in: sb)
        let started = Date()
        #expect(SystemCodexAppControl().runCLI(cli, arguments: [], home: URL(fileURLWithPath: "/tmp/h"), timeout: 10,
                                               shouldStop: { Date().timeIntervalSince(started) > 0.3 }, onOutput: { _ in }) == .stopped)
        #expect(SystemCodexAppControl().runCLI(cli, arguments: [], home: URL(fileURLWithPath: "/tmp/h"), timeout: 0.3,
                                               shouldStop: { false }, onOutput: { _ in }) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        // A child that ignores SIGTERM is killed after the grace period.
        let stubborn = try Self.script("trap '' TERM; sleep 30", in: sb)
        #expect(SystemCodexAppControl().runCLI(stubborn, arguments: [], home: URL(fileURLWithPath: "/tmp/h"), timeout: 0.2,
                                               shouldStop: { false }, onOutput: { _ in }) == .timedOut)
    }

    @Test func aMissingToolIsReportedAsNotStarted() {
        let outcome = SystemCodexAppControl().runCLI(URL(fileURLWithPath: "/nonexistent/codex"), arguments: [],
                                                     home: URL(fileURLWithPath: "/tmp/h"), timeout: 1,
                                                     shouldStop: { false }, onOutput: { _ in })
        guard case .failedToStart = outcome else { Issue.record("expected failedToStart, got \(outcome)"); return }
    }

    @Test func linesAreSplitAcrossChunks() {
        let lines = Lines()
        let splitter = LineSplitter(lines.add)
        splitter.append(Data("ab".utf8))
        splitter.append(Data("c\nde\n\nf".utf8))
        #expect(lines.all == ["abc", "de", ""])
    }
}
