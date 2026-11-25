/// Whether the app may quit now — asked when the user quits and when Sparkle wants to relaunch it
/// to install an update. A switch or recovery under way, or a Codex action other than a sign-in,
/// waits for the user: quitting mid-way could leave files half swapped or an action half done.
/// A Codex sign-in is simply cancelled. A demo (`--ui-fixture`) changes nothing on disk, so it
/// always quits — a `--snapshot` of a busy screen ends instead of leaving a window up.
public enum QuitPolicy {
    public enum Decision: Equatable, Sendable {
        case now
        case waitForSwitch
        case waitForCodex

        public var waits: Bool { self != .now }
    }

    public static func decide(switcherBusy: Bool, switcherDemo: Bool, codexBusy: Bool,
                              codexSigningIn: Bool, codexDemo: Bool) -> Decision {
        if switcherBusy && !switcherDemo { return .waitForSwitch }
        if codexBusy && !codexSigningIn && !codexDemo { return .waitForCodex }
        return .now
    }
}
