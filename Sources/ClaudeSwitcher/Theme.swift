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
    static let ready = Color(nsColor: .systemGreen)
    static let relogin = Color(nsColor: .systemOrange)
    static let missing = Color(nsColor: .tertiaryLabelColor)
    static let alias = Color(nsColor: .secondaryLabelColor)
    static let danger = Color(nsColor: .systemRed)

    // Usage gauges: room to run, nearly out, empty (danger/missing reused from state colors)
    static let usageNormal = Color(nsColor: .controlAccentColor)
    static let usageLow = Color(nsColor: .systemOrange)

    // Typography
    static let display = Font.system(size: 22, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    static let eyebrow = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let mono = Font.system(size: 11, design: .monospaced)

    // Rhythm (deliberately uneven: tight inside rows, generous between groups)
    static let gapTight: CGFloat = 4
    static let gapRow: CGFloat = 10
    static let gapGroup: CGFloat = 22
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

/// Primary action button with designed hover/press/focus states.
struct ActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.active
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(prominent ? Color.white : tint)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? tint.opacity(configuration.isPressed ? 0.78 : hovering ? 0.92 : 1) : tint.opacity(hovering ? 0.16 : 0.09)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
