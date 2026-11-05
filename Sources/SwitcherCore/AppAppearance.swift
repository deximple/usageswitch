/// The app's appearance choice. `system` maps to `NSApp.appearance = nil` so the app follows
/// the OS setting live instead of capturing a constant.
public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    /// Priority: a recognized temporary `--appearance light|dark` launch override beats the saved
    /// choice; anything else (nil or unknown) falls through to the choice.
    public static func resolve(override: String?, choice: AppAppearance) -> AppAppearance {
        switch override {
        case "light": return .light
        case "dark": return .dark
        default: return choice
        }
    }
}
