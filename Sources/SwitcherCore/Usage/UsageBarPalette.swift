import Foundation

/// One color as an sRGB hex pair: the value for the light appearance and the one for dark.
public struct UsageBarTint: Equatable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}

/// The remaining-share bar's colors as plain data, so the contrast rule is checked by tests
/// instead of by eye. A bar is filled in its vendor's logo color; a warning or used-up window
/// overrides that, and a stale one is always grey. Views read these through `Theme` only.
public enum UsageBarPalette {
    /// What decides a bar's fill, strongest first.
    public enum Role: Equatable, Sendable { case stale, exhausted, warning, vendor }

    /// WCAG 2.x non-text contrast (SC 1.4.11) every fill must reach against `canvas` and `track`.
    public static let minimumContrast = 3.0

    /// The window background the rows sit on (`NSColor.windowBackgroundColor`, measured).
    public static let canvas = UsageBarTint(light: 0xEBEBEB, dark: 0x323232)
    /// The unfilled part of a bar: a well slightly darker than the canvas in both appearances.
    public static let track = UsageBarTint(light: 0xDCDCDC, dark: 0x202020)

    /// Running low. Light is a deep gold rather than system orange (1.8:1 on the canvas), kept
    /// on the yellow side so it never reads as Claude's clay.
    public static let warning = UsageBarTint(light: 0x9E7200, dark: 0xFF9F0A)
    /// Used up. The bar itself is empty at 0%; this colors its marker.
    public static let exhausted = UsageBarTint(light: 0xD70015, dark: 0xFF453A)

    /// Vendors whose logo is black on white (or the reverse): near-black on light, near-white on dark.
    public static let monochrome = UsageBarTint(light: 0x1F1F1F, dark: 0xEDEDED)

    /// The vendor's logo color, adjusted per appearance only as far as 3:1 needs.
    public static func tint(for provider: UsageProvider) -> UsageBarTint {
        switch provider {
        // Anthropic clay: the logo's #D97757 on dark, its deeper brand tone on light.
        case .claude: UsageBarTint(light: 0xC15F3C, dark: 0xD97757)
        // Google blues: the Gemini spark and the Antigravity arc.
        case .gemini: UsageBarTint(light: 0x1A73E8, dark: 0x3186FF)
        case .antigravity: UsageBarTint(light: 0x1967D2, dark: 0x4285F4)
        // OpenAI, Cursor, xAI, Cognition, OpenCode and GitHub all ship a black-and-white mark.
        case .codex, .cursor, .grok, .devin, .opencode, .copilot: monochrome
        }
    }

    /// Stale beats everything (the number isn't current), then used up, then the warning level.
    public static func role(usedPercent: Double, warnAt: Double, stale: Bool) -> Role {
        if stale { return .stale }
        if usedPercent >= 100 { return .exhausted }
        return usedPercent >= warnAt ? .warning : .vendor
    }

    /// WCAG relative luminance of an sRGB hex color, 0 (black) … 1 (white).
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG contrast ratio between two sRGB hex colors, 1 … 21, order-independent.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
