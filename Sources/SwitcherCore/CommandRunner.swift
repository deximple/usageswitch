import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
}

/// Runs a fixed executable with arguments (no shell). Injected so tests never touch launchd.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}

public struct SystemCommandRunner: CommandRunner {
    /// launchd can leave a `launchctl` call unanswered for minutes; every run is bounded.
    private static let timeout: TimeInterval = 10

    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return CommandResult(status: -1, output: error.localizedDescription) }
        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return CommandResult(status: -1, output: "timed out")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
