import Foundation

/// The environment for usage-collector child processes: the launch-time allowlist plus a PATH
/// that can actually find a script launcher's interpreter (audit B-05). A `#!/usr/bin/env node`
/// shim pinned to the system PATH exits 127, so the launcher's own folders come first.
public enum UsageChildEnvironment {
    /// `cleanEnvironment` with PATH rebuilt as: the launcher's folder, the symlink-resolved
    /// launcher's folder, the four system folders, `extraDirectories`, then the user search
    /// folders — deduplicated. Extras beat user bins so a call site can pin an interpreter.
    public static func make(for launcher: URL, home: URL, extraDirectories: [URL] = []) -> [String: String] {
        var environment = SystemClaudeAppControl.cleanEnvironment(from: ProcessInfo.processInfo.environment)
        var dirs: [URL] = [launcher.deletingLastPathComponent()]
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) {
            dirs.append(URL(fileURLWithPath: resolved, isDirectory: true).deletingLastPathComponent())
        }
        dirs += [URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                 URL(fileURLWithPath: "/bin", isDirectory: true),
                 URL(fileURLWithPath: "/usr/sbin", isDirectory: true),
                 URL(fileURLWithPath: "/sbin", isDirectory: true)]
        dirs += extraDirectories
        dirs += UsageInstallations.userBinDirectories(home: home)
        var seen = Set<String>()
        environment["PATH"] = dirs
            .map { $0.standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }
}
