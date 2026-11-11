import Darwin
import Foundation

/// One read-only command a usage collector wants to run.
public struct UsageProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Lines written to stdin, which then stays open until the run ends; nil means /dev/null.
    /// Kept open because a server that sees stdin close exits before answering.
    public var stdinLines: [String]?
    /// Checked against each stdout line; the first match ends the run. nil = run to exit.
    public var stopWhen: (@Sendable (String) -> Bool)?
    /// Bound on collected stdout bytes; crossing it terminates the run. Default 1 MiB.
    public var maxOutputBytes: Int
    public var timeout: TimeInterval

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
                stdinLines: [String]? = nil, stopWhen: (@Sendable (String) -> Bool)? = nil,
                maxOutputBytes: Int = 1_048_576, timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.stdinLines = stdinLines
        self.stopWhen = stopWhen; self.maxOutputBytes = maxOutputBytes; self.timeout = timeout
    }
}

public struct UsageProcessResult: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `stopWhen` matched a line.
        case stopped
        case exited(Int32)
        case timedOut
        case failedToStart
        case outputLimit
        case cancelled
    }
    /// The stdout lines read before the run ended. Stderr is never captured (it may carry identity).
    public var lines: [String]
    public var outcome: Outcome

    public init(lines: [String], outcome: Outcome) {
        self.lines = lines; self.outcome = outcome
    }
}

/// Runs vendor command-line tools for usage reads, injected so tests never touch real binaries.
public protocol UsageProcessRunner: Sendable {
    func run(_ request: UsageProcessRequest) -> UsageProcessResult
}

/// posix_spawn wrapper: the child leads a new process group (POSIX_SPAWN_SETPGROUP, applied
/// before exec — a post-run setpgid always loses that race) so a terminate reaches the
/// grandchildren a launcher spawns below it (audit P3). CLOEXEC_DEFAULT keeps every other
/// descriptor of this process out of the child.
enum GroupSpawn {
    static func spawn(executable: URL, arguments: [String], environment: [String: String],
                      workingDirectory: URL, stdinFD: Int32?, stdoutFD: Int32,
                      stderrFD: Int32?) -> Child? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdinFD {
            posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        if let stderrFD {
            posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        // Same signal hygiene as Process(): an empty mask and default dispositions — a mask
        // or a handler inherited from the spawning thread would leave the child deaf to
        // SIGTERM and make every stop a full-grace SIGKILL.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path)]
        argv += arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        // A file-action chdir happens in the child between spawn and exec; a failing one
        // fails the spawn, never silently runs in the wrong directory.
        let result = workingDirectory.withUnsafeFileSystemRepresentation { cwd -> Int32 in
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
            return argv.withUnsafeBufferPointer { argvBuffer in
                envp.withUnsafeBufferPointer { envpBuffer in
                    posix_spawn(&pid, executable.path, &actions, &attributes,
                                argvBuffer.baseAddress, envpBuffer.baseAddress)
                }
            }
        }
        return result == 0 ? Child(pid: pid) : nil
    }

    /// waitpid bookkeeping for one spawned child. Signals go to the whole group first,
    /// with a direct-pid signal as fallback.
    final class Child: @unchecked Sendable {
        let pid: pid_t
        private var status: Int32 = 0
        private var reaped = false

        init(pid: pid_t) { self.pid = pid }

        var isRunning: Bool {
            if reaped { return false }
            var s: Int32 = 0
            let result = waitpid(pid, &s, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { reaped = true; status = s }
            return !reaped
        }

        /// waitpid(..., 0) — EINTR only retries.
        func reap() {
            while !reaped {
                var s: Int32 = 0
                let result = waitpid(pid, &s, 0)
                if result == pid || (result < 0 && errno != EINTR) { reaped = true; status = s }
            }
        }

        /// Exit code, or 128+signal when killed. Only meaningful after the child exited.
        var exitStatus: Int32 {
            status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        }

        func terminate() {
            _ = Darwin.kill(-pid, SIGTERM)
            _ = Darwin.kill(pid, SIGTERM)
        }

        func kill() {
            _ = Darwin.kill(-pid, SIGKILL)
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}

/// Lines arriving while the run is being torn down, plus the predicate match flag.
final class UsageLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _matched = false

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var matched: Bool { lock.lock(); defer { lock.unlock() }; return _matched }
    private var bytes = 0
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return _overflowed }
    private var _overflowed = false

    func append(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }

    /// Budget raw chunks before line splitting, including output without any newline.
    func accepts(_ count: Int, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_overflowed else { return false }
        guard count <= limit - bytes else {
            _overflowed = true
            _matched = true
            return false
        }
        bytes += count
        return true
    }
    func match() { lock.lock(); _matched = true; lock.unlock() }
}

public struct SystemUsageProcessRunner: UsageProcessRunner {
    public init() {}

    public func run(_ request: UsageProcessRequest) -> UsageProcessResult {
        guard request.maxOutputBytes > 0, request.timeout.isFinite, request.timeout > 0 else {
            return UsageProcessResult(lines: [], outcome: .failedToStart)
        }
        guard !Task.isCancelled else {
            return UsageProcessResult(lines: [], outcome: .cancelled)
        }
        let stdout = Pipe()
        var stdinPipe: Pipe?
        let box = UsageLineBox()
        let splitter = LineSplitter { line in
            box.append(line)
            if request.stopWhen?(line) == true { box.match() }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF is terminal: without this the handler keeps firing on the closed pipe.
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if box.accepts(data.count, limit: request.maxOutputBytes) { splitter.append(data) }
        }
        if request.stdinLines != nil { stdinPipe = Pipe() }
        guard let child = GroupSpawn.spawn(executable: request.executable,
                                           arguments: request.arguments,
                                           environment: request.environment,
                                           workingDirectory: request.workingDirectory,
                                           stdinFD: stdinPipe?.fileHandleForReading.fileDescriptor,
                                           stdoutFD: stdout.fileHandleForWriting.fileDescriptor,
                                           stderrFD: nil)
        else {
            stdout.fileHandleForReading.readabilityHandler = nil
            return UsageProcessResult(lines: [], outcome: .failedToStart)
        }
        // The parent only reads stdout / writes stdin; close the ends the child owns.
        try? stdout.fileHandleForWriting.close()
        if let stdinPipe { try? stdinPipe.fileHandleForReading.close() }

        RunningCommands.shared.add(groupPID: child.pid)
        defer { RunningCommands.shared.remove(groupPID: child.pid) }
        if let lines = request.stdinLines, let stdinPipe {
            // Writing to a dead child's pipe raises SIGPIPE and would kill this app; the write then
            // just fails with EPIPE, which is ignored — the run ends as exited/timedOut anyway.
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            for line in lines {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
        while child.isRunning {
            if Task.isCancelled || box.matched || ProcessInfo.processInfo.systemUptime >= deadline {
                let cancelled = Task.isCancelled
                child.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 2
                while child.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning {
                    child.kill()
                    child.reap()
                }
                drain(stdout, into: splitter, budget: box, limit: request.maxOutputBytes)
                let outcome: UsageProcessResult.Outcome = cancelled ? .cancelled
                    : box.overflowed ? .outputLimit : box.matched ? .stopped : .timedOut
                return UsageProcessResult(lines: box.lines, outcome: outcome)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.reap()
        drain(stdout, into: splitter, budget: box, limit: request.maxOutputBytes)
        return UsageProcessResult(lines: box.lines,
                                  outcome: box.overflowed ? .outputLimit : .exited(child.exitStatus))
    }

    /// After the handler is released, reads whatever is still in the pipe without blocking — a
    /// grandchild may hold the write end open, so a plain read could hang. Feeds the splitter so a
    /// last line racing the exit is not lost.
    private func drain(_ pipe: Pipe, into splitter: LineSplitter, budget: UsageLineBox, limit: Int) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            guard budget.accepts(count, limit: limit) else { break }
            splitter.append(Data(chunk[0..<count]))
        }
        splitter.flush()
    }
}
