import Foundation

/// A user LaunchAgent that would restart Claude while its profile is being swapped (design D2-2).
public struct Relauncher: Codable, Equatable, Sendable {
    public let label: String
    public let plistPath: String
}

/// Detects, suspends (bootout) and restores (bootstrap) Claude-relaunching LaunchAgents. Plists are never
/// edited; suspension is journaled so a crash mid-switch is repaired on the next start.
public struct RelauncherGuard: Sendable {
    let env: SwitcherEnvironment
    let fs: SafeFS
    let runner: CommandRunner
    static let launchctl = "/bin/launchctl"

    public init(env: SwitcherEnvironment, fs: SafeFS, runner: CommandRunner) {
        self.env = env
        self.fs = fs
        self.runner = runner
    }

    public func discover() -> [Relauncher] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: env.launchAgentsDir.path) else { return [] }
        return names.sorted().filter { $0.hasSuffix(".plist") }.compactMap { name in
            let url = env.launchAgentsDir.appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { return nil }
            var args = plist["ProgramArguments"] as? [String] ?? []
            if let program = plist["Program"] as? String { args.insert(program, at: 0) }
            var text = args.joined(separator: " ")
            for arg in args where arg.hasPrefix("/") {
                // Only small text scripts are inspected; binaries (NUL bytes) are skipped.
                if let attrs = try? fm.attributesOfItem(atPath: arg), (attrs[.size] as? NSNumber)?.intValue ?? 0 < 65_536,
                   let body = fm.contents(atPath: arg), !body.contains(0) {
                    text += "\n" + String(decoding: body, as: UTF8.self)
                }
            }
            return Self.relaunchesClaude(text) ? Relauncher(label: label, plistPath: url.path) : nil
        }
    }

    /// Lines are pre-filtered with cheap substring checks and length-capped so the regexes stay linear.
    static func relaunchesClaude(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.count <= 4096 && line.contains("open") && line.contains("Claude") && lineRelaunchesClaude(String(line))
        }
    }

    static func lineRelaunchesClaude(_ text: String) -> Bool {
        // `-a Claude`, `-a "Claude"`, `-a 'Claude'` or a path ending in `/Claude.app` — but not e.g. "Claude Switcher".
        let patterns = [
            #"\bopen\b[^\n]*-a\s+(?:"Claude"|'Claude'|Claude(?=[\s;)&|]|$))"#,
            #"\bopen\b[^\n]*(?:^|[\s"'/])Claude\.app\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    public func isLoaded(_ r: Relauncher) -> Bool {
        runner.run(Self.launchctl, ["print", "gui/\(env.uid)/\(r.label)"]).status == 0
    }

    /// Boots out every loaded relauncher; returns the ones suspended. Journal is written first.
    public func suspendAll() throws -> [Relauncher] {
        let loaded = discover().filter(isLoaded)
        guard !loaded.isEmpty else { return [] }
        let pending = (journal() + loaded).uniqued()
        try saveJournal(pending)
        for r in loaded {
            let result = runner.run(Self.launchctl, ["bootout", "gui/\(env.uid)/\(r.label)"])
            if result.status != 0 && isLoaded(r) {
                throw SwitcherError.io(L10n.t(.reasonRelauncherSuspendFailed, r.label, String(result.output.prefix(200))))
            }
        }
        return loaded
    }

    /// The suspended-relaunchers journal exists but cannot be decoded (kept for inspection, never deleted).
    public func journalIsUnreadable() -> Bool {
        guard let data = FileManager.default.contents(atPath: env.relauncherJournalFile.path) else { return false }
        return (try? JSONDecoder().decode([Relauncher].self, from: data)) == nil
    }

    /// Only agents whose plist sits directly in ~/Library/LaunchAgents and still carries the recorded label.
    func isTrusted(_ r: Relauncher) -> Bool {
        let url = URL(fileURLWithPath: r.plistPath)
        guard SafeFS.normalized(url.deletingLastPathComponent()) == SafeFS.normalized(env.launchAgentsDir),
              let data = FileManager.default.contents(atPath: url.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist["Label"] as? String == r.label
    }

    /// Re-bootstraps everything in the journal. Safe to call repeatedly.
    @discardableResult
    public func restoreAll() -> [Relauncher] {
        guard !journalIsUnreadable() else { return [] }
        let all = journal()
        let pending = all.filter(isTrusted)
        let untrusted = all.filter { !isTrusted($0) }   // kept in the journal and reported, never silently dropped
        var remaining: [Relauncher] = []
        for r in pending {
            if !isLoaded(r) {
                _ = runner.run(Self.launchctl, ["bootstrap", "gui/\(env.uid)", r.plistPath])
            }
            if !isLoaded(r) { remaining.append(r) }
        }
        try? saveJournal(untrusted + remaining)
        return pending.filter { !remaining.contains($0) }
    }

    /// Journal entries restoreAll() will not touch (plist moved, relabelled or outside LaunchAgents).
    public func untrustedEntries() -> [Relauncher] { journal().filter { !isTrusted($0) } }

    public func journal() -> [Relauncher] {
        guard let data = FileManager.default.contents(atPath: env.relauncherJournalFile.path) else { return [] }
        return (try? JSONDecoder().decode([Relauncher].self, from: data)) ?? []
    }

    private func saveJournal(_ items: [Relauncher]) throws {
        if items.isEmpty { try fs.remove(env.relauncherJournalFile); return }
        try fs.createDirectory(env.storeDir)
        try fs.write(try JSONEncoder().encode(items), to: env.relauncherJournalFile)
    }
}

extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        var out: [Element] = []
        for e in self where !out.contains(e) { out.append(e) }
        return out
    }
}
