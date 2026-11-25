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

/// The remaining-share bar's levels and colors as plain data, so the rules are checked by tests
/// instead of by eye. A bar is filled by how much is left — ample, warning, critical — is empty when
/// used up, and a stale one is always grey. Views read these through `Theme` only.
public enum UsageBarPalette {
    /// What a bar shows: a stale reading first, then the four levels from empty to plenty.
    public enum Role: Equatable, Sendable, CaseIterable {
        case stale, exhausted, critical, warning, ample

        /// The SF Symbol beside the number. Each level below ample has a shape of its own — a
        /// triangle, a filled octagon, a ring with a slash — so it never rides on color alone.
        public var symbol: String? {
            switch self {
            case .stale, .ample: nil
            case .warning: "exclamationmark.triangle.fill"
            case .critical: "exclamationmark.octagon.fill"
            case .exhausted: "nosign"
            }
        }

        /// How bad a level is, for comparing two of them; a stale bar has none.
        fileprivate var severity: Int? {
            switch self {
            case .stale: nil
            case .ample: 0
            case .warning: 1
            case .critical: 2
            case .exhausted: 3
            }
        }
    }

    /// One level's colors. Both appearances use the dark appearance's fill (the light green is a
    /// little deeper); on the light window those fills reach only 1.3–2.9:1, so a 1pt border in a
    /// deep tone of the same hue carries the contrast there.
    public struct Look: Equatable, Sendable {
        public let fill: UsageBarTint
        /// The 1pt border around the fill in light. Dark draws none: the fill itself reads.
        public let rim: UInt32

        public init(fill: UsageBarTint, rim: UInt32) {
            self.fill = fill
            self.rim = rim
        }

        /// The glyph beside the number: the border's tone in light, the fill in dark.
        public var marker: UsageBarTint { UsageBarTint(light: rim, dark: fill.dark) }
    }

    /// The raised look of a bar, drawn with gradients and inner lines (never a system material):
    /// white fading out from the top of the fill, a thin gloss line under its top edge, a faint
    /// shade along the bottom, and a track that reads as a shallow well. All opacities.
    public struct Emboss: Equatable, Sendable {
        /// One opacity per appearance.
        public struct Opacity: Equatable, Sendable {
            public let light: Double
            public let dark: Double
        }

        /// White at the top of the fill, fading to nothing at `highlightEnd` of its height.
        public let highlight: Double
        public let highlightEnd: Double
        /// Black at the bottom of the fill.
        public let shade: Double
        /// The gloss line under the fill's top edge and the shade line above its bottom edge.
        public let glossLine: Double
        public let shadeLine: Double
        /// The shadow inside the top of the track, and the lip of light along its bottom.
        public let wellShade: Opacity
        public let wellLip: Opacity
    }

    /// WCAG 2.x non-text contrast (SC 1.4.11) a bar must reach against `canvas` and `track`: with
    /// its border in light, with its fill in dark.
    public static let minimumContrast = 3.0

    /// The window background the rows sit on (`NSColor.windowBackgroundColor`, measured).
    public static let canvas = UsageBarTint(light: 0xEBEBEB, dark: 0x323232)
    /// The unfilled part of a bar: a well slightly darker than the canvas in both appearances.
    public static let track = UsageBarTint(light: 0xDCDCDC, dark: 0x202020)

    /// Above the warning line.
    public static let ample = Look(fill: UsageBarTint(light: 0x00DB7E, dark: 0x1CFF96), rim: 0x00904F)
    /// From the warning line down.
    public static let warning = Look(fill: UsageBarTint(light: 0xFF9F0A, dark: 0xFF9F0A), rim: 0x7C5A00)
    /// Nearly empty. A used-up bar draws no fill; its marker takes this look's color.
    public static let critical = Look(fill: UsageBarTint(light: 0xFF453A, dark: 0xFF453A), rim: 0x89021E)

    /// The shade values are as strong as the dark red allows: its darkest edge still reaches 3:1.
    public static let emboss = Emboss(
        highlight: 0.38, highlightEnd: 0.55, shade: 0.05, glossLine: 0.55, shadeLine: 0.06,
        wellShade: Emboss.Opacity(light: 0.14, dark: 0.55),
        wellLip: Emboss.Opacity(light: 0.55, dark: 0.06))

    /// Whether a bar is drawn raised. A stale bar never is, and under Reduce Transparency or
    /// Increase Contrast every bar is flat (the light border stays).
    public static func isEmbossed(_ role: Role, reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        role != .stale && !reduceTransparency && !increasedContrast
    }

    /// The colors a role is drawn in; nil for stale, which is the system's tertiary label color.
    public static func look(for role: Role) -> Look? {
        switch role {
        case .stale: nil
        case .ample: ample
        case .warning: warning
        case .critical, .exhausted: critical
        }
    }

    /// How far above a line the remaining share has to climb before a level eases, in points.
    public static let recovery = 2.0

    /// The remaining share where the warning level starts: the "warn at" setting, turned around.
    public static func warningLine(warnAt: Double) -> Double { 100 - warnAt }

    /// The remaining share where the critical level starts: 10%, or half the warning line when
    /// that is lower (5% under a 10% warning line).
    public static func criticalLine(warnAt: Double) -> Double { min(10, warningLine(warnAt: warnAt) / 2) }

    /// The level a bar shows. Stale beats everything (the number isn't current). The rest follows
    /// the whole percent the row shows, so the number, the color and the glyph share one line:
    /// 0% is used up, then critical, then warning. Getting worse shows at once; a level `previous`
    /// had reached eases only once the remaining share is `recovery` points above its line.
    public static func role(usedPercent: Double, warnAt: Double, stale: Bool, previous: Role? = nil) -> Role {
        guard !stale, let left = UsageText.percentLeft(usedPercent) else { return .stale }
        if left == 0 { return .exhausted }
        let held = previous?.severity ?? 0
        func reaches(_ line: Double, _ level: Role) -> Bool {
            let holding = held >= (level.severity ?? 0)
            return holding ? Double(left) < line + recovery : Double(left) <= line
        }
        if reaches(criticalLine(warnAt: warnAt), .critical) { return .critical }
        if reaches(warningLine(warnAt: warnAt), .warning) { return .warning }
        return .ample
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
