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
    private func touchExecutable(at file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    private func touchGeminiCLI(at candidate: URL) throws {
        let target = home.appendingPathComponent("node_modules/@google/gemini-cli/bundle/gemini.js")
        try touchExecutable(at: target)
        try FileManager.default.createDirectory(
            at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
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

    @Test("a regular user-owned 755 executable is trustworthy")
    func trustworthyExec() throws { defer { cleanup() }
        let file = bins.appendingPathComponent("tool")
        try touchExecutable(at: file)
        #expect(UsageInstallations.isTrustworthyExecutable(file))
    }

    @Test("a group- or world-writable executable is refused")
    func writableExecRefused() throws { defer { cleanup() }
        for mode in [0o775, 0o757, 0o777] {
            let file = bins.appendingPathComponent("tool-\(mode)")
            try touchExecutable(at: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            #expect(!UsageInstallations.isTrustworthyExecutable(file))
        }
    }

    @Test("a non-executable file and a symlink to a writable target are refused")
    func nonExecAndSymlinkTarget() throws { defer { cleanup() }
        try touchNonExec("plain")
        #expect(!UsageInstallations.isTrustworthyExecutable(bins.appendingPathComponent("plain")))
        // A symlink is judged by its target: target writable -> refused.
        let target = bins.appendingPathComponent("real-tool")
        try touchExecutable(at: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
        let link = bins.appendingPathComponent("shim")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!UsageInstallations.isTrustworthyExecutable(link))
        // Missing file -> refused.
        #expect(!UsageInstallations.isTrustworthyExecutable(bins.appendingPathComponent("gone")))
    }

    @Test("a group-writable cli is skipped by discovery")
    func writableCliSkipped() throws { defer { cleanup() }
        try touchExec("codex")
        let file = bins.appendingPathComponent("codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: file.path)
        #expect(discover().allSatisfy { $0.provider != .codex })
    }

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

    @Test("Gemini detection skips a plain executable and follows a package symlink")
    func geminiPackageSymlink() throws { defer { cleanup() }
        let earlier = home.appendingPathComponent("first-bin", isDirectory: true)
        let later = home.appendingPathComponent("second-bin", isDirectory: true)
        let plain = earlier.appendingPathComponent("gemini")
        let googleCLI = later.appendingPathComponent("gemini")
        try touchExecutable(at: plain)
        try touchGeminiCLI(at: googleCLI)
        let roots = UsageSearchRoots(executableDirectories: [earlier, later],
                                     applicationDirectories: [apps])
        let inv = UsageInstallations.discover(home: home, path: "",
                                              bundledCodexCLI: nil, searchRoots: roots)
        #expect(inv.first { $0.provider == .gemini }?.cli == googleCLI)
    }

    @Test("a plain gemini executable alone is not the Google Gemini CLI")
    func plainGeminiIgnored() throws { defer { cleanup() }
        try touchExec("gemini")
        #expect(!discover().contains { $0.provider == .gemini })
    }

    @Test("Antigravity is detected from agy and its app")
    func antigravity() throws { defer { cleanup() }
        try touchExec("agy")
        try touchApp("Antigravity.app")
        let row = discover().first { $0.provider == .antigravity }
        #expect(row?.cli == bins.appendingPathComponent("agy"))
        #expect(row?.app == apps.appendingPathComponent("Antigravity.app"))
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
    func visible() { defer { cleanup() }
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
    private func touchGeminiCLI(_ rel: String) throws -> URL {
        let candidate = home.appendingPathComponent(rel)
        let target = home.appendingPathComponent("node_modules/@google/gemini-cli/bundle/gemini.js")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(
            at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
        return candidate
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
        let selected = name == "gemini"
            ? try touchGeminiCLI("selected/bin/\(name)")
            : try touch("selected/bin/\(name)")
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
        let gemini = try touchGeminiCLI("\(dir)/gemini")
        let rows = discover(path: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(rows.first { $0.provider == .gemini }?.cli == gemini)
    }

    @Test("Antigravity CLI falls back to ~/.local/bin/agy")
    func antigravityFallback() throws {
        defer { cleanup() }
        let agy = try touch(".local/bin/agy")
        let rows = discover(path: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(rows.first { $0.provider == .antigravity }?.cli == agy)
    }

    /// Non-executable and directory entries don't shadow a real binary elsewhere.
    @Test("non-exec + directory shadows skip to the real fallback")
    func shadowSkip() throws {
        defer { cleanup() }
        _ = try touch(".local/bin/gemini", exec: false)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".npm-global/bin/gemini"),
            withIntermediateDirectories: true)
        let bun = try touchGeminiCLI(".bun/bin/gemini")
        let rows = discover(path: "/usr/bin:/bin")
        #expect(rows.first { $0.provider == .gemini }?.cli == bun)
    }

    /// Explicit searchRoots is a strict seam — never consults defaults or PATH.
    @Test("explicit searchRoots produces empty inventory regardless of fallbacks")
    func seamStrict() throws {
        defer { cleanup() }
        _ = try touchGeminiCLI(".npm-global/bin/gemini")
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
        let selected = try touchGeminiCLI("selected/bin/gemini")
        let rows = discover(path: ":.:relative/bin:../bin:\(home.path)/selected/bin::")
        #expect(rows.first { $0.provider == .gemini }?.cli == selected)
    }

    /// Detection never executes the candidate — a side-effect script leaves no marker.
    @Test("a runnable script is detected but never executed")
    func neverExecuted() throws {
        defer { cleanup() }
        let script = try touchGeminiCLI("selected/bin/gemini")
        let target = script.resolvingSymlinksInPath()
        try "#!/bin/sh\nprintf x > \"$(dirname \"$0\")/invoked\"\n"
            .write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
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

    @Test("gh detects the Copilot provider, CLI only")
    func copilotGh() throws {
        defer { cleanup() }
        let gh = try touch("selected/bin/gh")
        let roots = UsageSearchRoots(
            executableDirectories: [home.appendingPathComponent("selected/bin")],
            applicationDirectories: [])
        let rows = UsageInstallations.discover(home: home, path: "",
                                               bundledCodexCLI: nil, searchRoots: roots)
        let row = try #require(rows.first { $0.provider == .copilot })
        #expect(row.cli == gh)
        #expect(row.app == nil)
    }

    @Test("no gh means no Copilot row at all")
    func copilotAbsent() throws {
        defer { cleanup() }
        _ = try touch("selected/bin/claude")
        let roots = UsageSearchRoots(
            executableDirectories: [home.appendingPathComponent("selected/bin")],
            applicationDirectories: [])
        let rows = UsageInstallations.discover(home: home, path: "",
                                               bundledCodexCLI: nil, searchRoots: roots)
        #expect(!rows.contains { $0.provider == .copilot })
    }
}
