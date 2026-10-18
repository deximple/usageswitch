import Foundation

/// All filesystem locations the switcher reads or writes. Tests build this from temp directories.
public struct SwitcherEnvironment: Sendable {
    public var home: URL
    public var claudeAppURL: URL
    public var claudeBundleID: String
    public var claudeUserData: URL
    public var claudeLogsDir: URL
    public var launchAgentsDir: URL
    public var storeDir: URL
    public var codexAppURL: URL
    public var uid: uid_t

    public init(
        home: URL,
        claudeAppURL: URL,
        claudeBundleID: String = "com.anthropic.claudefordesktop",
        claudeUserData: URL,
        claudeLogsDir: URL,
        launchAgentsDir: URL,
        storeDir: URL,
        codexAppURL: URL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
        uid: uid_t = getuid()
    ) {
        self.home = home
        self.claudeAppURL = claudeAppURL
        self.claudeBundleID = claudeBundleID
        self.claudeUserData = claudeUserData
        self.claudeLogsDir = claudeLogsDir
        self.launchAgentsDir = launchAgentsDir
        self.storeDir = storeDir
        self.codexAppURL = codexAppURL
        self.uid = uid
    }

    /// Real locations on this Mac.
    public static func live() -> SwitcherEnvironment {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let appFolders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          home.appendingPathComponent("Applications", isDirectory: true)]
        func app(_ name: String) -> URL {
            installedApp(named: name, in: appFolders) ?? appFolders[0].appendingPathComponent(name, isDirectory: true)
        }
        return SwitcherEnvironment(
            home: home,
            claudeAppURL: app("Claude.app"),
            claudeUserData: appSupport.appendingPathComponent("Claude", isDirectory: true),
            claudeLogsDir: home.appendingPathComponent("Library/Logs/Claude", isDirectory: true),
            launchAgentsDir: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            storeDir: appSupport.appendingPathComponent(ProductInfo.defaultBundleID, isDirectory: true),
            codexAppURL: app("Codex.app")
        )
    }

    /// The first of `folders` holding the app: /Applications, or ~/Applications for an app installed for one user.
    static func installedApp(named name: String, in folders: [URL]) -> URL? {
        folders.map { $0.appendingPathComponent(name, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var claudeMainExecutable: URL {
        claudeAppURL.appendingPathComponent("Contents/MacOS/Claude")
    }

    public var claudeConfigJSON: URL { claudeUserData.appendingPathComponent("config.json") }
    public var claudeCookies: URL { claudeUserData.appendingPathComponent("Cookies") }
    public var mainLog: URL { claudeLogsDir.appendingPathComponent("main.log") }

    public var snapshotsDir: URL { storeDir.appendingPathComponent("snapshots", isDirectory: true) }
    /// Store of the personal 1.0 build: never written; its snapshots are copied once, its lock is shared.
    public var legacyStoreDir: URL {
        storeDir.deletingLastPathComponent().appendingPathComponent(ProductInfo.legacyBundleID, isDirectory: true)
    }
    /// False when this store *is* the legacy one (nothing to import or coordinate with).
    public var hasSeparateLegacyStore: Bool { SafeFS.normalized(legacyStoreDir) != SafeFS.normalized(storeDir) }
    public var legacySnapshotsDir: URL { legacyStoreDir.appendingPathComponent("snapshots", isDirectory: true) }
    public var legacyLockFile: URL { legacyStoreDir.appendingPathComponent("switch.lock") }
    public var legacyJournalFile: URL { legacyStoreDir.appendingPathComponent("swap-journal.json") }
    public var legacyImportMarker: URL { storeDir.appendingPathComponent("legacy-import-done") }
    /// Legacy identity folders already settled (imported, already present, or rejected) while the import is
    /// incomplete, so a retry never brings back a sign-in the user removed in the meantime.
    public var legacyImportHandled: URL { storeDir.appendingPathComponent("legacy-import-handled.json") }
    public var backupsDir: URL { storeDir.appendingPathComponent("backups", isDirectory: true) }
    public var stagingDir: URL { storeDir.appendingPathComponent("staging", isDirectory: true) }
    public var previousDir: URL { storeDir.appendingPathComponent("previous", isDirectory: true) }
    /// Sign-ins that had to be swapped out without a saved snapshot are kept here (never auto-deleted).
    public var displacedDir: URL { storeDir.appendingPathComponent("displaced", isDirectory: true) }
    public var tmpDir: URL { storeDir.appendingPathComponent("tmp", isDirectory: true) }
    public var journalFile: URL { storeDir.appendingPathComponent("swap-journal.json") }
    public var relauncherJournalFile: URL { storeDir.appendingPathComponent("suspended-relaunchers.json") }
    public var lockFile: URL { storeDir.appendingPathComponent("switch.lock") }
    public var settingsFile: URL { storeDir.appendingPathComponent("settings.json") }
    public var settingsLockFile: URL { storeDir.appendingPathComponent("settings.lock") }
    public var accountNamesFile: URL { storeDir.appendingPathComponent("account-names.json") }
    public var accountNamesLockFile: URL { storeDir.appendingPathComponent("account-names.lock") }

    // Codex: each account has its own Codex home; the standard one is ~/.codex.
    public var codexStandardHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    /// Homes this app creates (`<id>/home`, `<id>/app-data`).
    public var codexManagedDir: URL { storeDir.appendingPathComponent("codex", isDirectory: true) }
    /// App data for found homes that have none of their own yet (`<folder name>`).
    public var codexAppDataDir: URL { storeDir.appendingPathComponent("codex-app-data", isDirectory: true) }
    public var codexRegistryFile: URL { storeDir.appendingPathComponent("codex-accounts.json") }
    public var codexRegistryLockFile: URL { storeDir.appendingPathComponent("codex-accounts.lock") }
    /// The command-line tool shipped inside the Codex app (used for sign-in and sign-out).
    public var codexCLI: URL { codexAppURL.appendingPathComponent("Contents/Resources/codex-cli/bin/codex") }
}

/// Names of the Claude userData items that hold the claude.ai sign-in (design D3).
public enum SnapshotItems {
    /// SQLite cookie jar plus every possible sidecar; swapped as one group.
    public static let cookieGroup = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm"]
    public static let config = "config.json"
    /// Optional renderer-state group (off by default in v1).
    public static let uiGroup = ["Local Storage", "Session Storage", "IndexedDB", "WebStorage"]

    /// Extra machine-level files copied (never auto-restored) into the one-time original backup.
    public static let originalBackupExtras = [
        "claude_desktop_config.json", "ccd-session-presets.json", "bridge-state.json",
        "ant-device-registry.json", "mcp-user-tool-toggles.json",
    ]

    /// config.json keys the switcher may touch. Everything else is preserved verbatim.
    public static let lastKnownAccountKey = "lastKnownAccountUuid"
    public static let tokenCacheKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]

    /// Cookie rows that carry the sign-in; removed only when preparing a fresh login (D7).
    public static let authCookieHosts = [".claude.ai", "claude.ai"]
    public static let authCookieNamePrefixes = ["sessionKey", "routingHint", "lastActiveOrg"]
}
