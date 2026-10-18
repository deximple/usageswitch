import SwiftUI
import SwitcherCore

/// Design tokens. Direction: editorial utility — New York serif for identity, SF Pro for UI text,
/// SF Mono for identifiers; warm paper surfaces; color carries state meaning only.
enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Surfaces
    static let canvas = dynamic(rgb(0xF6F2EA), rgb(0x1B1916))
    static let surface = dynamic(rgb(0xFFFDF8), rgb(0x24211D))
    static let surfaceRaised = dynamic(rgb(0xFFFFFF), rgb(0x2D2924))
    static let hairline = dynamic(rgb(0xE4DCCD), rgb(0x3A352E))
    static let ink = dynamic(rgb(0x2A241D), rgb(0xF1EBE0))
    static let inkMuted = dynamic(rgb(0x7A6F62), rgb(0xA79D8F))

    // Semantic state colors
    static let active = dynamic(rgb(0xC15F3C), rgb(0xE58A62))
    static let ready = dynamic(rgb(0x3F7653), rgb(0x7DBE8F))
    static let relogin = dynamic(rgb(0xA86A12), rgb(0xE7AE52))
    static let missing = dynamic(rgb(0x8A8174), rgb(0x8E857A))
    static let alias = dynamic(rgb(0x4F55B8), rgb(0x9CA1F0))
    static let danger = dynamic(rgb(0xA63A2B), rgb(0xF08371))

    // Typography
    static let display = Font.system(size: 30, weight: .semibold, design: .serif)
    static let rowTitle = Font.system(size: 19, weight: .semibold, design: .serif)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold).smallCaps()
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
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
