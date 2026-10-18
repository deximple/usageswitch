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
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.environment = Self.environment(home: home)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LineSplitter(onOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in lines.append(handle.availableData) }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return .failedToStart(error.localizedDescription) }
        RunningCommands.shared.add(process)
        defer { RunningCommands.shared.remove(process) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let stopped = shouldStop()
            if stopped || Date() >= deadline {
                process.terminate()
                let grace = Date().addingTimeInterval(3)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return stopped ? .stopped : .timedOut
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .exited(process.terminationStatus)
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
        let processes = RunningCommands.shared.all
        processes.forEach { if $0.isRunning { $0.terminate() } }
        let deadline = Date().addingTimeInterval(grace)
        while processes.contains(where: \.isRunning) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        processes.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
    }
}

/// Command-line runs in progress, so quitting the app never leaves a `codex login` behind.
final class RunningCommands: @unchecked Sendable {
    static let shared = RunningCommands()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) { lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock() }
    func remove(_ process: Process) { lock.lock(); processes[ObjectIdentifier(process)] = nil; lock.unlock() }
    var all: [Process] { lock.lock(); defer { lock.unlock() }; return Array(processes.values) }
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
}
