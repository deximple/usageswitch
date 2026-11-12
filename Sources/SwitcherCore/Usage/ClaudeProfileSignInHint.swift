import Foundation

/// The re-login command a saved Claude account's CLI profile needs — display/copy only.
/// UsageSwitch never runs it: the user pastes it into a terminal themselves.
public enum ClaudeProfileSignInHint {
    /// `CLAUDE_CONFIG_DIR='<profile>' claude auth login`, with the path POSIX-single-quoted
    /// so spaces and quotes survive a paste.
    public static func command(profilePath: String) -> String {
        "CLAUDE_CONFIG_DIR=\(shellQuoted(profilePath)) \(UsageText.cliCommand(.claude))"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
