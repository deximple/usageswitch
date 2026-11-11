import AppKit
import Foundation

/// Side effects on Claude.app, injected so the orchestrator is testable without the real app.
public protocol ClaudeAppControl: Sendable {
    /// Graceful quit request (NSRunningApplication.terminate — no Apple Events automation consent).
    func requestQuit(pid: pid_t) -> Bool
    /// One SIGTERM; Electron routes it through the same before-quit path.
    func signalTerminate(pid: pid_t) -> Bool
    /// Launch through LaunchServices so our own environment (e.g. CLAUDE_CONFIG_DIR) is not inherited.
    func launch(appURL: URL) throws
    func open(url: URL) -> Bool
    func bundleVersion(appURL: URL) -> String?
}

public protocol Clock: Sendable {
    func now() -> Date
    /// Monotonic seconds for elapsed-time measurement: wall-clock changes and sleep/wake
    /// drift cannot make a timeout fire early or late (audit P3).
    func uptime() -> TimeInterval
    func sleep(_ seconds: TimeInterval)
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}

public struct SystemClaudeAppControl: ClaudeAppControl {
    public init() {}

    public func requestQuit(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.terminate()
    }

    public func signalTerminate(pid: pid_t) -> Bool { kill(pid, SIGTERM) == 0 }

    public func launch(appURL: URL) throws {
        // LaunchServices hands the *caller's* environment to the launched app, so a switcher started from a
        // shell that has e.g. CLAUDE_CONFIG_DIR would leak it into Claude and every Code-tab session.
        // Launch through /usr/bin/open with a Dock-like minimal environment instead.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appURL.path]
        process.environment = Self.cleanEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw SwitcherError.launchFailed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); throw SwitcherError.launchFailed(L10n.t(.reasonOpenTimeout)) }
        guard process.terminationStatus == 0 else { throw SwitcherError.launchFailed(L10n.t(.reasonOpenExitCode, Int(process.terminationStatus))) }
    }

    /// The variables launchd gives a Dock-launched app; everything else is dropped.
    static let allowedLaunchKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "LANG", "COMMAND_MODE", "__CF_USER_TEXT_ENCODING",
    ]

    public static func cleanEnvironment(from env: [String: String]) -> [String: String] {
        var clean = env.filter { allowedLaunchKeys.contains($0.key) }
        clean["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        // Identity comes from the account database, not from whatever the caller exported.
        if let pw = getpwuid(getuid()) {
            clean["HOME"] = String(cString: pw.pointee.pw_dir)
            clean["USER"] = String(cString: pw.pointee.pw_name)
            clean["LOGNAME"] = String(cString: pw.pointee.pw_name)
            clean["SHELL"] = String(cString: pw.pointee.pw_shell)
        }
        return clean
    }

    /// Delivers a claude:// URL through /usr/bin/open with the same clean environment as `launch`, so even
    /// if it ends up launching Claude nothing from the caller's environment leaks in.
    public func open(url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        process.environment = Self.cleanEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public func bundleVersion(appURL: URL) -> String? {
        Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error?) { lock.lock(); error = e; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
