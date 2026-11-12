import Foundation

/// Whether the bundled Sparkle updater may start. Pure decision over the values the
/// app bundle ships: until a feed URL and EdDSA public key are both present (and the
/// run isn't a demo), the updater stays inert — no network, no XPC services, nothing.
public enum UpdaterLaunchPolicy {
    public enum Decision: Equatable, Sendable {
        case enabled
        case disabledDemo
        case disabledMissingFeedURL
        case disabledInvalidFeedURL
        case disabledMissingPublicKey
        case disabledInvalidPublicKey
    }

    /// `feedURLString`/`publicEDKey` are the raw Info.plist `SUFeedURL`/`SUPublicEDKey`
    /// values. The feed must be HTTPS; the key must decode as a 32-byte EdDSA key
    /// (Sparkle's `SUPublicEDKey` format is base64 of the raw key).
    public static func decide(feedURLString: String?, publicEDKey: String?,
                              isDemo: Bool) -> Decision {
        if isDemo { return .disabledDemo }
        guard let feedURLString, !feedURLString.isEmpty else { return .disabledMissingFeedURL }
        guard let url = URL(string: feedURLString), url.scheme == "https",
              url.host != nil else { return .disabledInvalidFeedURL }
        guard let publicEDKey, !publicEDKey.isEmpty else { return .disabledMissingPublicKey }
        guard let decoded = Data(base64Encoded: publicEDKey), decoded.count == 32
        else { return .disabledInvalidPublicKey }
        return .enabled
    }
}
