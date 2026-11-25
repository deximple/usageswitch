import Foundation

/// The marker an account-state chip carries beside its text. The text stays at body contrast and
/// the marker carries the color; each state has its own glyph, so two states that share a button
/// (an expired and a damaged saved sign-in) are told apart without color.
public enum StatusMarker: CaseIterable, Equatable, Sendable {
    case current, ready, attention, damaged

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .current: "circle.fill"
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .damaged: "xmark.octagon.fill"
        }
    }

    public static func claude(_ snapshot: SnapshotState, active: Bool) -> StatusMarker {
        if active { return .current }
        switch snapshot {
        case .ready: return .ready
        case .expired: return .attention
        case .corrupt: return .damaged
        }
    }

    public static func codex(_ state: CodexAccount.State) -> StatusMarker {
        switch state {
        case .running: .current
        case .signedIn: .ready
        case .signedOut: .attention
        }
    }
}

/// Marker and filled-button colors as plain data, so the contrast rules are checked by tests
/// instead of by eye. Views read these through `Theme` only.
public enum StatusPalette {
    /// A filled button: its fill and the label drawn on it.
    public struct FilledButton: Equatable, Sendable {
        public let fill: UsageBarTint
        public let label: UsageBarTint

        public init(fill: UsageBarTint, label: UsageBarTint) {
            self.fill = fill
            self.label = label
        }
    }

    /// WCAG 2.x text contrast (SC 1.4.3) a filled button's label must reach on its fill.
    public static let minimumTextContrast = 4.5
    /// How far a filled button's fill fades while the pointer is over it.
    public static let hoverOpacity = 0.92

    /// A state chip's background: a step off the canvas, darker in light and lighter in dark, so
    /// the chip also shows on the header card.
    public static let chipWell = UsageBarTint(light: 0xDCDCDC, dark: 0x3C3C3C)
    /// The header card (`NSColor.controlBackgroundColor`, measured).
    public static let surface = UsageBarTint(light: 0xFFFFFF, dark: 0x1E1E1E)

    /// Ready to use. Light is deeper than system green (1.9:1 on the canvas) so it also carries a
    /// white label; dark is system green.
    public static let ready = UsageBarTint(light: 0x197A33, dark: 0x30D158)

    /// The marker's color; nil for `.current`, which follows the user's accent color.
    public static func tint(for marker: StatusMarker) -> UsageBarTint? {
        switch marker {
        case .current: nil
        case .ready: ready
        case .attention: UsageBarPalette.warning
        case .damaged: UsageBarPalette.exhausted
        }
    }

    /// The text on a filled button: white on a deep fill in light, near-black on a bright one in dark.
    public static let labelOnFill = UsageBarTint(light: 0xFFFFFF, dark: 0x1F1F1F)

    /// The user's accent color as the primary button's fill. The hue stays; the fill moves toward
    /// black (light) or white (dark) only as far as `labelOnFill` needs to reach
    /// `minimumTextContrast` on it, at rest and while hovered on the canvas or the header card.
    public static func accentFill(_ accent: UInt32, dark: Bool) -> UInt32 {
        let label = dark ? labelOnFill.dark : labelOnFill.light
        let backdrops = [UsageBarPalette.canvas, surface].map { dark ? $0.dark : $0.light }
        func carriesLabel(_ fill: UInt32) -> Bool {
            ([fill] + backdrops.map { blend(fill, over: $0, opacity: hoverOpacity) })
                .allSatisfy { UsageBarPalette.contrast(label, $0) >= minimumTextContrast }
        }
        let end: UInt32 = dark ? 0xFFFFFF : 0x000000
        return (0...100).lazy.map { blend(end, over: accent, opacity: Double($0) / 100) }
            .first(where: carriesLabel) ?? end
    }

    /// Saving the sign-in that was just made.
    public static let confirmButton = FilledButton(fill: ready, label: labelOnFill)
    /// A primary action with no state of its own.
    public static let neutralButton = FilledButton(fill: UsageBarTint(light: 0x505050, dark: 0xD0D0D0),
                                                   label: labelOnFill)

    // MARK: - Quiet buttons, the current marker and the environment dot

    /// The environment badge's tint behind its text.
    public static let environmentWashOpacity = 0.12
    /// The current account's row: a faint wash of the accent color.
    public static let currentRowOpacity = 0.10

    /// What a quiet button or a marker can sit on: the canvas, a chip well (as dark as the tinted
    /// cards get) and the header card.
    private static func backdrops(dark: Bool) -> [UInt32] {
        [UsageBarPalette.canvas, chipWell, surface].map { dark ? $0.dark : $0.light }
    }

    /// The washes a quiet button draws of its own color: at rest, hovered, and the environment badge's.
    private static let quietWashes: [Double] = [
        ActionButtonLook.Background.wash.opacity(hovering: false, pressed: false),
        ActionButtonLook.Background.wash.opacity(hovering: true, pressed: false),
        environmentWashOpacity,
    ]

    /// `color` moved toward black (light) or white (dark), 1% at a time, to the first step `reads`
    /// accepts. The hue stays; a color that already reads is left alone.
    private static func deepened(_ color: UInt32, dark: Bool, until reads: (UInt32) -> Bool) -> UInt32 {
        let end: UInt32 = dark ? 0xFFFFFF : 0x000000
        return (0...100).lazy.map { blend(end, over: color, opacity: Double($0) / 100) }
            .first(where: reads) ?? end
    }

    /// The label of a quiet button in `tint`: drawn over a wash of itself, it reaches
    /// `minimumTextContrast` at rest and hovered, on every backdrop.
    public static func quietLabel(_ tint: UInt32, dark: Bool) -> UInt32 {
        deepened(tint, dark: dark) { label in
            backdrops(dark: dark).allSatisfy { backdrop in
                quietWashes.allSatisfy {
                    UsageBarPalette.contrast(label, blend(label, over: backdrop, opacity: $0)) >= minimumTextContrast
                }
            }
        }
    }

    /// The grey of a quiet button with no color of its own (Details, Hide, Cancel, Sign in again).
    /// The system's secondary label reaches only 3.6–3.9:1 on its own wash in light.
    public static let quietMuted = UsageBarTint(light: 0x535353, dark: 0xC5C5C5)

    /// The current marker in the user's accent color: moved only as far as it needs to reach 3:1 on
    /// every backdrop and on the current row, which is washed with the raw accent.
    public static func currentMarker(_ accent: UInt32, dark: Bool) -> UInt32 {
        let canvas = dark ? UsageBarPalette.canvas.dark : UsageBarPalette.canvas.light
        let row = blend(accent, over: canvas, opacity: currentRowOpacity)
        return deepened(accent, dark: dark) { marker in
            (backdrops(dark: dark) + [row]).allSatisfy {
                UsageBarPalette.contrast(marker, $0) >= UsageBarPalette.minimumContrast
            }
        }
    }

    /// The dot on a confirmed environment's badge: system blue, deepened in light until it reaches
    /// 3:1 on its own badge tint.
    public static let environmentMarker = UsageBarTint(light: 0x0070D1, dark: 0x0091FF)

    /// `top` drawn at `opacity` over `bottom`, as sRGB hex.
    public static func blend(_ top: UInt32, over bottom: UInt32, opacity: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let mixed = Double((top >> shift) & 0xFF) * opacity + Double((bottom >> shift) & 0xFF) * (1 - opacity)
            return UInt32(mixed.rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
