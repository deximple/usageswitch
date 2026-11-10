import Foundation

/// Assembles the suggestion log roots for one collection pass (audit B-10, D-6).
/// Only *listed* Codex accounts count: a home merely found on the Mac is never a log root.
public enum SuggestionLogRoots {
    public static func make(home: URL, claudeBindings: [ClaudeProfileBinding],
                            registeredClaudeIDs: Set<String>, codexAccounts: [CodexAccount],
                            usages: [AccountUsage]) -> [SuggestionLogRoot] {
        var roots: [SuggestionLogRoot] = []
        var seen = Set<String>()
        func append(_ provider: UsageProvider, _ accountRef: String, _ directory: URL) {
            let identity = "\(provider.rawValue)\u{0}\(accountRef)\u{0}\(directory.standardizedFileURL.path)"
            guard seen.insert(identity).inserted else { return }
            roots.append(SuggestionLogRoot(provider: provider, accountRef: accountRef,
                                           directory: directory))
        }

        append(.claude, "cli", home.appendingPathComponent(".claude", isDirectory: true))
        for binding in claudeBindings where registeredClaudeIDs.contains(binding.accountId) {
            let accountRef = "app:\(binding.accountId)"
            guard SuggestionLogRootPolicy.includes(provider: .claude,
                                                    accountRef: accountRef, usages: usages) else {
                continue
            }
            append(.claude, accountRef,
                   URL(fileURLWithPath: binding.profilePath, isDirectory: true))
        }

        if SuggestionLogRootPolicy.includes(provider: .codex, accountRef: "standard", usages: usages) {
            append(.codex, "standard", home.appendingPathComponent(".codex", isDirectory: true))
        }
        // Only `codex.accounts` — a found-but-not-added home's logs are never read.
        for account in codexAccounts {
            guard SuggestionLogRootPolicy.includes(provider: .codex,
                                                    accountRef: account.id, usages: usages) else {
                continue
            }
            append(.codex, account.id, URL(fileURLWithPath: account.home, isDirectory: true))
        }
        return roots
    }
}
