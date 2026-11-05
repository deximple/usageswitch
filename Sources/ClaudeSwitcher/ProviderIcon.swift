import AppKit
import SwiftUI
import SwitcherCore

/// The provider's real product icon, read from the installed app on this Mac via
/// `NSWorkspace.icon(forFile:)`. Displaying a local app icon ships no vendor brand asset —
/// an app that isn't installed falls back to the provider's text name, never a look-alike glyph.
/// Icons are resolved once per process; nothing re-scans the disk on each render.
struct ProviderIcon: View {
    let provider: UsageProvider
    var size: CGFloat = 18

    var body: some View {
        if let icon = Self.icons[provider], let icon {
            Image(nsImage: icon)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Resolved once: the icon of the installed provider app, or nil when it isn't present.
    private static let icons: [UsageProvider: NSImage?] = {
        var found: [UsageProvider: NSImage?] = [:]
        for provider in UsageProvider.allCases {
            guard let url = appURL(provider) else { found[provider] = nil; continue }
            found[provider] = NSWorkspace.shared.icon(forFile: url.path)
        }
        return found
    }()

    /// Standard install folders only (/Applications, then ~/Applications), matching how
    /// SwitcherEnvironment resolves the real app paths.
    static func appURL(_ provider: UsageProvider) -> URL? {
        let name: String
        switch provider {
        case .claude: name = "Claude.app"
        case .codex: name = "Codex.app"
        case .cursor: name = "Cursor.app"
        case .grok, .gemini, .devin, .opencode: return nil // CLI-only for now
        }
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Applications", isDirectory: true)]
        return folders.map { $0.appendingPathComponent(name, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
