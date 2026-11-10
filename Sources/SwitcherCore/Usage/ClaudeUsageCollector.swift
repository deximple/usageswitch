import Foundation

/// Reads the default `claude` CLI sign-in's usage by running `claude -p /usage`. The CLI self-updates
/// into `~/.local/share/claude/versions/`, so the binary and its version are rediscovered on every read.
/// The vendor binary uses its own sign-in; UsageSwitch only sees the answer text.
public struct ClaudeUsageCollector: Sendable {
    /// The fixed invocation: no project settings, no MCP config, no hooks, no session persistence.
    public static let arguments = [
        "-p", "--setting-sources", "local", "--strict-mcp-config", "--no-session-persistence",
        "--settings", #"{"disableAllHooks":true,"disableClaudeAiConnectors":true}"#,
        "/usage", "--output-format", "stream-json", "--verbose",
    ]

    private let runner: any UsageProcessRunner
    private let home: URL
    private let managed: ClaudeManagedSettings
    private let binaryPaths: [URL]
    private let workingDirectory: URL
    private let now: @Sendable () -> Date

    /// `home` is the real home by default; tests pass a temp home. `binaryPaths` overrides the
    /// discovery list (home-relative candidates plus the two system locations). `workingDirectory`
    /// must already exist; the collector never creates or removes it.
    public init(runner: any UsageProcessRunner,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                managed: ClaudeManagedSettings = .system,
                binaryPaths: [URL]? = nil,
                workingDirectory: URL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.home = home
        self.managed = managed
        self.binaryPaths = binaryPaths ?? Self.defaultBinaryPaths(home: home)
        self.workingDirectory = workingDirectory
        self.now = now
    }

    static func defaultBinaryPaths(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
    }

    public func collect() -> AccountUsage {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [], toolVersion: String? = nil) -> AccountUsage {
            AccountUsage(id: "claude:cli", provider: .claude, accountRef: "cli", label: "CLI sign-in",
                         plan: nil, windows: windows, state: state, readAt: now(), toolVersion: toolVersion)
        }
        guard let binary = binaryPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return finish(.unavailable(.cliMissing)) }
        let toolVersion = Self.toolVersion(of: binary)
        guard !managed.shuts(claudeFolder: home.appendingPathComponent(".claude", isDirectory: true))
        else { return finish(.unavailable(.managed), toolVersion: toolVersion) }
        let read = Self.readUsage(runner: runner, binary: binary, environment: Self.environment(),
                                  workingDirectory: workingDirectory, timeout: 60, now: now)
        return finish(read.state, read.windows, toolVersion: toolVersion)
    }

    static func readUsage(runner: any UsageProcessRunner, binary: URL,
                          environment: [String: String], workingDirectory: URL, timeout: TimeInterval,
                          now: @Sendable () -> Date) -> (state: UsageState, windows: [UsageWindow]) {
        guard isDirectory(workingDirectory) else { return (.failed(.refused), []) }
        let request = UsageProcessRequest(executable: binary, arguments: Self.arguments,
            environment: environment, workingDirectory: workingDirectory,
            stopWhen: { ClaudeUsageOutput.stops($0) || ClaudeUsageOutput.answers($0) },
            timeout: timeout)
        let result = runner.run(request)
        switch result.outcome {
        case .timedOut: return (.failed(.timeout), [])
        case .failedToStart: return (.unavailable(.cliMissing), [])
        case .outputLimit: return (.unavailable(.refused), [])
        case .cancelled: return (.unavailable(.refused), [])
        case .stopped, .exited:
            switch ClaudeUsageOutput.text(in: result.lines) {
            case .failure:
                return (.unavailable(.refused), [])
            case .success(let text):
                switch ClaudeUsageText.windows(text, readAt: now()) {
                case .success(let windows): return (.ok, windows)
                case .failure(.notReporting): return (.notReporting, [])
                case .failure(.unreadable): return (.unavailable(.schemaChanged), [])
            }
        }
    }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The version in the binary's resolved path (`…/versions/<v>`), else nil.
    static func toolVersion(of binary: URL) -> String? {
        let resolved = binary.resolvingSymlinksInPath()
        return resolved.deletingLastPathComponent().lastPathComponent == "versions"
            ? resolved.lastPathComponent : nil
    }

    /// The Dock-like environment minus CLAUDE_CONFIG_DIR (the default sign-in lives in ~/.claude),
    /// plus the flags that keep the run quiet and local.
    static func environment() -> [String: String] {
        var environment = SystemClaudeAppControl.cleanEnvironment(from: ProcessInfo.processInfo.environment)
        environment["CLAUDE_CONFIG_DIR"] = nil
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        environment["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
        environment["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] = "1"
        return environment
    }
}
