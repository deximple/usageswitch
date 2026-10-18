import Darwin
import Foundation

/// The Codex tab. Every Codex account has its own Codex home and opens in its own Codex instance with its own app data,
/// the way Codex itself opens a second instance; accounts are never swapped and their sign-ins are never copied (Codex
/// rotates single-use refresh tokens, so a stale copy stops working). Signing in and out always goes through Codex's
/// own command-line tool.
public final class CodexManager: @unchecked Sendable {
    public struct Options: Sendable {
        public var signInTimeout: TimeInterval = 600
        public var quitTimeout: TimeInterval = 60
        public var helperExitTimeout: TimeInterval = 5
        public var pollInterval: TimeInterval = 0.25
        public init() {}
    }

    /// A main Codex app process and the home and app data it was started with.
    struct Window: Equatable {
        let pid: Int32
        /// Normalized CODEX_HOME (the standard home when unset).
        let home: String
        /// CODEX_ELECTRON_USER_DATA_PATH; nil means Codex's standard app data.
        let appData: String?
    }

    public let env: SwitcherEnvironment
    let fs: SafeFS
    let table: ProcessTable
    let control: CodexAppControl
    let options: Options

    public init(env: SwitcherEnvironment = .live(), table: ProcessTable = SystemProcessTable(),
                control: CodexAppControl = SystemCodexAppControl(), options: Options = Options()) {
        self.env = env
        fs = SafeFS(env: env)
        self.table = table
        self.control = control
        self.options = options
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: env.codexAppURL.path) }

    // MARK: - Listing

    public func status() -> CodexStatus {
        let registry = loadRegistry() ?? CodexRegistry()
        let listedProfiles = listedProfiles(registry)
        // Named together, so a found copy of a listed home never shows exactly the same name.
        let all = rows(listedProfiles + foundProfiles(registry), registry: registry, windows: windows())
        let hidden = registry.hidden.filter { Self.looksLikeCodexHome(home(ofFound: $0)) }.count
        return CodexStatus(installed: isInstalled, version: control.bundleVersion(appURL: env.codexAppURL),
                           accounts: Array(all.prefix(listedProfiles.count)), found: Array(all.dropFirst(listedProfiles.count)),
                           hiddenCount: hidden)
    }

    /// Ends any `codex login` still running (the app is quitting).
    public func stopRunningCommands() { control.stopAllCommands(grace: 1.5) }

    /// A listed account by id, or by a name it answers to (shown name, default name or email; case is ignored).
    public func resolve(_ query: String) throws -> CodexAccount {
        try Self.pick(query, from: status().accounts)
    }

    // MARK: - Actions

    /// Brings the account's Codex window forward, or starts one.
    @discardableResult
    public func open(_ query: String) throws -> CodexAccount {
        guard isInstalled else { throw SwitcherError.codexNotInstalled }
        let account = try resolve(query)
        if !account.pids.isEmpty {
            // Never start a second instance on the same home and app data: if it can't be brought forward, say so.
            guard account.pids.contains(where: control.activate) else { throw SwitcherError.codexCannotShow(account.label) }
            return account
        }
        let profile = try profile(account.id)
        if profile.kind == .standard {
            // Codex's standard app data can be used by one instance only (another window started without its own
            // app data, e.g. by a hand-made launcher, already uses it).
            guard !windows().contains(where: { $0.appData == nil }) else { throw SwitcherError.codexDefaultDataInUse }
            try control.launch(appURL: env.codexAppURL, home: nil, appDataDir: nil)
        } else {
            guard let appData = profile.appDataDir else { throw SwitcherError.unknownAccount(account.id) }
            if fs.isAllowed(appData) { try fs.createDirectory(appData) }
            try control.launch(appURL: env.codexAppURL, home: profile.home, appDataDir: appData)
        }
        return account
    }

    /// Creates a new Codex home and signs it in through the browser (Codex's own `codex login`). The new account is
    /// kept once Codex reports a successful sign-in, or whenever Codex already saved a sign-in file; otherwise
    /// nothing is left behind. Open it afterwards.
    @discardableResult
    public func addAccount(shouldStop: @escaping @Sendable () -> Bool = { false },
                           onLink: @escaping @Sendable (URL) -> Void = { _ in }) throws -> CodexAccount {
        guard isInstalled else { throw SwitcherError.codexNotInstalled }
        let id = "m-" + UUID().uuidString.prefix(8).lowercased()
        let folder = env.codexManagedDir.appendingPathComponent(id, isDirectory: true)
        let home = folder.appendingPathComponent("home", isDirectory: true)
        try fs.createDirectory(home)
        try fs.createDirectory(folder.appendingPathComponent("app-data", isDirectory: true))
        // Keep this home's sign-in in its own file (never in a keychain item shared between homes).
        try fs.write(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: home.appendingPathComponent("config.toml"))
        do {
            try updateRegistry { $0.managed.append(id) }
            return try signIn(id, shouldStop: shouldStop, onLink: onLink)
        } catch {
            // A sign-in file means Codex did save something: keep the account (it can be removed) rather than lose it.
            if !FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) {
                try? updateRegistry { $0.managed.removeAll { $0 == id } }
                try? fs.remove(folder)
            }
            throw error
        }
    }

    /// Signs the account in again through the browser. Its Codex window closes first (so it can't keep using the old
    /// sign-in) and opens again afterwards, also when the sign-in doesn't finish.
    @discardableResult
    public func reauthenticate(_ query: String, shouldStop: @escaping @Sendable () -> Bool = { false },
                               onLink: @escaping @Sendable (URL) -> Void = { _ in }) throws -> CodexAccount {
        guard isInstalled else { throw SwitcherError.codexNotInstalled }
        let account = try resolve(query)
        let wasOpen = !account.pids.isEmpty
        try quitWindows(of: account)
        let signedIn: CodexAccount
        do {
            signedIn = try signIn(account.id, shouldStop: shouldStop, onLink: onLink)
        } catch {
            if wasOpen { _ = try? open(account.id) }
            throw error
        }
        if wasOpen { try open(account.id) }
        return signedIn
    }

    /// Adds a Codex home found on this Mac (also a hidden one) to the list; only then can it be opened or signed in to.
    @discardableResult
    public func adopt(_ query: String) throws -> CodexAccount {
        let found = try pickFound(query, includeHidden: true)
        try updateRegistry {
            if !$0.adopted.contains(found.id) { $0.adopted.append(found.id) }
            $0.hidden.removeAll { $0 == found.id }
        }
        return try resolve(found.id)
    }

    /// A listed account with the same email as a found home, if any (the found folder may be a copy of it).
    public func listedAccount(sameAs query: String) throws -> CodexAccount? {
        let found = try pickFound(query, includeHidden: true)
        guard let email = found.email else { return nil }
        return status().accounts.first { $0.email == email }
    }

    /// Stops suggesting a found home (it can be shown again with `unhideAll`).
    public func dismiss(_ query: String) throws {
        let found = try pickFound(query, includeHidden: false)
        try updateRegistry { if !$0.hidden.contains(found.id) { $0.hidden.append(found.id) } }
    }

    /// A found home by id, folder name, full path or a name it answers to.
    func pickFound(_ query: String, includeHidden: Bool) throws -> CodexAccount {
        var registry = loadRegistry() ?? CodexRegistry()
        if includeHidden { registry.hidden = [] }
        let found = rows(foundProfiles(registry), registry: CodexRegistry(), windows: windows())
        let path = SafeFS.normalized(URL(fileURLWithPath: (query as NSString).expandingTildeInPath, isDirectory: true))
        if let byPath = found.first(where: { SafeFS.normalized(URL(fileURLWithPath: $0.home, isDirectory: true)) == path }) {
            return byPath
        }
        return try Self.pick(query, from: found, folderNames: true)
    }

    /// The standard home can't be removed. An added found home only leaves the list (its folder and sign-in stay).
    /// A home this app created is signed out and its folder goes to the Trash; its windows and the Codex processes
    /// working in it close first.
    @discardableResult
    public func remove(_ query: String) throws -> CodexAccount {
        let account = try resolve(query)
        let profile = try profile(account.id)
        switch profile.kind {
        case .standard:
            throw SwitcherError.codexCannotRemoveStandard
        case .found:
            try updateRegistry {
                $0.adopted.removeAll { $0 == account.id }
                if !$0.hidden.contains(account.id) { $0.hidden.append(account.id) }
                $0.names[account.id] = nil
            }
        case .managed:
            try quitWindows(of: account)
            stopHelpers(using: profile.home)
            if FileManager.default.fileExists(atPath: env.codexCLI.path) {
                _ = control.runCLI(env.codexCLI, arguments: ["logout"], home: profile.home, timeout: 30,
                                   shouldStop: { false }, onOutput: { _ in })
            }
            // Never send a live sign-in to the Trash, even if `codex logout` didn't finish.
            let auth = profile.home.appendingPathComponent("auth.json")
            if FileManager.default.fileExists(atPath: auth.path) { try fs.remove(auth) }
            let folder = env.codexManagedDir.appendingPathComponent(account.id, isDirectory: true)
            try fs.check(folder)
            if FileManager.default.fileExists(atPath: folder.path) { try control.moveToTrash(folder) }
            try updateRegistry {
                $0.managed.removeAll { $0 == account.id }
                $0.names[account.id] = nil
            }
        }
        return account
    }

    /// Shows every hidden found home again.
    public func unhideAll() throws { try updateRegistry { $0.hidden = [] } }

    /// Same rules as Claude account names: one line, at most 40 characters, never another account's name, email or
    /// id; nil or blank goes back to the default name.
    @discardableResult
    public func renameAccount(_ query: String, to name: String?) throws -> CodexAccount {
        let account = try resolve(query)
        let newName = try AccountNames.validated(name)
        if let newName {
            let others = status().accounts.filter { $0.id != account.id }
            let taken = others.contains { $0.answers(to: newName) || SwitcherAccount.fold($0.id) == SwitcherAccount.fold(newName) }
            if taken { throw SwitcherError.duplicateAccountName(newName) }
        }
        try updateRegistry { $0.names[account.id] = newName }
        return try resolve(account.id)
    }

    // MARK: - Sign-in

    /// Runs `codex login` for the account's home and waits for it (the browser does the rest).
    func signIn(_ id: String, shouldStop: @escaping @Sendable () -> Bool,
                onLink: @escaping @Sendable (URL) -> Void) throws -> CodexAccount {
        guard FileManager.default.fileExists(atPath: env.codexCLI.path) else { throw SwitcherError.codexNotInstalled }
        let profile = try profile(id)
        var arguments = ["login"]
        if profile.kind == .managed { arguments += ["-c", "cli_auth_credentials_store=\"file\""] }
        let outcome = control.runCLI(env.codexCLI, arguments: arguments, home: profile.home, timeout: options.signInTimeout,
                                     shouldStop: shouldStop, onOutput: { line in
                                         if let link = Self.signInLink(in: line) { onLink(link) }
                                     })
        switch outcome {
        case .exited(0): return try resolve(id)   // a home that keeps sign-ins in the keychain may show no email
        case .exited(let status): throw SwitcherError.codexSignInFailed(L10n.t(.reasonCodexExitCode, Int(status)))
        case .stopped: throw SwitcherError.codexSignInCancelled
        case .timedOut: throw SwitcherError.codexSignInFailed(L10n.t(.reasonCodexTimedOut, Int(options.signInTimeout)))
        case .failedToStart(let reason): throw SwitcherError.codexSignInFailed(L10n.t(.reasonCodexNotStarted, reason))
        }
    }

    /// The sign-in page `codex login` prints in case the browser didn't open (kept in memory only).
    static func signInLink(in line: String) -> URL? {
        guard let range = line.range(of: #"https://auth\.openai\.com/\S+"#, options: .regularExpression) else { return nil }
        return URL(string: String(line[range]))
    }

    // MARK: - Processes

    /// Main Codex app processes (this user's, started by launchd) with the home and app data they were started with.
    func windows() -> [Window] {
        let executables = SafeFS.normalized(env.codexAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)) + "/"
        return table.all().filter { $0.ppid == 1 && $0.path.hasPrefix(executables) }.map { process in
            let values = table.environmentValues(pid: process.pid, keys: ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"])
            let home = values["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? env.codexStandardHome
            let appData = values["CODEX_ELECTRON_USER_DATA_PATH"]?.trimmingCharacters(in: .whitespaces)
            return Window(pid: process.pid, home: SafeFS.normalized(home), appData: appData?.isEmpty == false ? appData : nil)
        }
    }

    /// Codex's command-line and background processes working in a home (started from it or with it as CODEX_HOME).
    func helperProcesses(using home: URL) -> [ProcInfo] {
        let target = SafeFS.normalized(home)
        return table.all().filter { process in
            if process.path.hasPrefix(target + "/") { return true }
            guard process.comm == "codex" || process.path.hasSuffix("/codex") else { return false }
            let value = table.environmentValues(pid: process.pid, keys: ["CODEX_HOME"])["CODEX_HOME"]
            return value.map { SafeFS.normalized(URL(fileURLWithPath: $0, isDirectory: true)) } == target
        }
    }

    /// Ends the Codex processes working in one of this app's homes: SIGTERM, then SIGKILL for any still there after
    /// the grace period (they would otherwise recreate files in the folder being removed). A pid is only killed while
    /// it still belongs to the same process (same executable and start time).
    func stopHelpers(using home: URL) {
        let helpers = helperProcesses(using: home)
        guard !helpers.isEmpty else { return }
        helpers.forEach { _ = control.signalTerminate(pid: $0.pid) }
        let deadline = Date().addingTimeInterval(options.helperExitTimeout)
        var remaining = helpers
        while true {
            let current = table.all()
            remaining = helpers.filter { helper in
                current.contains { $0.pid == helper.pid && $0.path == helper.path && $0.startTime == helper.startTime }
            }
            if remaining.isEmpty || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
        remaining.forEach { _ = control.forceKill(pid: $0.pid) }
    }

    /// Asks the account's Codex windows to quit and waits for them.
    func quitWindows(of account: CodexAccount) throws {
        guard !account.pids.isEmpty else { return }
        for pid in account.pids { _ = control.requestQuit(pid: pid) }
        let deadline = Date().addingTimeInterval(options.quitTimeout)
        while true {
            let alive = Set(table.all().map(\.pid))
            if !account.pids.contains(where: alive.contains) { return }
            if Date() >= deadline { throw SwitcherError.codexStillRunning(account.label) }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    // MARK: - Homes

    /// The standard home, the found homes the user added, and the homes this app created.
    func listedProfiles(_ registry: CodexRegistry) -> [CodexProfile] {
        var profiles = [CodexProfile(id: "standard", kind: .standard, home: env.codexStandardHome, appDataDir: nil)]
        for id in registry.adopted.sorted() {
            let home = home(ofFound: id)
            // An added home stays listed while its folder exists (signed out it may hold no files we recognize).
            guard Self.isDirectory(home) else { continue }
            profiles.append(CodexProfile(id: id, kind: .found, home: home, appDataDir: appDataDir(forFound: home.lastPathComponent)))
        }
        for id in registry.managed {
            let folder = env.codexManagedDir.appendingPathComponent(id, isDirectory: true)
            profiles.append(CodexProfile(id: id, kind: .managed, home: folder.appendingPathComponent("home", isDirectory: true),
                                         appDataDir: folder.appendingPathComponent("app-data", isDirectory: true)))
        }
        return profiles
    }

    /// Codex homes in the home folder that are neither added nor hidden.
    func foundProfiles(_ registry: CodexRegistry) -> [CodexProfile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: env.home.path)) ?? []
        return names.sorted().compactMap { name -> CodexProfile? in
            let id = "found:" + name
            let home = env.home.appendingPathComponent(name, isDirectory: true)
            guard Self.isCodexHomeName(name), !registry.adopted.contains(id), !registry.hidden.contains(id),
                  Self.looksLikeCodexHome(home) else { return nil }
            return CodexProfile(id: id, kind: .found, home: home, appDataDir: appDataDir(forFound: name))
        }
    }

    func rows(_ profiles: [CodexProfile], registry: CodexRegistry, windows: [Window]) -> [CodexAccount] {
        let base = profiles.map { profile -> (CodexProfile, CodexIdentity?, String, [Int32]) in
            let identity = CodexIdentity.read(home: profile.home)
            let home = SafeFS.normalized(profile.home)
            let pids = windows.filter { $0.home == home }.map(\.pid)
            return (profile, identity, defaultName(profile, identity), pids)
        }
        // A default name another row also shows (one email in two homes) gets its folder appended.
        let shown = base.map { SwitcherAccount.fold(registry.names[$0.0.id] ?? $0.2) }
        let counts = Dictionary(shown.map { ($0, 1) }, uniquingKeysWith: +)
        return base.enumerated().map { index, row -> CodexAccount in
            let (profile, identity, defaultName, pids) = row
            let custom = registry.names[profile.id]
            let label = custom ?? (counts[shown[index], default: 0] > 1 ? "\(defaultName) · \(folderName(profile))" : defaultName)
            let state: CodexAccount.State = !pids.isEmpty ? .running : identity == nil ? .signedOut : .signedIn
            return CodexAccount(id: profile.id, kind: profile.kind, label: label, customName: custom, defaultName: defaultName,
                                home: profile.home.path, homePath: displayPath(profile.home), identity: identity,
                                state: state, pids: pids)
        }
    }

    func profile(_ id: String) throws -> CodexProfile {
        guard let profile = listedProfiles(loadRegistry() ?? CodexRegistry()).first(where: { $0.id == id }) else {
            throw SwitcherError.unknownAccount(id)
        }
        return profile
    }

    func home(ofFound id: String) -> URL {
        env.home.appendingPathComponent(String(id.dropFirst("found:".count)), isDirectory: true)
    }

    static func pick(_ query: String, from accounts: [CodexAccount], folderNames: Bool = false) throws -> CodexAccount {
        if let exact = accounts.first(where: { $0.id == query }) { return exact }
        let matches = accounts.filter {
            $0.answers(to: query) || (folderNames && ("found:" + query == $0.id))
        }
        guard matches.count < 2 else { throw SwitcherError.ambiguousAccount(query) }
        guard let match = matches.first else { throw SwitcherError.unknownAccount(query) }
        return match
    }

    /// `.codex-work`, `.codex_second`: the usual names for a second Codex home.
    static func isCodexHomeName(_ name: String) -> Bool {
        guard name.hasPrefix(".codex"), name.count > ".codex-".count, !name.contains("/") else { return false }
        let separator = name[name.index(name.startIndex, offsetBy: ".codex".count)]
        return separator == "-" || separator == "_"
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func looksLikeCodexHome(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        return ["auth.json", "config.toml"].contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    /// A found home keeps the app data folder its window already had when it was opened by hand
    /// (`~/Library/Application Support/Codex_Second` for `.codex_second`, same separator); otherwise it gets its own in
    /// the store. `.codex-work` and `.codex_work` never share one.
    func appDataDir(forFound name: String) -> URL {
        let separator = String(name[name.index(name.startIndex, offsetBy: ".codex".count)])
        let suffix = String(name.dropFirst(".codex-".count))
        let support = env.home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidates = ["Codex" + separator + suffix.capitalized, "Codex" + separator + suffix]
        for candidate in candidates {
            let url = support.appendingPathComponent(candidate, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return env.codexAppDataDir.appendingPathComponent(name, isDirectory: true)
    }

    func defaultName(_ profile: CodexProfile, _ identity: CodexIdentity?) -> String {
        if let email = identity?.email { return email }
        if identity?.mode == .apiKey { return L10n.t(.codexApiKeyName, folderName(profile)) }
        return profile.kind == .managed ? L10n.t(.codexNewAccount) : displayPath(profile.home)
    }

    func folderName(_ profile: CodexProfile) -> String {
        profile.kind == .managed ? profile.id : profile.home.lastPathComponent
    }

    func displayPath(_ url: URL) -> String {
        let home = env.home.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: - Records

    /// nil when the file exists but can't be read. Ids this app couldn't have written are dropped.
    func loadRegistry() -> CodexRegistry? {
        LockedStoreFile.load(env.codexRegistryFile, as: CodexRegistry.self, empty: CodexRegistry())?.sanitized
    }

    func updateRegistry(_ change: (inout CodexRegistry) throws -> Void) throws {
        try LockedStoreFile.update(env.codexRegistryFile, lock: env.codexRegistryLockFile, env: env, fs: fs,
                                   empty: CodexRegistry(), isEmpty: { $0.isEmpty }) { registry in
            registry = registry.sanitized
            try change(&registry)
        }
    }
}
