import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage installation inventory")
struct UsageInstallationTests {
    private var home: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var bins: URL { home.appendingPathComponent("bins", isDirectory: true) }
    private var apps: URL { home.appendingPathComponent("apps", isDirectory: true) }
    private var roots: UsageSearchRoots {
        UsageSearchRoots(executableDirectories: [bins], applicationDirectories: [apps])
    }
    private func discover(bundledCodexCLI: URL? = nil) -> [UsageInstallation] {
        UsageInstallations.discover(home: home, path: "",
                                  bundledCodexCLI: bundledCodexCLI, searchRoots: roots)
    }
    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    /// Each test calls this once via `defer { cleanup() }` — temporary homes
    /// are removed after the case completes.
    private func cleanup() { try? FileManager.default.removeItem(at: home) }
    private func touchExec(_ rel: String) throws {
        let file = bins.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    private func touchNonExec(_ rel: String) throws {
        let file = bins.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    private func touchApp(_ rel: String) throws {
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    @Test("nothing installed -> empty inventory")
    func empty() { defer { cleanup() }; #expect(discover().isEmpty) }

    @Test("claude cli only -> exactly one claude row, no app")
    func claudeOnly() throws { defer { cleanup() }
        try touchExec("claude")
        let inv = discover()
        #expect(inv.count == 1)
        #expect(inv[0].provider == .claude)
        #expect(inv[0].cli != nil && inv[0].app == nil)
    }

    @Test("all three providers detected once, fixed order")
    func allThree() throws { defer { cleanup() }
        try touchExec("claude"); try touchExec("codex"); try touchApp("Cursor.app")
        let inv = discover()
        #expect(inv.map { $0.provider } == [.claude, .codex, .cursor])
    }

    @Test("duplicate cli candidates deduplicate into one row")
    func dedup() throws { defer { cleanup() }
        try touchExec("claude")
        try FileManager.default.createSymbolicLink(
            at: bins.appendingPathComponent("claude-dup"),
            withDestinationURL: bins.appendingPathComponent("claude"))
        let inv = discover()
        #expect(inv.filter { $0.provider == .claude }.count == 1)
    }

    @Test("duplicate PATH entries for the same dir keep one row")
    func dupPath() throws { defer { cleanup() }
        try touchExec("claude")
        let roots2 = UsageSearchRoots(executableDirectories: [bins, bins], applicationDirectories: [apps])
        let inv = UsageInstallations.discover(home: home, path: "",
                                              bundledCodexCLI: nil, searchRoots: roots2)
        #expect(inv.filter { $0.provider == .claude }.count == 1)
    }

    @Test("non-executable files do not count")
    func nonExec() throws { defer { cleanup() }
        try touchNonExec("claude")
        #expect(discover().isEmpty)
    }

    @Test("app-only provider still detected")
    func appOnly() throws { defer { cleanup() }
        try touchApp("Claude.app")
        let inv = discover()
        #expect(inv.count == 1 && inv[0].provider == .claude && inv[0].app != nil && inv[0].cli == nil)
    }

    @Test("bundled codex cli preferred when executable")
    func bundledCodex() throws { defer { cleanup() }
        let bundled = bins.appendingPathComponent("codex")
        try touchExec("codex")
        let inv = discover(bundledCodexCLI: bundled)
        let codex = inv.first { $0.provider == .codex }
        #expect(codex != nil)
        #expect(codex?.cli == bundled)
    }

    @Test("missing or non-exec bundled codex falls back to PATH codex")
    func bundledFallback() throws { defer { cleanup() }
        try touchExec("codex")
        let ghost = bins.appendingPathComponent("codex-bundled-missing")
        let inv = discover(bundledCodexCLI: ghost)
        let codex = inv.first { $0.provider == .codex }
        #expect(codex?.cli == bins.appendingPathComponent("codex"))
    }

    @Test("arbitrary `agent` binary is not Cursor")
    func noFakeCursor() throws { defer { cleanup() }
        try touchExec("agent")
        #expect(discover().isEmpty)
    }

    @Test("visible helper drops absent providers, preserves rows, no placeholders")
    func visible() {
        let usages = [
            AccountUsage(id: "a", provider: .claude, accountRef: "r1", label: "A", plan: nil,
                         windows: [], state: .ok, readAt: Date(), toolVersion: nil),
            AccountUsage(id: "b", provider: .claude, accountRef: "r2", label: "B", plan: nil,
                         windows: [], state: .ok, readAt: Date(), toolVersion: nil),
            AccountUsage(id: "c", provider: .codex, accountRef: "r3", label: "C", plan: nil,
                         windows: [], state: .ok, readAt: Date(), toolVersion: nil),
        ]
        let inv = [UsageInstallation(provider: .claude, cli: nil, app: nil)]
        let out = UsageInstallations.visible(usages, installations: inv)
        #expect(out.count == 2)
        #expect(out.map { $0.id } == ["a", "b"])
    }
}

@Suite("Install discovery: PATH order + package-manager fallbacks")
struct InventoryPathOrderTests {
    private let home: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    private func cleanup() { try? FileManager.default.removeItem(at: home) }

    private func touch(_ rel: String, exec: Bool = true) throws -> URL {
        let file = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: exec ? 0o755 : 0o644], ofItemAtPath: file.path)
        return file
    }
    private func discover(path: String, bundledCodexCLI: URL? = nil) -> [UsageInstallation] {
        UsageInstallations.discover(home: home, path: path,
                                    bundledCodexCLI: bundledCodexCLI, searchRoots: nil)
    }

    /// Every canonical CLI name: PATH-selected dir wins over ~/.local/bin.
    /// Old policy put .local/bin first and would have failed every case.
    @Test("PATH-selected directory wins over ~/.local/bin for each provider",
          arguments: ["claude", "codex", "cursor-agent", "grok", "gemini", "devin", "opencode"])
    func pathFirst(_ name: String) throws {
        defer { cleanup() }
        _ = try touch(".local/bin/\(name)")
        let selected = try touch("selected/bin/\(name)")
        let rows = discover(path: "\(home.path)/selected/bin:/usr/bin:/bin")
        let provider: UsageProvider = switch name {
        case "cursor-agent": .cursor
        default: UsageProvider(rawValue: name)!
        }
        #expect(rows.first { $0.provider == provider }?.cli == selected)
    }

    /// npm/bun/volta fallback dirs are searched when PATH has only the system bins.
    @Test("package-manager fallback directories",
          arguments: [".npm-global/bin", ".bun/bin", ".volta/bin"])
    func packageManager(_ dir: String) throws {
        defer { cleanup() }
        let gemini = try touch("\(dir)/gemini")
        let rows = discover(path: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(rows.first { $0.provider == .gemini }?.cli == gemini)
    }

    /// Non-executable and directory entries don't shadow a real binary elsewhere.
    @Test("non-exec + directory shadows skip to the real fallback")
    func shadowSkip() throws {
        defer { cleanup() }
        _ = try touch(".local/bin/gemini", exec: false)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".npm-global/bin/gemini"),
            withIntermediateDirectories: true)
        let bun = try touch(".bun/bin/gemini")
        let rows = discover(path: "/usr/bin:/bin")
        #expect(rows.first { $0.provider == .gemini }?.cli == bun)
    }

    /// Explicit searchRoots is a strict seam — never consults defaults or PATH.
    @Test("explicit searchRoots produces empty inventory regardless of fallbacks")
    func seamStrict() throws {
        defer { cleanup() }
        _ = try touch(".npm-global/bin/gemini")
        _ = try touch("selected/bin/devin")
        let roots = UsageSearchRoots(
            executableDirectories: [home.appendingPathComponent("empty-bin", isDirectory: true)],
            applicationDirectories: [home.appendingPathComponent("empty-apps", isDirectory: true)])
        let rows = UsageInstallations.discover(
            home: home, path: "\(home.path)/selected/bin:/usr/bin",
            bundledCodexCLI: nil, searchRoots: roots)
        #expect(rows.isEmpty)
    }

    /// Non-absolute PATH entries are ignored — no CWD or relative resolution.
    @Test("relative and empty PATH components are skipped, absolute selected wins")
    func pathSanitization() throws {
        defer { cleanup() }
        _ = try touch(".local/bin/gemini")
        let selected = try touch("selected/bin/gemini")
        let rows = discover(path: ":.:relative/bin:../bin:\(home.path)/selected/bin::")
        #expect(rows.first { $0.provider == .gemini }?.cli == selected)
    }

    /// Detection never executes the candidate — a side-effect script leaves no marker.
    @Test("a runnable script is detected but never executed")
    func neverExecuted() throws {
        defer { cleanup() }
        let script = home.appendingPathComponent("selected/bin/gemini")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf x > \"$(dirname \"$0\")/invoked\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let rows = discover(path: "\(home.path)/selected/bin")
        #expect(rows.first { $0.provider == .gemini }?.cli == script)
        #expect(!FileManager.default.fileExists(
            atPath: script.deletingLastPathComponent().appendingPathComponent("invoked").path))
    }

    /// A supplied bundled Codex executable wins over a PATH-selected codex.
    @Test("bundled Codex CLI is preferred over PATH")
    func bundledWins() throws {
        defer { cleanup() }
        let bundled = try touch("Codex.app/Contents/Resources/codex")
        _ = try touch("selected/bin/codex")
        let rows = discover(path: "\(home.path)/selected/bin", bundledCodexCLI: bundled)
        #expect(rows.first { $0.provider == .codex }?.cli == bundled)
    }
}
