import Darwin
import Foundation

public struct AntigravityScreenResult: Equatable, Sendable {
    public let state: UsageState
    public let windows: [UsageWindow]

    public init(state: UsageState, windows: [UsageWindow]) {
        self.state = state
        self.windows = windows
    }

    static func success(_ windows: [UsageWindow]) -> Self {
        Self(state: .ok, windows: windows)
    }

    static func failure(_ state: UsageState) -> Self {
        Self(state: state, windows: [])
    }
}

public protocol AntigravityUsageScreenReading: Sendable {
    func read(executable: URL?, now: Date) -> AntigravityScreenResult
}

struct AntigravityPTYResult: Sendable {
    enum Outcome: Equatable, Sendable {
        case completed, timedOut, cancelled, failedToStart, promptNotReady, trustPrompt
    }

    let outcome: Outcome
    let output: Data
    let childPID: Int32?
}

protocol AntigravityPTYExecuting: Sendable {
    func run(executable: URL, workingDirectory: URL,
             environment: [String: String]) -> AntigravityPTYResult
}

struct AntigravityPTYTiming: Sendable {
    var promptQuiet: TimeInterval = 1.5
    var promptTimeout: TimeInterval = 20
    var commandPause: TimeInterval = 0.8
    var screenQuiet: TimeInterval = 1.5
    var screenTimeout: TimeInterval = 15
    var totalTimeout: TimeInterval = 40
    var interruptInterval: TimeInterval = 0.5
    var terminateGrace: TimeInterval = 2
    var killGrace: TimeInterval = 2
}

private enum AntigravityPTYWaitResult {
    case ready
    case trustPrompt
    case promptNotReady
    case cancelled
    case timedOut
}

struct SystemAntigravityPTYRunner: AntigravityPTYExecuting {
    private static let outputLimit = 1_048_576
    private static let readBudget = 262_144
    private let timing: AntigravityPTYTiming

    init(timing: AntigravityPTYTiming = AntigravityPTYTiming()) {
        self.timing = timing
    }

    private static func scheduleReaper(for pid: pid_t) {
        Task.detached(priority: .utility) {
            for _ in 0..<60 {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func run(executable: URL, workingDirectory: URL,
             environment: [String: String]) -> AntigravityPTYResult {
        var env = environment
        env["TERM"] = "xterm-256color"
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), nil]
        var variables: [UnsafeMutablePointer<CChar>?] = env.sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        variables.append(nil)
        defer {
            for value in arguments + variables { if let value { free(value) } }
        }

        var master: Int32 = -1
        var size = winsize()
        size.ws_col = 200
        size.ws_row = 100
        let startedAt = ProcessInfo.processInfo.systemUptime
        let pid = forkpty(&master, nil, nil, &size)
        guard pid >= 0 else {
            return AntigravityPTYResult(outcome: .failedToStart, output: Data(), childPID: nil)
        }
        if pid == 0 {
            guard chdir(workingDirectory.path) == 0 else { _exit(126) }
            arguments.withUnsafeBufferPointer { argv in
                variables.withUnsafeBufferPointer { envp in
                    _ = execve(argv[0]!, UnsafeMutablePointer(mutating: argv.baseAddress!),
                               UnsafeMutablePointer(mutating: envp.baseAddress!))
                }
            }
            _exit(127)
        }
        guard fcntl(master, F_SETFL, O_NONBLOCK) == 0 else {
            _ = close(master)
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            Self.scheduleReaper(for: pid)
            return AntigravityPTYResult(outcome: .failedToStart, output: Data(), childPID: pid)
        }

        var childReaped = false
        var childStatus: Int32 = 0
        var output = Data()
        var pipeClosed = false
        var lastOutputAt: TimeInterval?
        var terminal = AntigravityVTScreenBuffer()

        func readAvailable(retainOutput: Bool = true) -> (valid: Bool, received: Bool) {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            var received = false
            var drained = 0
            func finish(_ valid: Bool) -> (valid: Bool, received: Bool) {
                if received { lastOutputAt = ProcessInfo.processInfo.systemUptime }
                return (valid, received)
            }
            while master >= 0 && drained < Self.readBudget {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(master, buffer.baseAddress, min(buffer.count, Self.readBudget - drained))
                }
                if count > 0 {
                    received = true
                    drained += count
                    terminal.feed(Data(bytes.prefix(count)))
                    if retainOutput, output.count < Self.outputLimit {
                        output.append(contentsOf: bytes.prefix(min(count, Self.outputLimit - output.count)))
                    }
                    continue
                }
                if count == 0 || errno == EIO {
                    pipeClosed = true
                    return finish(true)
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return finish(true) }
                return finish(false)
            }
            return finish(true)
        }

        func write(_ bytes: [UInt8]) {
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { buffer in
                    Darwin.write(master, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                }
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }

        func pauseWhileDraining(_ duration: TimeInterval, retainOutput: Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                if master < 0 || pipeClosed {
                    usleep(20_000)
                    continue
                }
                var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                let milliseconds = Int32(max(1, min(100, remaining * 1_000)))
                let ready = poll(&descriptor, 1, milliseconds)
                if ready > 0 && descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    if !readAvailable(retainOutput: retainOutput).valid { return }
                } else if ready < 0 && errno != EINTR {
                    return
                }
            }
        }

        func pollAndDrain(until deadline: TimeInterval) -> Bool {
            if master < 0 || pipeClosed {
                usleep(20_000)
                return true
            }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let milliseconds = Int32(max(1, min(100, remaining * 1_000)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready > 0 && descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                return readAvailable().valid
            }
            return ready >= 0 || errno == EINTR
        }

        func updateChildStatus() -> Bool {
            if childReaped { return true }
            let result = waitpid(pid, &childStatus, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) {
                childReaped = true
            }
            return childReaped
        }

        func waitForExit(_ duration: TimeInterval) -> Bool {
            if childReaped { return true }
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
            repeat {
                if master >= 0 { _ = readAvailable(retainOutput: false) }
                let result = waitpid(pid, &childStatus, WNOHANG)
                if result == pid { childReaped = true; return true }
                if result < 0 && errno == ECHILD { childReaped = true; return true }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                usleep(20_000)
            } while true
            return childReaped
        }

        func closeMaster() {
            if master >= 0 {
                _ = close(master)
                master = -1
                pipeClosed = true
            }
        }

        func terminate(cancelled: Bool, skipTerminalInput: Bool) -> Bool {
            if childReaped { return true }
            var skipInput = skipTerminalInput
            if !skipInput {
                _ = readAvailable(retainOutput: false)
                // Keys go only into a screen that still shows the main prompt; an unknown or
                // modal screen gets signals, never keystrokes (audit B-09).
                skipInput = terminal.hasTrustPrompt || !terminal.hasMainInputPrompt
            }
            if !skipInput {
                write([0x1b])
                _ = pollAndDrain(until: ProcessInfo.processInfo.systemUptime + 0.05)
                skipInput = terminal.hasTrustPrompt || !terminal.hasMainInputPrompt
            }
            if !skipInput { write([0x03]) }
            if !skipInput && !cancelled {
                pauseWhileDraining(timing.interruptInterval, retainOutput: false)
                skipInput = terminal.hasTrustPrompt || !terminal.hasMainInputPrompt
            }
            if !skipInput { write([0x03]) }
            if skipInput {
                _ = kill(-pid, SIGTERM)
                _ = kill(pid, SIGTERM)
                if waitForExit(timing.terminateGrace) { return true }
            } else if !cancelled {
                if waitForExit(timing.terminateGrace) { return true }
                _ = kill(-pid, SIGTERM)
                _ = kill(pid, SIGTERM)
                if waitForExit(timing.killGrace) { return true }
            } else {
                _ = kill(-pid, SIGTERM)
                _ = kill(pid, SIGTERM)
            }
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
            if waitForExit(3) { return true }
            closeMaster()
            if waitForExit(2) { return true }
            Self.scheduleReaper(for: pid)
            return false
        }

        defer {
            closeMaster()
        }

        func waitForPrompt(until deadline: TimeInterval) -> AntigravityPTYWaitResult {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                if terminal.hasMainInputPrompt, let lastOutputAt,
                   ProcessInfo.processInfo.systemUptime - lastOutputAt >= timing.promptQuiet {
                    return .ready
                }
                guard pollAndDrain(until: deadline) else { return .promptNotReady }
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                if updateChildStatus() { return .promptNotReady }
            }
            return terminal.hasTrustPrompt ? .trustPrompt : .promptNotReady
        }

        func waitForUsageInput() -> AntigravityPTYWaitResult {
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, timing.commandPause)
            // No cumulative flag: only the screen at the END of the pause counts — an echo
            // replaced by a modal before Enter is written is not a go (audit B-09).
            while ProcessInfo.processInfo.systemUptime < deadline {
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                guard pollAndDrain(until: deadline) else { return .promptNotReady }
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                if updateChildStatus() && !terminal.hasUsageInput { return .promptNotReady }
            }
            if terminal.hasTrustPrompt { return .trustPrompt }
            return terminal.hasUsageInput ? .ready : .promptNotReady
        }

        func waitForQuotaScreen(until deadline: TimeInterval) -> AntigravityPTYWaitResult {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                if terminal.hasQuotaTitle, let lastOutputAt,
                   ProcessInfo.processInfo.systemUptime - lastOutputAt >= timing.screenQuiet {
                    return .ready
                }
                guard pollAndDrain(until: deadline) else { return .timedOut }
                if terminal.hasTrustPrompt { return .trustPrompt }
                if Task.isCancelled { return .cancelled }
                if terminal.hasQuotaTitle, let lastOutputAt,
                   ProcessInfo.processInfo.systemUptime - lastOutputAt >= timing.screenQuiet {
                    return .ready
                }
                if updateChildStatus() && !terminal.hasQuotaTitle { return .timedOut }
            }
            return .timedOut
        }

        var outcome: AntigravityPTYResult.Outcome = .timedOut
        var skipTerminalInput = false
        let promptDeadline = min(startedAt + timing.promptTimeout,
                                 startedAt + timing.totalTimeout)
        switch waitForPrompt(until: promptDeadline) {
        case .ready:
            _ = readAvailable(retainOutput: false)
            if terminal.hasTrustPrompt {
                outcome = .trustPrompt
                skipTerminalInput = true
            } else if Task.isCancelled {
                outcome = .cancelled
            } else {
                write(Array("/usage".utf8))
                switch waitForUsageInput() {
                case .ready:
                    _ = readAvailable(retainOutput: false)
                    if terminal.hasTrustPrompt {
                        outcome = .trustPrompt
                        skipTerminalInput = true
                    } else if Task.isCancelled {
                        outcome = .cancelled
                    } else {
                        _ = readAvailable(retainOutput: false)
                        if terminal.hasMainInputPrompt && terminal.hasUsageInput
                            && !terminal.hasTrustPrompt {
                            write([0x0d])
                            let cleanupReserve = timing.interruptInterval + timing.terminateGrace
                                + timing.killGrace + 5
                            let screenDeadline = min(ProcessInfo.processInfo.systemUptime + timing.screenTimeout,
                                                     startedAt + timing.totalTimeout - cleanupReserve)
                            switch waitForQuotaScreen(until: screenDeadline) {
                            case .ready: outcome = .completed
                            case .trustPrompt:
                                outcome = .trustPrompt
                                skipTerminalInput = true
                            case .cancelled: outcome = .cancelled
                            case .timedOut, .promptNotReady: outcome = .timedOut
                            }
                        } else {
                            outcome = .promptNotReady
                            skipTerminalInput = true
                        }
                    }
                case .trustPrompt:
                    outcome = .trustPrompt
                    skipTerminalInput = true
                case .cancelled:
                    outcome = .cancelled
                case .promptNotReady, .timedOut:
                    outcome = .promptNotReady
                }
            }
        case .trustPrompt:
            outcome = .trustPrompt
            skipTerminalInput = true
        case .cancelled:
            outcome = .cancelled
            skipTerminalInput = true
        case .promptNotReady:
            outcome = .promptNotReady
            skipTerminalInput = true
        case .timedOut:
            outcome = .timedOut
            skipTerminalInput = true
        }
        if terminal.hasTrustPrompt {
            outcome = .trustPrompt
            skipTerminalInput = true
        } else if Task.isCancelled {
            outcome = .cancelled
        }
        if !terminate(cancelled: Task.isCancelled, skipTerminalInput: skipTerminalInput) {
            if outcome == .completed { outcome = .timedOut }
        }
        return AntigravityPTYResult(outcome: outcome, output: output, childPID: pid)
    }
}

public struct AntigravityUsageScreen: AntigravityUsageScreenReading {
    private let runner: any AntigravityPTYExecuting

    public init() { runner = SystemAntigravityPTYRunner() }

    init(runner: any AntigravityPTYExecuting) { self.runner = runner }

    public func read(executable: URL?, now: Date) -> AntigravityScreenResult {
        guard let executable else { return .failure(.failed(.network)) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var environment = UsageChildEnvironment.make(for: executable, home: home)
        environment["TERM"] = "xterm-256color"
        let result = runner.run(executable: executable, workingDirectory: home,
                                environment: environment)
        switch result.outcome {
        case .completed: break
        case .cancelled: return .failure(.failed(.refused))
        case .timedOut: return .failure(.failed(.timeout))
        case .promptNotReady, .trustPrompt: return .failure(.unavailable(.schemaChanged))
        case .failedToStart: return .failure(.failed(.network))
        }
        guard let windows = Self.parse(result.output, now: now), !windows.isEmpty else {
            return .failure(.unavailable(.schemaChanged))
        }
        return .success(windows)
    }

    static func containsQuotaTitle(_ data: Data) -> Bool {
        var screen = AntigravityVTScreenBuffer()
        screen.feed(data)
        return screen.hasQuotaTitle
    }

    static func parse(_ data: Data, now: Date) -> [UsageWindow]? {
        var screen = AntigravityVTScreenBuffer()
        let bytes = [UInt8](data)
        let markers = [Data("Within each group".utf8), Data("↑/↓ Scroll".utf8)]
        let checkpoints = markers.flatMap { marker -> [Int] in
            var offsets: [Int] = []
            var start = data.startIndex
            while let range = data.range(of: marker, in: start..<data.endIndex) {
                offsets.append(range.upperBound)
                start = range.upperBound
            }
            return offsets
        }.sorted()
        var candidate: [String]?
        var offset = 0
        for checkpoint in checkpoints {
            for byte in bytes[offset..<checkpoint] { screen.consume(byte) }
            offset = checkpoint
            let lines = screen.lines
            if lines.contains(where: { $0.contains("Models & Quota") }),
               lines.contains(where: { $0.contains("Within each group") || $0.contains("↑/↓ Scroll") }) {
                candidate = lines
            }
        }
        if offset < bytes.count {
            for byte in bytes[offset...] { screen.consume(byte) }
        }
        let lines = candidate ?? screen.lines
        guard let start = lines.firstIndex(where: { $0.contains("Models & Quota") }) else { return nil }
        let content = Array(lines.dropFirst(start + 1))
        var group: String?
        var windows: [UsageWindow] = []
        var index = 0
        while index < content.count {
            let line = content[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains("Within each group") || line.contains("↑/↓ Scroll") { break }
            if let heading = groupHeading(line) {
                group = heading
                index += 1
                continue
            }
            guard let duration = windowDuration(line) else {
                index += 1
                continue
            }
            let end = (index + 1..<content.count).first { offset in
                let candidate = content[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.contains("Within each group") || candidate.contains("↑/↓ Scroll")
                    || groupHeading(candidate) != nil || windowDuration(candidate) != nil
            } ?? content.count
            if let group, validScope(group),
               let percentageIndex = (index + 1..<end).first(where: { remainingPercent(content[$0]) != nil }),
               let remaining = remainingPercent(content[percentageIndex]) {
                let reset = (index + 1..<end).compactMap { parseReset(content[$0], now: now) }.first
                windows.append(UsageWindow(scope: AntigravityScope.canonical(group),
                                           durationMinutes: duration,
                                           usedPercent: min(100, max(0, 100 - remaining)),
                                           resetsAt: reset))
            }
            index = max(index + 1, end)
        }
        return windows.isEmpty ? nil : windows
    }

    private static func groupHeading(_ line: String) -> String? {
        guard !line.isEmpty, !line.contains("%"), !line.contains("["),
              line.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
                      || scalar == " " || scalar == "&" || scalar == "-"
              }),
              line.contains(where: { $0.isLetter }) else { return nil }
        return line.lowercased().split(separator: " ").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func validScope(_ scope: String) -> Bool {
        (1...40).contains(scope.count) && scope.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value) || scalar == " " || scalar == "."
                || scalar == "&" || scalar == "-"
        }
    }

    private static func windowDuration(_ line: String) -> Int? {
        let label = line.lowercased()
        if label.contains("weekly") { return 10_080 }
        if label.contains("five hour") || label.contains("5-hour") || label.range(of: #"\b5h\b"#, options: .regularExpression) != nil {
            return 300
        }
        return nil
    }

    private static func remainingPercent(_ line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3}(?:\.[0-9]+)?)%"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[valueRange])
    }

    private static func parseReset(_ line: String, now: Date) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bresets?\s+(in|at)\s+(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let kindRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        let kind = line[kindRange].lowercased()
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "at" { return UsageJSON.resetDateISO(value) }
        guard let relative = try? NSRegularExpression(
            pattern: #"^(?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m)?$"#),
              let relativeMatch = relative.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        else { return nil }
        var seconds: TimeInterval = 0
        for (component, multiplier) in [(1, 86_400.0), (2, 3_600.0), (3, 60.0)] {
            if let componentRange = Range(relativeMatch.range(at: component), in: value),
               let amount = Double(value[componentRange]) {
                seconds += amount * multiplier
            }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}

public struct AntigravityVTScreenBuffer: Sendable {
    private enum State: Sendable {
        case ground, escape, csi(String), osc, oscEscape, charset
    }

    private let columns: Int
    private let rows: Int
    private var cells: [[String]]
    private var column = 0
    private var row = 0
    private var state: State = .ground
    private var utf8: [UInt8] = []
    private var utf8Length = 0

    public init(columns: Int = 200, rows: Int = 100) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        cells = Array(repeating: Array(repeating: " ", count: max(1, columns)),
                      count: max(1, rows))
    }

    public var lines: [String] {
        cells.map { row in
            row.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Set when an unrecognized CSI final was consumed: the screen may be wrong, so prompt and
    /// input checks refuse to claim anything (audit B-09).
    private(set) var untrusted = false

    var hasMainInputPrompt: Bool {
        !untrusted && !hasTrustPrompt && lines.contains {
            $0.localizedCaseInsensitiveContains("? for shortcuts")
        }
    }

    var hasTrustPrompt: Bool {
        let text = lines.joined(separator: "\n").lowercased()
        return text.contains("do you trust the contents of this project")
            || text.contains("trust this folder")
    }

    var hasUsageInput: Bool {
        guard !untrusted, !hasTrustPrompt else { return false }
        // The row must carry exactly the `/usage` command: the command ends at whitespace or
        // end-of-row, so `> /usage-report` and `> /usagex` are not matches, while the real
        // echo row's trailing hint text still counts (audit B-09).
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in ["> /usage", "› /usage"] where trimmed.hasPrefix(marker) {
                let rest = trimmed.dropFirst(marker.count)
                return rest.isEmpty || rest.first.map(\.isWhitespace) == true
            }
            return false
        }
    }

    var hasQuotaTitle: Bool {
        lines.contains { $0.contains("Models & Quota") }
    }

    public mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    fileprivate mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1b {
                flushIncompleteUTF8()
                state = .escape
            } else if byte == 0x0d {
                flushIncompleteUTF8(); column = 0
            } else if byte == 0x0a {
                flushIncompleteUTF8(); lineFeed()
            } else if byte == 0x08 {
                flushIncompleteUTF8(); column = max(0, column - 1)
            } else if byte == 0x09 {
                flushIncompleteUTF8(); column = min(columns - 1, ((column / 8) + 1) * 8)
            } else if byte >= 0x20 && byte != 0x7f {
                appendUTF8(byte)
            }
        case .escape:
            switch byte {
            case 0x5b: state = .csi("")
            case 0x5d: state = .osc
            case 0x28, 0x29, 0x2a, 0x2b, 0x2d, 0x2e, 0x2f: state = .charset
            case 0x4d:
                flushIncompleteUTF8()
                if row == 0 {
                    cells.removeLast()
                    cells.insert(Array(repeating: " ", count: columns), at: 0)
                } else {
                    row -= 1
                }
                state = .ground
            default: state = .ground
            }
        case .charset:
            state = .ground
        case .osc:
            if byte == 0x07 { state = .ground }
            else if byte == 0x1b { state = .oscEscape }
        case .oscEscape:
            state = byte == 0x5c ? .ground : .osc
        case .csi(var parameters):
            if (0x40...0x7e).contains(byte) {
                executeCSI(parameters, final: byte)
                state = .ground
            } else if parameters.utf8.count < 64 {
                parameters.append(Character(UnicodeScalar(byte)))
                state = .csi(parameters)
            } else {
                state = .ground
            }
        }
    }

    private mutating func appendUTF8(_ byte: UInt8) {
        if utf8.isEmpty {
            if byte < 0x80 { put(String(UnicodeScalar(byte))); return }
            if (0xc2...0xdf).contains(byte) { utf8Length = 2 }
            else if (0xe0...0xef).contains(byte) { utf8Length = 3 }
            else if (0xf0...0xf4).contains(byte) { utf8Length = 4 }
            else { put("�"); return }
            utf8 = [byte]
            return
        }
        guard (0x80...0xbf).contains(byte) else {
            flushIncompleteUTF8()
            appendUTF8(byte)
            return
        }
        utf8.append(byte)
        if utf8.count == utf8Length {
            put(String(decoding: utf8, as: UTF8.self))
            utf8.removeAll(keepingCapacity: true)
            utf8Length = 0
        }
    }

    private mutating func flushIncompleteUTF8() {
        if !utf8.isEmpty { put("�"); utf8.removeAll(keepingCapacity: true); utf8Length = 0 }
    }

    private mutating func put(_ value: String) {
        guard row >= 0, row < rows, column >= 0, column < columns else { return }
        cells[row][column] = value
        column = min(columns - 1, column + 1)
    }

    private mutating func lineFeed() {
        if row < rows - 1 { row += 1 }
        else { cells.removeFirst(); cells.append(Array(repeating: " ", count: columns)) }
    }

    private mutating func clear() {
        cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        column = 0; row = 0
    }

    private mutating func executeCSI(_ raw: String, final: UInt8) {
        if raw == "?1049", final == 0x68 || final == 0x6c { clear(); return }
        // Private prefixes and any intermediate byte (0x20-0x2F, e.g. " q", "$p") never move
        // the cursor or cells in ways we model — ignore them wholesale (audit B-09).
        if let first = raw.first, "?><=".contains(first) { return }
        if raw.unicodeScalars.contains(where: { (0x20...0x2f).contains($0.value) }) { return }
        let parameters = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < parameters.count, parameters[index] > 0 else { return fallback }
            return min(parameters[index], 10_000)
        }
        switch final {
        case 0x48, 0x66:
            row = min(rows - 1, max(0, value(0) - 1))
            column = min(columns - 1, max(0, value(1) - 1))
        case 0x41: row = max(0, row - value(0))
        case 0x42: row = min(rows - 1, row + value(0))
        case 0x43: column = min(columns - 1, column + value(0))
        case 0x44: column = max(0, column - value(0))
        case 0x47: column = min(columns - 1, max(0, value(0) - 1))
        case 0x64: row = min(rows - 1, max(0, value(0) - 1))
        case 0x4b: eraseLine(value(0, default: 0))
        case 0x4a: eraseDisplay(value(0, default: 0))
        case 0x58: eraseCharacters(value(0))
        case 0x50: deleteCharacters(value(0))
        case 0x5a: column = max(0, ((column / 8) - max(1, value(0))) * 8)
        case 0x6d, 0x6e, 0x63, 0x74, 0x68, 0x6c, 0x71, 0x70, 0x73, 0x75:
            break // SGR/DSR/DA/window ops/mode/tab clear/save-restore: no grid change
        default: untrusted = true
        }
    }

    /// ECH: blank the next n cells from the cursor without moving it.
    private mutating func eraseCharacters(_ count: Int) {
        for x in column..<min(columns, column + count) { cells[row][x] = " " }
    }

    /// DCH: drop n cells at the cursor and shift the rest of the row left.
    private mutating func deleteCharacters(_ count: Int) {
        guard column < columns else { return }
        // Never more than what is left of the row, so the row keeps exactly `columns` cells.
        let deleted = min(count, columns - column)
        var rowCells = cells[row]
        let tail = rowCells[(column + deleted)..<columns]
        rowCells.replaceSubrange(column..<columns, with: tail + Array(repeating: " ", count: deleted))
        cells[row] = rowCells
    }

    /// Cell count of every row, for tests: each must stay `columns`.
    var rowWidths: [Int] { cells.map(\.count) }

    private mutating func eraseLine(_ mode: Int) {
        guard (0...2).contains(mode) else { return }
        let range: ClosedRange<Int> = mode == 0 ? column...(columns - 1)
            : mode == 1 ? 0...column : 0...(columns - 1)
        for index in range { cells[row][index] = " " }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        guard (0...3).contains(mode) else { return }
        if mode == 2 || mode == 3 {
            for y in 0..<rows { for x in 0..<columns { cells[y][x] = " " } }
        } else if mode == 0 {
            eraseLine(0)
            if row + 1 < rows {
                for y in (row + 1)..<rows { for x in 0..<columns { cells[y][x] = " " } }
            }
        } else {
            if row > 0 {
                for y in 0..<row { for x in 0..<columns { cells[y][x] = " " } }
            }
            eraseLine(1)
        }
    }
}
