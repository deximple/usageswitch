import SwiftUI
import SwitcherCore

/// Design tokens. Direction: system language — semantic colors and SF Pro throughout so light and
/// dark come from the OS instead of a hand-tuned pair; SF Mono for identifiers.
enum Theme {
    // Surfaces
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let ink = Color(nsColor: .labelColor)
    static let inkMuted = Color(nsColor: .secondaryLabelColor)

    // Semantic state colors
    static let active = Color(nsColor: .controlAccentColor)
    static let environmentActive = Color(nsColor: .systemBlue)
    static let ready = adaptive(StatusPalette.ready)
    static let relogin = Color(nsColor: .systemOrange)
    static let alias = Color(nsColor: .secondaryLabelColor)
    static let danger = Color(nsColor: .systemRed)

    // Usage bars. The fill is the vendor's logo color; a warning or used-up window overrides it
    // and a stale reading is grey. The hex pairs live in SwitcherCore's `UsageBarPalette`, where
    // tests hold every fill to 3:1 against the canvas and the track in light and dark.
    static let usageTrack = adaptive(UsageBarPalette.track)
    static let usageWarn = adaptive(UsageBarPalette.warning)
    static let usageExhausted = adaptive(UsageBarPalette.exhausted)
    static let usageStale = Color(nsColor: .tertiaryLabelColor)
    private static let vendorFills = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map {
        ($0, adaptive(UsageBarPalette.tint(for: $0)))
    })

    /// The vendor's logo color, readable in both appearances (black-and-white logos flip).
    static func vendor(_ provider: UsageProvider) -> Color { vendorFills[provider] ?? ink }

    static func usageFill(_ role: UsageBarPalette.Role, provider: UsageProvider) -> Color {
        switch role {
        case .stale: usageStale
        case .exhausted: usageExhausted
        case .warning: usageWarn
        case .vendor: vendor(provider)
        }
    }

    // State chips. The text is always `ink`; the marker beside it carries the color. The hex pairs
    // live in SwitcherCore's `StatusPalette`, where tests hold each marker to 3:1 on the well.
    static let chipWell = adaptive(StatusPalette.chipWell)

    /// The current marker follows the user's accent color; the others are fixed.
    static func marker(_ marker: StatusMarker) -> Color {
        StatusPalette.tint(for: marker).map(adaptive) ?? active
    }

    // The primary button. Its fill is the user's accent color with the brightness moved until the
    // label reads on it at 4.5:1 (`StatusPalette.accentFill`); the hue stays theirs.
    static let onFill = adaptive(StatusPalette.labelOnFill)
    static let accentFill = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var accent: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        guard let accent else { return .controlAccentColor }
        let channels = [accent.redComponent, accent.greenComponent, accent.blueComponent]
        let hex = channels.reduce(UInt32(0)) { $0 << 8 | UInt32((min(max($1, 0), 1) * 255).rounded()) }
        return nsColor(StatusPalette.accentFill(hex, dark: dark))
    })

    /// A color that follows the view's light/dark appearance, from an sRGB hex pair.
    fileprivate static func adaptive(_ tint: UsageBarTint) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(dark ? tint.dark : tint.light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Typography
    static let display = Font.system(size: 22, weight: .semibold)
    static let title = Font.system(size: 14, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    static let eyebrow = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    /// The smallest text size: metadata, badges, secondary actions. Nothing goes below it.
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 11, design: .monospaced)

    // Rhythm (deliberately uneven: tight inside rows, generous between groups)
    static let gapTight: CGFloat = 4
    static let gapRow: CGFloat = 12
    static let gapGroup: CGFloat = 24
    static let radiusCard: CGFloat = 14
    static let radiusChip: CGFloat = 6

    static func label(for state: SnapshotState, active: Bool) -> String {
        if active { return L10n.t(.uiStateActive) }
        switch state {
        case .ready: return L10n.t(.uiStateReady)
        case .expired: return L10n.t(.uiStateExpired)
        case .corrupt: return L10n.t(.uiStateCorrupt)
        }
    }
}

/// A state label that never rides on color alone: the marker carries the color and a glyph of
/// its own, the text stays at full reading contrast.
struct Chip: View {
    let text: String
    var marker: StatusMarker? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let marker {
                Image(systemName: marker.symbol).foregroundStyle(Theme.marker(marker))
                    .accessibilityHidden(true)
            }
            Text(text).foregroundStyle(Theme.ink)
                .accessibilityLabel(text)
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                .fill(Theme.chipWell))
    }
}

/// Primary action button with designed hover/press/focus states. `small` is the quiet
/// in-row size (Details): same states, 11pt, the control radius. Its shape, size and background
/// come from `ActionButtonLook`, which also decides where a secondary button is glass.
struct ActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.accentFill
    /// The text on a filled button.
    var label: Color = Theme.onFill
    var prominent = true
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, tint: tint, label: label, prominent: prominent, small: small)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let tint: Color
        let label: Color
        let prominent: Bool
        let small: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.glassChrome) private var chrome

        var body: some View {
            let look = ActionButtonLook(prominent: prominent, small: small, chrome: chrome)
            if let radius = look.cornerRadius {
                styled(look, RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                styled(look, Capsule(style: .continuous))
            }
        }

        private func styled(_ look: ActionButtonLook, _ shape: some InsettableShape) -> some View {
            configuration.label
                .font(.system(size: look.fontSize, weight: look.semibold ? .semibold : .medium))
                .padding(.horizontal, look.horizontalPadding)
                .padding(.vertical, look.verticalPadding)
                .foregroundStyle(labelColor(look.label))
                .background(shape.fill(tint.opacity(
                    look.background.opacity(hovering: hovering, pressed: configuration.isPressed))))
                .background(shape.fill(look.background == .plate ? Theme.canvas : .clear))
                .modifier(GlassBackdrop(shape: shape, enabled: look.background == .glass))
                .overlay(shape.strokeBorder(focused ? tint : .clear, lineWidth: 2).padding(-3))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private func labelColor(_ kind: ActionButtonLook.Label) -> Color {
            switch kind {
            case .onFill: label
            case .tint: tint
            case .ink: Theme.ink
            }
        }
    }
}

extension ActionButtonStyle {
    /// A filled button in a fixed fill and label: `StatusPalette` holds each pair to 4.5:1.
    init(filled pair: StatusPalette.FilledButton) {
        self.init(tint: Theme.adaptive(pair.fill), label: Theme.adaptive(pair.label))
    }
}
