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
    static let ready = Color(nsColor: .systemGreen)
    static let relogin = Color(nsColor: .systemOrange)
    static let missing = Color(nsColor: .tertiaryLabelColor)
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

    /// A color that follows the view's light/dark appearance, from an sRGB hex pair.
    private static func adaptive(_ tint: UsageBarTint) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = dark ? tint.dark : tint.light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
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

    static func color(for state: SnapshotState, active: Bool) -> Color {
        if active { return Theme.active }
        switch state {
        case .ready: return Theme.ready
        case .expired: return Theme.relogin
        case .corrupt: return Theme.danger
        }
    }

    static func label(for state: SnapshotState, active: Bool) -> String {
        if active { return L10n.t(.uiStateActive) }
        switch state {
        case .ready: return L10n.t(.uiStateReady)
        case .expired: return L10n.t(.uiStateExpired)
        case .corrupt: return L10n.t(.uiStateCorrupt)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? Color.white : color)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                    .fill(filled ? color : color.opacity(0.13)))
            .accessibilityLabel(text)
    }
}

/// Primary action button with designed hover/press/focus states. `small` is the quiet
/// in-row size (Details): same states, 11pt, the control radius.
struct ActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.active
    var prominent = true
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, tint: tint, prominent: prominent, small: small)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        let small: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let radius: CGFloat = small ? Theme.radiusChip : 8
            configuration.label
                .font(.system(size: small ? 11 : 12, weight: small ? .medium : .semibold))
                .padding(.horizontal, small ? 8 : 12)
                .padding(.vertical, small ? 3 : 6)
                .foregroundStyle(prominent ? Color.white : tint)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(prominent ? tint.opacity(configuration.isPressed ? 0.78 : hovering ? 0.92 : 1) : tint.opacity(hovering ? 0.16 : 0.09)))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(focused ? tint : .clear, lineWidth: 2)
                        .padding(-3))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
