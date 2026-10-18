/// The short account name next to the menu bar icon.
public enum MenuBarTitle {
    public static let limit = 14

    /// nil when the name is turned off. Emails are masked (the bar is visible when sharing screens) unless the user
    /// chose to always show them; long names end in "…".
    public static func make(label: String?, showsName: Bool, showEmails: Bool) -> String? {
        guard showsName, let label else { return nil }
        let shown = showEmails ? label : Privacy.maskEmails(in: label)
        return shown.count > limit ? String(shown.prefix(limit - 1)) + "…" : shown
    }
}
