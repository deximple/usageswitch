import AppKit
import Darwin
import Foundation

/// How a run of Codex's command-line tool ended.
public enum CodexCLIOutcome: Equatable, Sendable {
    case exited(Int32)
    /// `shouldStop` became true.
    case stopped
    case timedOut
    case failedToStart(String)
}

/// Everything the Codex tab does to the Codex app and its command-line tool goes through here, so tests never
/// touch the real Codex.
public protocol CodexAppControl: Sendable {
    /// Starts a new Codex instance: the standard home with Codex's usual app data (`home == nil`), any other home
    /// with its own app data folder.
    func launch(appURL: URL, home: URL?, appDataDir: URL?) throws
    func activate(pid: pid_t) -> Bool
    func requestQuit(pid: pid_t) -> Bool
    func signalTerminate(pid: pid_t) -> Bool
    /// Runs Codex's own command-line tool for one home. Output lines go to `onOutput` and are never stored.
    func runCLI(_ cli: URL, arguments: [String], home: URL, timeout: TimeInterval,
                shouldStop: @escaping @Sendable () -> Bool, onOutput: @escaping @Sendable (String) -> Void) -> CodexCLIOutcome
    func moveToTrash(_ url: URL) throws
    func bundleVersion(appURL: URL) -> String?
    /// SIGKILL for a helper that ignored SIGTERM.
    func forceKill(pid: pid_t) -> Bool
    /// Ends every command-line run still going (used when the app quits), waiting at most `grace` seconds.
    func stopAllCommands(grace: TimeInterval)
}

public struct SystemCodexAppControl: CodexAppControl {
    public init() {}

    /// Arguments for /usr/bin/open, the same way Codex itself opens a second instance: Codex takes its app data
    /// folder (and its single-instance lock) from CODEX_ELECTRON_USER_DATA_PATH, not from `--user-data-dir` alone,
    /// and only keeps the launch CODEX_HOME when that variable is set. Always a new instance (`-n`): we only launch
    /// when the account has no window, and `open -a` would otherwise just bring another account's window forward.
    public static func openArguments(appURL: URL, home: URL?, appDataDir: URL?) -> [String] {
        guard let home, let appDataDir else { return ["-n", "-a", appURL.path] }
        return ["-n", "--env", "CODEX_HOME=\(home.path)", "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(appDataDir.path)",
                "-a", appURL.path, "--args", "--user-data-dir=\(appDataDir.path)"]
    }

    /// A Dock-like environment plus, for one home, its CODEX_HOME: nothing else from this app's environment
    /// (for example a CODEX_HOME exported in the shell that started it) reaches Codex.
    static func environment(home: URL?) -> [String: String] {
        var environment = SystemClaudeAppControl.cleanEnvironment(from: ProcessInfo.processInfo.environment)
        if let home { environment["CODEX_HOME"] = home.path }
        return environment
    }

    public func launch(appURL: URL, home: URL?, appDataDir: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = Self.openArguments(appURL: appURL, home: home, appDataDir: appDataDir)
        process.environment = Self.environment(home: nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw SwitcherError.codexLaunchFailed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw SwitcherError.codexLaunchFailed(L10n.t(.reasonOpenTimeout)) }
        guard process.terminationStatus == 0 else {
            throw SwitcherError.codexLaunchFailed(L10n.t(.reasonOpenExitCode, Int(process.terminationStatus)))
        }
    }

    public func activate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    public func requestQuit(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    public func signalTerminate(pid: pid_t) -> Bool { kill(pid, SIGTERM) == 0 }

    public func runCLI(_ cli: URL, arguments: [String], home: URL, timeout: TimeInterval,
                       shouldStop: @escaping @Sendable () -> Bool, onOutput: @escaping @Sendable (String) -> Void) -> CodexCLIOutcome {
        let pipe = Pipe()
        let lines = LineSplitter(onOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF is terminal: without this the handler keeps firing on the closed pipe.
            if data.isEmpty { handle.readabilityHandler = nil } else { lines.append(data) }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        // GroupSpawn makes the child a process-group leader, so a terminate reaches the
        // grandchildren a `codex login` spawns below it (audit P3).
        guard let child = GroupSpawn.spawn(executable: cli, arguments: arguments,
                                           environment: Self.environment(home: home),
                                           workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                                           stdinFD: nil,
                                           stdoutFD: pipe.fileHandleForWriting.fileDescriptor,
                                           stderrFD: pipe.fileHandleForWriting.fileDescriptor)
        else { return .failedToStart("posix_spawn failed") }
        try? pipe.fileHandleForWriting.close()
        RunningCommands.shared.add(groupPID: child.pid)
        defer { RunningCommands.shared.remove(groupPID: child.pid) }
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning {
            let stopped = shouldStop()
            if stopped || Date() >= deadline {
                child.terminate()
                let grace = Date().addingTimeInterval(3)
                while child.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
                if child.isRunning { child.kill() }
                return stopped ? .stopped : .timedOut
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        child.reap()
        return .exited(child.exitStatus)
    }

    public func moveToTrash(_ url: URL) throws {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
            throw SwitcherError.io(L10n.t(.reasonTrashFailed, url.lastPathComponent))
        }
    }

    public func bundleVersion(appURL: URL) -> String? {
        Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public func forceKill(pid: pid_t) -> Bool { kill(pid, SIGKILL) == 0 }

    public func stopAllCommands(grace: TimeInterval) {
        let entries = RunningCommands.shared.all
        entries.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while entries.contains(where: { $0.isRunning() }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        entries.filter { $0.isRunning() }.forEach { $0.kill() }
    }
}

/// Command-line runs in progress, so quitting the app never leaves a `codex login` or a
/// usage read behind. Entries are process-group leaders spawned via GroupSpawn: terminate
/// reaches the whole tree (audit P3).
final class RunningCommands: @unchecked Sendable {
    static let shared = RunningCommands()

    struct Entry {
        let isRunning: () -> Bool
        let terminate: () -> Void
        let kill: () -> Void
    }

    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]

    func add(groupPID pid: pid_t) {
        let entry = Entry(
            isRunning: {
                var s: Int32 = 0
                return waitpid(pid, &s, WNOHANG) == 0
            },
            terminate: {
                _ = Darwin.kill(-pid, SIGTERM)
                _ = Darwin.kill(pid, SIGTERM)
            },
            kill: {
                _ = Darwin.kill(-pid, SIGKILL)
                _ = Darwin.kill(pid, SIGKILL)
            })
        lock.lock(); entries[pid] = entry; lock.unlock()
    }

    func remove(groupPID pid: pid_t) { lock.lock(); entries[pid] = nil; lock.unlock() }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return Array(entries.values) }
}

/// Turns pipe chunks into lines for `runCLI`'s output callback.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    /// Emits a last line that arrived without a trailing newline (call once the pipe is closed).
    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}
