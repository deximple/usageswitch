import Foundation

/// Editing state for an account's display name in the detail window. Pure value —
/// no Codable, no UI. Typing clears restore intent via the setter only; a
/// programmatic Default action never cancels itself.
public struct UsageNameDraft: Equatable, Sendable {
    /// What the account is called when the user has no alias.
    public let defaultName: String
    /// The email shape hidden from display when `showEmails` is off — never a draft value.
    private let maskedPlaceholder: String?
    private let defaultPlaceholder: String
    /// Editable text. Changes go through `edit`, never direct assignment.
    public private(set) var text: String
    /// User pressed Default: the next save returns nil (removes the alias).
    public private(set) var restoreToDefault: Bool
    /// Whether the text differs from the initial seeded state.
    public private(set) var isDirty: Bool

    private let initialText: String
    private let initialName: String
    private let customName: String?

    /// `showEmails == false` with an email-shaped alias or default name starts the
    /// draft EMPTY with a masked placeholder — a masked email is never seeded as a name.
    public init(currentName: String, customName: String?, defaultName: String, showEmails: Bool) {
        self.defaultName = defaultName
        defaultPlaceholder = showEmails ? defaultName : Privacy.maskEmails(in: defaultName)
        initialName = currentName
        self.customName = customName
        restoreToDefault = false
        isDirty = false
        let hidesEmail = !showEmails && Privacy.maskEmails(in: currentName) != currentName
        if hidesEmail {
            maskedPlaceholder = Privacy.maskEmails(in: currentName)
            initialText = ""
        } else {
            maskedPlaceholder = nil
            initialText = currentName
        }
        text = initialText
    }

    /// Placeholder for the empty field — masked, never a real email.
    public var placeholder: String? { restoreToDefault ? defaultPlaceholder : maskedPlaceholder }

    /// Text-field set side: any edit marks dirty and clears restore intent.
    public mutating func edit(_ value: String) {
        text = value
        isDirty = value != initialText
        restoreToDefault = false
    }

    /// The Default action: explicit intent to restore. Disabled callers check `canRestore`.
    public mutating func restoreDefault() {
        guard canRestore else { return }
        restoreToDefault = true
        text = ""
        isDirty = true
    }

    /// Default is only meaningful when an alias exists to remove.
    public var canRestore: Bool { customName != nil }

    /// True only when the draft is a VALID name and a real change.
    public var canSave: Bool {
        if restoreToDefault { return customName != nil }
        guard !text.isEmpty, isDirty else { return false }
        guard let valid = try? AccountNames.validated(text) else { return false }
        return valid != initialName
    }

    /// nil only for the explicit Default restore; everything else throws through
    /// `AccountNames.validated` — a blank draft is INVALID, never a silent restore.
    public func saveValue() throws -> String? {
        if restoreToDefault { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwitcherError.invalidAccountName(maxLength: AccountNames.maxLength) }
        return try AccountNames.validated(text)
    }
}
