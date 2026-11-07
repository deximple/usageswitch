import Foundation
import Testing
@testable import SwitcherCore

/// The real runner against harmless system binaries only — never codex, claude, security or the network.
@Suite("System usage process runner")
struct UsageProcessRunnerTests {
    let runner = SystemUsageProcessRunner()
    let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

    func request(executable: String, _ arguments: [String], stdinLines: [String]? = nil,
                 stopWhen: (@Sendable (String) -> Bool)? = nil, timeout: TimeInterval = 10) -> UsageProcessRequest {
        UsageProcessRequest(executable: URL(fileURLWithPath: executable), arguments: arguments,
                            environment: environment, workingDirectory: FileManager.default.temporaryDirectory,
                            stdinLines: stdinLines, stopWhen: stopWhen, timeout: timeout)
    }

    @Test("stdin lines are written and stay open; the matching line stops the run")
    func stoppedOnMatch() {
        // cat echoes each stdin line back — line 2 is the answer being waited for.
        let result = runner.run(request(executable: "/bin/cat", [], stdinLines: ["one", "two"],
                                        stopWhen: { $0 == "two" }))
        #expect(result.outcome == .stopped)
        #expect(result.lines == ["one", "two"])
    }

    @Test("a run past its deadline is terminated")
    func timedOut() {
        let started = Date()
        let result = runner.run(request(executable: "/bin/sleep", ["5"], timeout: 0.5))
        #expect(result.outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test("cancellation terminates and reaps the child promptly")
    func cancelled() async throws {
        let processRunner = SystemUsageProcessRunner()
        let request = request(executable: "/bin/sleep", ["30"], timeout: 60)
        let task = Task.detached { processRunner.run(request) }
        let deadline = Date().addingTimeInterval(3)
        var childPID: pid_t?
        while Date() < deadline {
            childPID = RunningCommands.shared.all.first {
                $0.executableURL?.path == "/bin/sleep" && $0.arguments == ["30"]
            }?.processIdentifier
            if childPID != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = try #require(childPID)
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(cancelledAt) < 3)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("a run without a predicate ends when the process exits")
    func runToExit() {
        let result = runner.run(request(executable: "/bin/echo", ["hello"]))
        #expect(result.outcome == .exited(0))
        #expect(result.lines == ["hello"])
    }

    @Test("a missing executable is failedToStart")
    func failedToStart() {
        let result = runner.run(request(executable: "/nonexistent/binary-xyz", []))
        #expect(result.outcome == .failedToStart)
        #expect(result.lines.isEmpty)
    }

    @Test("writing to a dead child's stdin does not kill this process")
    func deadChildStdin() {
        // ~256 KB of stdin, far bigger than the pipe buffer: sh exits before it can all be written.
        let lines = [String(repeating: "x", count: 262_144)]
        let result = runner.run(request(executable: "/bin/sh", ["-c", "exit 0"], stdinLines: lines))
        #expect(result.outcome == .exited(0))
    }

    @Test("lines written just before exit are never lost", .serialized)
    func tailDrained() {
        // printf writes and exits at once; the last line has no trailing newline.
        for _ in 0..<50 {
            let result = runner.run(request(executable: "/bin/sh", ["-c", #"printf "a\nb\nlast""#]))
            #expect(result.lines == ["a", "b", "last"])
        }
    }
}
