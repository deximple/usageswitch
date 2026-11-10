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

    @Test func aNodeShebangLauncherStartsWithTheCollectorEnvironment() throws {
        // audit B-05: a `#!/usr/bin/env node` launcher needs its interpreter on PATH — the pinned
        // system PATH exited 127.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uenv-\(UUID().uuidString)", isDirectory: true)
        let dirA = root.appendingPathComponent("a", isDirectory: true)
        let dirB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let node = dirA.appendingPathComponent("node")
        try "#!/bin/sh\necho started\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let launcher = dirB.appendingPathComponent("codex")
        try "#!/usr/bin/env node\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let env = UsageChildEnvironment.make(for: launcher, home: root, extraDirectories: [dirA])
        let req = UsageProcessRequest(executable: launcher, arguments: [], environment: env,
                                      workingDirectory: root, timeout: 10)
        let result = runner.run(req)
        #expect(result.outcome == .exited(0))
        #expect(result.lines == ["started"])
    }

    @Test func theLauncherDirectoryComesFirstAndSystemDirectoriesStay() throws {
        let root = FileManager.default.temporaryDirectory
        let launcher = root.appendingPathComponent("codex")
        let env = UsageChildEnvironment.make(for: launcher, home: FileManager.default.homeDirectoryForCurrentUser)
        let path = try #require(env["PATH"]).split(separator: ":").map { String($0) }
        #expect(path[0] == root.path)
        #expect(Array(path[1...4]) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(path.contains(NSHomeDirectory() + "/.local/bin"))
    }

    @Test func aRelativeLauncherLinkAddsTheTargetsFolder() throws {
        // npm links `bin/codex -> ../lib/node_modules/@openai/codex/bin/codex.js`.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uenv-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let target = root.appendingPathComponent("lib/pkg/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#!/usr/bin/env node\n".write(to: target.appendingPathComponent("codex.js"), atomically: true, encoding: .utf8)
        let launcher = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: launcher.path, withDestinationPath: "../lib/pkg/bin/codex.js")
        let path = try #require(UsageChildEnvironment.make(for: launcher, home: root)["PATH"])
            .split(separator: ":").map { String($0) }
        #expect(Array(path[0...1]) == [bin.path, target.path])
    }

    @Test func nothingElseFromTheCallerEnvironmentIsAdded() throws {
        let root = FileManager.default.temporaryDirectory
        let env = UsageChildEnvironment.make(
            for: root.appendingPathComponent("codex"),
            home: FileManager.default.homeDirectoryForCurrentUser)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["OPENAI_API_KEY"] == nil)
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
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-process-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = #"printf '%s\n' "$$" > "$1"; exec /bin/sleep 30"#
        let processRequest = request(executable: "/bin/sh",
                                     ["-c", script, "usage-process-test", pidFile.path],
                                     timeout: 60)
        let task = Task.detached { processRunner.run(processRequest) }
        let deadline = Date().addingTimeInterval(30)
        var childPID: pid_t?
        while Date() < deadline {
            if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid_t(value)
            }
            if childPID != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let pid = childPID else {
            task.cancel()
            let result = await task.value
            #expect(result.outcome == .cancelled)
            #expect(childPID != nil)
            return
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(kill(pid, 0) == 0)
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(cancelledAt) < 10)
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
