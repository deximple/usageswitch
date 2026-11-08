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
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        process.standardError = FileHandle.nullDevice
        var stdinPipe: Pipe?
        if request.stdinLines != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        let box = UsageLineBox()
        let splitter = LineSplitter { line in
            box.append(line)
            if request.stopWhen?(line) == true { box.match() }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if box.accepts(data.count, limit: request.maxOutputBytes) { splitter.append(data) }
        }
        do { try process.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            return UsageProcessResult(lines: [], outcome: .failedToStart)
        }
        RunningCommands.shared.add(process)
        defer { RunningCommands.shared.remove(process) }
        if let lines = request.stdinLines, let stdinPipe {
            // Writing to a dead child's pipe raises SIGPIPE and would kill this app; the write then
            // just fails with EPIPE, which is ignored — the run ends as exited/timedOut anyway.
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            for line in lines {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        let deadline = Date().addingTimeInterval(request.timeout)
        while process.isRunning {
            if Task.isCancelled || box.matched || Date() >= deadline {
                let cancelled = Task.isCancelled
                process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                drain(stdout, into: splitter, budget: box, limit: request.maxOutputBytes)
                let outcome: UsageProcessResult.Outcome = cancelled ? .cancelled
                    : box.overflowed ? .outputLimit : box.matched ? .stopped : .timedOut
                return UsageProcessResult(lines: box.lines, outcome: outcome)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        drain(stdout, into: splitter, budget: box, limit: request.maxOutputBytes)
        return UsageProcessResult(lines: box.lines,
                                  outcome: box.overflowed ? .outputLimit : .exited(process.terminationStatus))
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
