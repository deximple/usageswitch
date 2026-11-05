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
