import Foundation

/// One provider's footprint on this Mac: its CLI and/or its app. Filesystem facts only — no sign-in
/// state is inferred, nothing is launched, and no credential file is opened.
public struct UsageInstallation: Equatable, Sendable {
    public let provider: UsageProvider
    public let cli: URL?
    public let app: URL?

    public init(provider: UsageProvider, cli: URL?, app: URL?) {
        self.provider = provider; self.cli = cli; self.app = app
    }
}

/// Explicit directories to search instead of the production roots. A deterministic filesystem seam
/// for tests; not a user setting.
public struct UsageSearchRoots: Equatable, Sendable {
    public let executableDirectories: [URL]
    public let applicationDirectories: [URL]

    public init(executableDirectories: [URL], applicationDirectories: [URL]) {
        self.executableDirectories = executableDirectories
        self.applicationDirectories = applicationDirectories
    }
}

public enum UsageInstallations {
    /// One row per installed provider, in the fixed allCases order. A provider counts as
    /// installed when an executable CLI or its `.app` directory exists. Existence and executability
    /// checks only; the single directory listing is the Cursor vendor `versions/` folder.
    /// With `searchRoots`, only those directories (plus `bundledCodexCLI`) are searched: no vendor
    /// or global fallbacks.
    public static func discover(home: URL, path: String, bundledCodexCLI: URL?,
                                searchRoots: UsageSearchRoots? = nil) -> [UsageInstallation] {
        let pathDirectories = path.split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        func directories(claudeLocal: Bool) -> [URL] {
            if let searchRoots {
                var seen = Set<String>()
                return searchRoots.executableDirectories.filter { seen.insert($0.standardizedFileURL.path).inserted }
            }
            // The caller's PATH wins first — an explicit PATH entry is the user's
            // own environment, so a real binary there beats any fallback location.
            // Then the standard user/package-manager directories in order; the
            // standardized-path dedup keeps the first occurrence, never re-searches.
            var list = pathDirectories
            list.append(home.appendingPathComponent(".local/bin", isDirectory: true))
            if claudeLocal { list.append(home.appendingPathComponent(".claude/local", isDirectory: true)) }
            list += [home.appendingPathComponent(".npm-global/bin", isDirectory: true),
                     home.appendingPathComponent(".bun/bin", isDirectory: true),
                     home.appendingPathComponent(".volta/bin", isDirectory: true),
                     URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                     URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]
            var seen = Set<String>()
            return list.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
        func firstExecutable(named name: String, claudeLocal: Bool = false) -> URL? {
            directories(claudeLocal: claudeLocal)
                .map { $0.appendingPathComponent(name) }
                .first(where: isExecutableFile)
        }
        let appRoots = searchRoots?.applicationDirectories
            ?? [URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true)]
        func app(_ name: String) -> URL? {
            appRoots.map { $0.appendingPathComponent("\(name).app", isDirectory: true) }
                .first(where: isDirectory)
        }

        let codexCLI = bundledCodexCLI.flatMap { isExecutableFile($0) ? $0 : nil }
            ?? firstExecutable(named: "codex")
        let cursorCLI = firstExecutable(named: "cursor-agent")
            ?? (searchRoots == nil ? cursorVendorCLI(home: home) : nil)
        let grokCLI = firstExecutable(named: "grok")
            ?? (searchRoots == nil && isExecutableFile(home.appendingPathComponent(".grok/bin/grok"))
                ? home.appendingPathComponent(".grok/bin/grok") : nil)
        let geminiCLI = firstExecutable(named: "gemini")
        let devinCLI = firstExecutable(named: "devin")
        let opencodeCLI = firstExecutable(named: "opencode")
            ?? (searchRoots == nil && isExecutableFile(home.appendingPathComponent(".opencode/bin/opencode"))
                ? home.appendingPathComponent(".opencode/bin/opencode") : nil)

        let rows = [
            UsageInstallation(provider: .claude,
                              cli: firstExecutable(named: "claude", claudeLocal: true), app: app("Claude")),
            UsageInstallation(provider: .codex, cli: codexCLI, app: app("Codex")),
            UsageInstallation(provider: .cursor, cli: cursorCLI, app: app("Cursor")),
            UsageInstallation(provider: .grok, cli: grokCLI, app: nil),
            UsageInstallation(provider: .gemini, cli: geminiCLI, app: nil),
            UsageInstallation(provider: .devin, cli: devinCLI, app: nil),
            UsageInstallation(provider: .opencode, cli: opencodeCLI, app: nil),
        ]
        return rows.filter { $0.cli != nil || $0.app != nil }
    }

    /// Readings of providers that are installed, in their original order. Never invents a row.
    public static func visible(_ readings: [AccountUsage],
                              installations: [UsageInstallation]) -> [AccountUsage] {
        let installed = Set(installations.map(\.provider))
        return readings.filter { installed.contains($0.provider) }
    }

    /// `~/.local/share/cursor-agent/cursor-agent` or `…/versions/<v>/cursor-agent` (one level deep).
    private static func cursorVendorCLI(home: URL) -> URL? {
        let root = home.appendingPathComponent(".local/share/cursor-agent", isDirectory: true)
        let direct = root.appendingPathComponent("cursor-agent")
        if isExecutableFile(direct) { return direct }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
        return names.sorted(by: >)
            .map { versions.appendingPathComponent($0).appendingPathComponent("cursor-agent") }
            .first(where: isExecutableFile)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        !isDirectory(url) && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
