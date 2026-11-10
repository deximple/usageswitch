import Foundation

/// Product identity in one place. The personal 1.0 build ("Claude Switcher", com.jaysong.claude-switcher)
/// keeps its own store; this app's store is named after `defaultBundleID` (never the host bundle's, so the
/// CLI, tests and the app always agree) and the two never share data.
public enum ProductInfo {
    public static let defaultBundleID = "com.jaysong.usageswitch"
    public static let defaultName = "UsageSwitch"
    public static let urlScheme = "usageswitch"
    /// Store of the personal 1.0 build, imported (copied) once on first run.
    public static let legacyBundleID = "com.jaysong.claude-switcher"
    /// Fallback version string when the bundle/build can't report one — keep in sync on release.
    public static let fallbackVersion = "2.0.0"

    /// Published releases. "Check for Updates…" opens this page in the browser; the app itself never goes online.
    public static let releasesURL = URL(string: "https://github.com/deximple/usageswitch/releases/latest")!

    public static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? defaultName
    }
}
