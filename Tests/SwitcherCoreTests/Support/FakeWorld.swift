import Foundation
import SQLite3
@testable import SwitcherCore

/// A simulated Mac for Switcher integration tests: process table, Claude.app, launchd and a virtual clock.
/// `sleep` advances virtual time instantly and fires scheduled events; nothing real is launched or signalled.
final class FakeWorld: ProcessTable, ClaudeAppControl, CommandRunner, Clock, @unchecked Sendable {
    enum QuitMode: Equatable {
        /// beforeQuit → cleanup → exit after `quitDuration`.
        case normal
        /// Claude shows "still working"; optionally the user confirms after N seconds.
        case veto(allowAfter: TimeInterval?)
        /// terminate() is ignored; SIGTERM quits only when `sigtermQuits`.
        case ignore
        /// Process tree vanishes without the clean-quit log line.
        case unclean
    }

    struct Agent { var plistPath: String; var loaded: Bool }

    struct State {
        var now: Date
        var procs: [ProcInfo] = []
        var procEnv: [pid_t: [String: String]] = [:]
        var nextPID: pid_t = 5000
        var events: [(at: Date, id: Int, action: (inout State, Date) -> Void)] = []
        var nextEventID = 0

        var quitMode: QuitMode = .normal
        var quitDuration: TimeInterval = 2
        /// The line Claude logs once its quit cleanup finished (Claude's own spelling by default).
        var cleanQuitText = LogFixture.cleanQuit
        var sigtermQuits = false
        /// What `signalTerminate` (kill(2)) reports; the signal is counted either way.
        var sigtermResult = true
        var launchInitDelay: TimeInterval = 2
        var launchLogsNothing = false
        var launchError: SwitcherError?
        /// Environment variable names a relaunched Claude main process starts with (values never modelled).
        var launchEnvNames: Set<String> = FakeWorld.dockLaunchEnvNames
        /// Parent of a relaunched Claude main process (1 = launchd, as for a Dock/`open` launch).
        var launchParentPID: pid_t = 1
        /// One-shot hook run after the next successful `launch` (e.g. to clear a fault for the rollback relaunch).
        var afterLaunch: ((inout State) -> Void)?
        var procEnvNames: [pid_t: Set<String>] = [:]
        var bundleVersion: String? = "1.0.0"
        var shipItRunning = false
        /// When an update is staged, quitting Claude makes "ShipIt" run for this long, then installs it.
        var shipItInstallDuration: TimeInterval = 3
        /// One-shot: when the next clean quit completes, ShipIt runs for `duration` (and optionally relaunches Claude).
        var shipItAfterNextQuit: (duration: TimeInterval, relaunchesClaude: Bool)?
        var shipItStoppedAt: Date?
        var codeSessionOnLaunch = false
        var codeSessionOnOpen = false
        var spawnClaudeWhenJournalApplied: Int?
        /// Runs once (with the journal's applied count reached) the next time the process table is read.
        var whenJournalApplied: (count: Int, action: (SwitcherEnvironment) -> Void)?
        /// Processes that survive their parent's exit (re-parented to launchd), e.g. a stuck MCP server.
        var immortal: Set<pid_t> = []
        var keepaliveInterval: TimeInterval = 30
        var lastKeepaliveTick: Date
        var agents: [String: Agent] = [:]
        var bootoutFails: Set<String> = []
        var bootstrapFails: Set<String> = []
        var freeGB = 100

        var commands: [[String]] = []
        var quitRequests = 0
        var sigterms = 0
        var launches = 0
        var opened: [URL] = []
        var journalHadLabelAtBootout: [String: Bool] = [:]
        var claudeStartedDuringSwap = false
        /// Process-table reads fail (return nil) while set — models sysctl returning nothing (audit P3).
        var tableUnreadable = false
        /// Claude reappears on the first table read after a new generation or backup dir
        /// exists — models a relaunch while a capture or backup was being copied (audit P3).
        var spawnClaudeWhenCopyingFiles = false
        var copyCountBaseline: Int?
    }

    static let dockLaunchEnvNames: Set<String> = ["HOME", "USER", "PATH"]

    let env: SwitcherEnvironment
    private let lock = NSLock()
    private var state: State

    init(env: SwitcherEnvironment, now: Date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))) {
        self.env = env
        state = State(now: now, lastKeepaliveTick: now)
    }

    func update(_ body: (inout State) -> Void) { lock.lock(); body(&state); lock.unlock() }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }

    // MARK: Scenario helpers

    /// Starts a Claude main process (and helpers) as if it had been running for an hour.
    @discardableResult
    func startClaude(codeSession: FakeIdentity? = nil, startedAgo: TimeInterval = 3600) -> pid_t {
        lock.lock(); defer { lock.unlock() }
        let main = Self.spawnTree(&state, env: env, at: state.now.addingTimeInterval(-startedAgo))
        if let codeSession { Self.spawnCodeSession(&state, env: env, main: main, identity: codeSession) }
        Self.spawnUnrelated(&state)
        return main
    }

    /// An MCP server under the current main process that keeps running after Claude exits.
    @discardableResult
    func spawnLingeringMCP() -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        guard let main = state.procs.first(where: { $0.path == env.claudeMainExecutable.path }) else { return nil }
        let pid = Self.add(&state, ppid: main.pid, comm: "node", path: "/opt/fake/bin/node", at: state.now)
        state.immortal.insert(pid)
        return pid
    }

    var mainPID: pid_t? { read { s in s.procs.first { $0.path == env.claudeMainExecutable.path }?.pid } }
    var mainStart: Date? { read { s in s.procs.first { $0.path == env.claudeMainExecutable.path }?.startTime } }

    func addAgent(label: String, plist: URL, loaded: Bool = true) {
        update { $0.agents[label] = Agent(plistPath: plist.path, loaded: loaded) }
    }

    func isAgentLoaded(_ label: String) -> Bool { read { $0.agents[label]?.loaded ?? false } }

    func logText() -> String { String(decoding: fileData(env.mainLog) ?? Data(), as: UTF8.self) }

    // MARK: Clock

    func now() -> Date { read { $0.now } }

    /// `now` only ever moves forward (sleep advances it), so it is monotonic in this world.
    func uptime() -> TimeInterval { read { $0.now.timeIntervalSince1970 } }

    func sleep(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let target = state.now.addingTimeInterval(max(seconds, 0))
        while let next = state.events.filter({ $0.at <= target }).min(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            state.events.removeAll { $0.id == next.id }
            if next.at > state.now { state.now = next.at }
            next.action(&state, next.at)
        }
        state.now = target
        Self.keepaliveTick(&state, env: env)
    }

    // MARK: ProcessTable

    func all() -> [ProcInfo]? {
        lock.lock(); defer { lock.unlock() }
        if state.tableUnreadable { return nil }
        if let n = state.spawnClaudeWhenJournalApplied, Self.journalApplied(env) >= n, !Self.claudeNamed(state) {
            state.spawnClaudeWhenJournalApplied = nil
            state.claudeStartedDuringSwap = true
            Self.spawnTree(&state, env: env, at: state.now)
            Self.appendLog(&state, env: env, at: state.now, LogFixture.startText)
        }
        if let hook = state.whenJournalApplied, Self.journalApplied(env) >= hook.count {
            state.whenJournalApplied = nil
            hook.action(env)
        }
        if state.spawnClaudeWhenCopyingFiles, !Self.claudeNamed(state) {
            let count = Self.copyArtifactCount(env)
            if let base = state.copyCountBaseline, count > base {
                state.spawnClaudeWhenCopyingFiles = false
                state.claudeStartedDuringSwap = true
                Self.spawnTree(&state, env: env, at: state.now)
                Self.appendLog(&state, env: env, at: state.now, LogFixture.startText)
            } else if state.copyCountBaseline == nil {
                state.copyCountBaseline = count
            }
        }
        return state.procs
    }

    func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] {
        read { s in (s.procEnv[pid] ?? [:]).filter { keys.contains($0.key) } }
    }

    func environmentNames(pid: pid_t) -> Set<String> {
        read { s in s.procEnvNames[pid] ?? Set((s.procEnv[pid] ?? [:]).keys) }
    }

    // MARK: ClaudeAppControl

    func requestQuit(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        state.quitRequests += 1
        guard state.procs.contains(where: { $0.pid == pid && $0.path == env.claudeMainExecutable.path }) else { return false }
        switch state.quitMode {
        case .normal:
            Self.beginQuit(&state, env: env, at: state.now)
        case .veto(let allowAfter):
            Self.appendLog(&state, env: env, at: state.now, LogFixture.veto)
            if let allowAfter {
                Self.schedule(&state, at: state.now.addingTimeInterval(allowAfter)) { s, t in Self.beginQuit(&s, env: self.env, at: t) }
            }
        case .ignore:
            break
        case .unclean:
            Self.killTree(&state, env: env, keepCrashpad: false)
        }
        return true
    }

    func signalTerminate(pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        state.sigterms += 1
        if state.sigtermQuits { Self.beginQuit(&state, env: env, at: state.now) }
        return state.sigtermResult
    }

    func launch(appURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        state.launches += 1
        if let e = state.launchError { throw e }
        guard appURL == env.claudeAppURL else { throw SwitcherError.launchFailed("unexpected app \(appURL.path)") }
        guard !state.procs.contains(where: { $0.path == env.claudeMainExecutable.path }) else { return }
        Self.relaunch(&state, env: env)
        if let hook = state.afterLaunch {
            state.afterLaunch = nil
            hook(&state)
        }
    }

    func open(url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        state.opened.append(url)
        guard state.codeSessionOnOpen,
              let main = state.procs.first(where: { $0.path == env.claudeMainExecutable.path }) else { return true }
        let identity = Self.liveIdentity(env)
        Self.schedule(&state, at: state.now.addingTimeInterval(3)) { s, _ in
            if let identity { Self.spawnCodeSession(&s, env: self.env, main: main.pid, identity: identity) }
        }
        return true
    }

    func bundleVersion(appURL: URL) -> String? { read { $0.bundleVersion } }

    // MARK: CommandRunner (launchctl only)

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        state.commands.append([executable] + arguments)
        guard executable == "/bin/launchctl", let verb = arguments.first else {
            return CommandResult(status: 127, output: "not simulated")
        }
        let domain = "gui/\(env.uid)"
        switch verb {
        case "print":
            guard arguments.count == 2, arguments[1].hasPrefix(domain + "/") else { return CommandResult(status: 64, output: "usage") }
            let label = String(arguments[1].dropFirst(domain.count + 1))
            if label == Switcher.shipItLabel {
                return state.shipItRunning
                    ? CommandResult(status: 0, output: "\(label) = {\n\tactive count = 1\n\tstate = running\n\tpid = 777\n}")
                    : CommandResult(status: 113, output: "Could not find service \"\(label)\" in domain for user gui: \(env.uid)")
            }
            guard state.agents[label]?.loaded == true else {
                return CommandResult(status: 113, output: "Could not find service \"\(label)\"")
            }
            return CommandResult(status: 0, output: "\(label) = {\n\tstate = not running\n}")
        case "bootout":
            guard arguments.count == 2, arguments[1].hasPrefix(domain + "/") else { return CommandResult(status: 64, output: "usage") }
            let label = String(arguments[1].dropFirst(domain.count + 1))
            let journal = (try? JSONDecoder().decode([Relauncher].self, from: fileData(env.relauncherJournalFile) ?? Data())) ?? []
            state.journalHadLabelAtBootout[label] = journal.contains { $0.label == label }
            guard state.agents[label]?.loaded == true else { return CommandResult(status: 3, output: "No such process") }
            if state.bootoutFails.contains(label) { return CommandResult(status: 5, output: "Boot-out failed: 5: Input/output error") }
            state.agents[label]?.loaded = false
            return CommandResult(status: 0, output: "")
        case "bootstrap":
            guard arguments.count == 3, arguments[1] == domain,
                  let label = state.agents.first(where: { $0.value.plistPath == arguments[2] })?.key else {
                return CommandResult(status: 5, output: "Bootstrap failed: 5: Input/output error")
            }
            if state.bootstrapFails.contains(label) { return CommandResult(status: 5, output: "Bootstrap failed: 5") }
            state.agents[label]?.loaded = true
            return CommandResult(status: 0, output: "")
        default:
            return CommandResult(status: 64, output: "unsupported")
        }
    }

    // MARK: - Simulation internals (called with the lock held)

    private static func schedule(_ s: inout State, at: Date, _ action: @escaping (inout State, Date) -> Void) {
        s.nextEventID += 1
        s.events.append((at: at, id: s.nextEventID, action: action))
    }

    private static func claudeNamed(_ s: State) -> Bool { s.procs.contains { $0.comm == "Claude" } }

    private static func newPID(_ s: inout State) -> pid_t { s.nextPID += 1; return s.nextPID }

    private static func add(_ s: inout State, ppid: pid_t, comm: String, path: String, at: Date,
                            env: [String: String] = [:]) -> pid_t {
        let pid = newPID(&s)
        s.procs.append(ProcInfo(pid: pid, ppid: ppid, pgid: ppid == 1 ? pid : ppid, comm: comm, path: path, startTime: at))
        if !env.isEmpty { s.procEnv[pid] = env }
        return pid
    }

    @discardableResult
    private static func spawnTree(_ s: inout State, env: SwitcherEnvironment, at: Date, ppid: pid_t = 1) -> pid_t {
        let app = env.claudeAppURL.path
        let main = add(&s, ppid: ppid, comm: "Claude", path: env.claudeMainExecutable.path, at: at)
        let fw = "\(app)/Contents/Frameworks"
        _ = add(&s, ppid: main, comm: "Claude Helper", path: "\(fw)/Claude Helper.app/Contents/MacOS/Claude Helper", at: at)
        _ = add(&s, ppid: main, comm: "Claude Helper (R",
                path: "\(fw)/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)", at: at)
        _ = add(&s, ppid: main, comm: "chrome_crashpad_",
                path: "\(fw)/Electron Framework.framework/Helpers/chrome_crashpad_handler", at: at)
        return main
    }

    private static func spawnCodeSession(_ s: inout State, env: SwitcherEnvironment, main: pid_t, identity: FakeIdentity) {
        let wrapper = add(&s, ppid: main, comm: "disclaimer", path: "\(env.claudeAppURL.path)/Contents/Helpers/disclaimer", at: s.now)
        _ = add(&s, ppid: wrapper, comm: "claude",
                path: env.claudeUserData.appendingPathComponent("claude-code/2.1.0/claude.app/Contents/MacOS/claude").path,
                at: s.now, env: [
                    "CLAUDE_CODE_ACCOUNT_UUID": identity.account, "CLAUDE_CODE_ORGANIZATION_UUID": identity.org,
                    "CLAUDE_CODE_USER_EMAIL": identity.email, "CLAUDE_CODE_OAUTH_TOKEN": "FAKE-OAUTH-TOKEN-0001",
                    "HOME": env.home.path,
                ])
    }

    /// Processes that must never block a quit: a terminal CLI and Chrome's native host.
    private static func spawnUnrelated(_ s: inout State) {
        let shell = add(&s, ppid: 1, comm: "zsh", path: "/bin/zsh", at: s.now.addingTimeInterval(-7200))
        _ = add(&s, ppid: shell, comm: "claude", path: "/opt/fake/bin/claude", at: s.now.addingTimeInterval(-7000),
                env: ["CLAUDE_CONFIG_DIR": "/fake/cli-config", "CLAUDE_CODE_ACCOUNT_UUID": FakeIdentity.d.account])
        let chrome = add(&s, ppid: 1, comm: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                         at: s.now.addingTimeInterval(-9000))
        _ = add(&s, ppid: chrome, comm: "chrome-native-h",
                path: "/Applications/Claude.app/Contents/Helpers/chrome-native-host", at: s.now.addingTimeInterval(-8000))
    }

    private static func killTree(_ s: inout State, env: SwitcherEnvironment, keepCrashpad: Bool) {
        guard let main = s.procs.first(where: { $0.path == env.claudeMainExecutable.path }) else { return }
        var doomed: Set<pid_t> = [main.pid]
        var changed = true
        while changed {
            changed = false
            for p in s.procs where doomed.contains(p.ppid) && !doomed.contains(p.pid) {
                doomed.insert(p.pid)
                changed = true
            }
        }
        doomed.subtract(s.immortal)
        s.procs = s.procs.map { p in
            s.immortal.contains(p.pid) && doomed.contains(p.ppid)
                ? ProcInfo(pid: p.pid, ppid: 1, pgid: p.pgid, comm: p.comm, path: p.path, startTime: p.startTime) : p
        }
        let crashpad = s.procs.filter { doomed.contains($0.pid) && $0.path.hasSuffix("/chrome_crashpad_handler") }
        s.procs.removeAll { doomed.contains($0.pid) && !(keepCrashpad && $0.path.hasSuffix("/chrome_crashpad_handler")) }
        if keepCrashpad, !crashpad.isEmpty {
            // Re-parented to launchd and gone shortly after.
            s.procs = s.procs.map { p in
                crashpad.contains(where: { $0.pid == p.pid })
                    ? ProcInfo(pid: p.pid, ppid: 1, pgid: p.pgid, comm: p.comm, path: p.path, startTime: p.startTime) : p
            }
            let pids = Set(crashpad.map(\.pid))
            schedule(&s, at: s.now.addingTimeInterval(1)) { st, _ in st.procs.removeAll { pids.contains($0.pid) } }
        }
        for pid in doomed { s.procEnv.removeValue(forKey: pid) }
    }

    private static func beginQuit(_ s: inout State, env: SwitcherEnvironment, at: Date) {
        appendLog(&s, env: env, at: at, LogFixture.quitHandler)
        appendLog(&s, env: env, at: at, LogFixture.quitCleanupStart)
        schedule(&s, at: at.addingTimeInterval(s.quitDuration)) { st, t in
            let cleanQuitText = st.cleanQuitText
            appendLog(&st, env: env, at: t, cleanQuitText)
            killTree(&st, env: env, keepCrashpad: true)
            installStagedUpdateIfAny(&st, env: env, at: t)
            runArmedShipIt(&st, env: env, at: t)
        }
    }

    private static func runArmedShipIt(_ s: inout State, env: SwitcherEnvironment, at: Date) {
        guard let armed = s.shipItAfterNextQuit else { return }
        s.shipItAfterNextQuit = nil
        s.shipItRunning = true
        schedule(&s, at: at.addingTimeInterval(armed.duration)) { st, t in
            st.shipItRunning = false
            st.shipItStoppedAt = t
            if armed.relaunchesClaude { relaunch(&st, env: env) }
        }
    }

    private static func installStagedUpdateIfAny(_ s: inout State, env: SwitcherEnvironment, at: Date) {
        // ShipIt only installs a staged payload that is newer than the installed bundle.
        guard let staged = (try? ClaudeConfig.load(env.claudeConfigJSON))?.stagedUpdateVersion,
              Switcher.isVersion(staged, newerThan: s.bundleVersion ?? "0") else { return }
        s.shipItRunning = true
        schedule(&s, at: at.addingTimeInterval(s.shipItInstallDuration)) { st, _ in
            st.bundleVersion = staged
            st.shipItRunning = false
        }
    }

    private static func relaunch(_ s: inout State, env: SwitcherEnvironment) {
        let main = spawnTree(&s, env: env, at: s.now, ppid: s.launchParentPID)
        s.procEnvNames[main] = s.launchEnvNames
        appendLog(&s, env: env, at: s.now, LogFixture.startText)
        guard !s.launchLogsNothing else { return }
        let identity = liveIdentity(env)
        let signedIn = liveHasSessionKey(env)
        let withCode = s.codeSessionOnLaunch
        schedule(&s, at: s.now.addingTimeInterval(s.launchInitDelay)) { st, t in
            guard let identity, signedIn else {
                appendLog(&st, env: env, at: t, "[LocalSessionManager] Cannot initialize sessions: User is logged out")
                return
            }
            appendLog(&st, env: env, at: t, LogFixture.agentInitLine(identity))
            appendLog(&st, env: env, at: t, LogFixture.initLine(identity))
            appendLog(&st, env: env, at: t, LogFixture.cacheKeyLine(identity))
            if withCode { spawnCodeSession(&st, env: env, main: main, identity: identity) }
        }
    }

    /// The keepalive LaunchAgent: relaunches Claude whenever it is loaded and Claude is not running.
    private static func keepaliveTick(_ s: inout State, env: SwitcherEnvironment) {
        guard s.now.timeIntervalSince(s.lastKeepaliveTick) >= s.keepaliveInterval else { return }
        s.lastKeepaliveTick = s.now
        guard s.agents[AgentFixture.keepaliveLabel]?.loaded == true, !claudeNamed(s) else { return }
        relaunch(&s, env: env)
    }

    private static func appendLog(_ s: inout State, env: SwitcherEnvironment, at: Date, _ text: String) {
        try? LogFixture.append(env.mainLog, LogFixture.line(at, text) + "\n")
    }

    /// Generations (finished or mid-copy) plus original backups — grows exactly when a
    /// capture or backup copies files, so a table read can notice "the copy ran" (audit P3).
    private static func copyArtifactCount(_ env: SwitcherEnvironment) -> Int {
        let fm = FileManager.default
        var count = ((try? fm.contentsOfDirectory(atPath: env.backupsDir.path)) ?? [])
            .filter { $0.hasPrefix("original-") || $0.hasPrefix(".partial-") }.count
        for identity in (try? fm.contentsOfDirectory(atPath: env.snapshotsDir.path)) ?? [] {
            count += ((try? fm.contentsOfDirectory(
                atPath: env.snapshotsDir.appendingPathComponent(identity).path)) ?? [])
                .filter { $0.hasPrefix("gen-") || $0.hasPrefix(".gen-") }.count
        }
        return count
    }

    private static func journalApplied(_ env: SwitcherEnvironment) -> Int {
        guard let data = fileData(env.journalFile),
              let j = try? JSONDecoder().decode(SwapEngine.Journal.self, from: data) else { return -1 }
        return j.applied.count
    }

    /// Which account the live cookie jar belongs to (fixture-only `fixture_identity` row).
    static func liveIdentity(_ env: SwitcherEnvironment) -> FakeIdentity? {
        guard exists(env.claudeCookies), let db = try? TestDB(env.claudeCookies, create: false, readOnly: true),
              let value = try? db.strings("SELECT value FROM cookies WHERE name = 'fixture_identity'").first else { return nil }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return nil }
        return [FakeIdentity.a, .b, .c, .d].first { $0.account == parts[0] && $0.org == parts[1] }
            ?? FakeIdentity(account: parts[0], org: parts[1], email: "unknown@example.com", name: "Unknown")
    }

    static func liveHasSessionKey(_ env: SwitcherEnvironment) -> Bool {
        guard exists(env.claudeCookies), let db = try? TestDB(env.claudeCookies, create: false, readOnly: true),
              let n = try? db.strings("SELECT count(*) FROM cookies WHERE host_key = '.claude.ai' AND name = 'sessionKey'").first
        else { return false }
        return n != "0"
    }
}
