import SwiftUI
import SwitcherCore

/// The remaining-share bar: a neutral well with the level's fill in it. The track is always
/// neutral, so an empty bar reads as empty — never as a pale full one.
///
/// Both appearances use the dark fills (the light green a little deeper). In light the fill
/// carries a 1pt border in a deep tone of the same hue, because there the border and not the fill
/// reaches 3:1; dark draws none. A fill narrower than its two borders is all border. The
/// bar looks raised: gradients and thin lines only, never a system material, and nothing the
/// offscreen snapshot draws differently from the window (it inverts inner shadows). A stale bar is
/// flat and grey, and so is every bar under Reduce Transparency or Increase Contrast (the light
/// border stays).
struct UsageBar: View {
    /// Remaining share 0…100; nil draws the empty track.
    let left: Int?
    let role: UsageBarPalette.Role

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private static let height: CGFloat = 6
    private static let rimWidth: CGFloat = 1
    /// How far the gloss and shade lines reach in from the fill's edge.
    private static let lineWidth: CGFloat = 0.9
    private static let emboss = UsageBarPalette.emboss

    private var dark: Bool { scheme == .dark }
    private var embossed: Bool {
        UsageBarPalette.isEmbossed(role, reduceTransparency: reduceTransparency,
                                   increasedContrast: contrast == .increased)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                track
                if let left, left > 0 {
                    fill.frame(width: proxy.size.width * CGFloat(left) / 100)
                }
            }
        }
        .frame(height: Self.height)
    }

    /// A shallow well: shaded inside its top edge, a lip of light along the bottom.
    private var track: some View {
        let emboss = Self.emboss
        return ZStack {
            Capsule().fill(Theme.usageTrack)
            if embossed {
                Capsule().fill(LinearGradient(
                    colors: [.black.opacity(dark ? emboss.wellShade.dark : emboss.wellShade.light), .clear],
                    startPoint: .top, endPoint: .center))
                EdgeLine(offset: -0.5).fill(.white.opacity(dark ? emboss.wellLip.dark : emboss.wellLip.light))
            }
        }
    }

    /// The border sits outside the raised part, so the gloss line never runs over it.
    private var fill: some View {
        let emboss = Self.emboss
        let rim = dark ? nil : Theme.usageRim(role)
        return ZStack {
            if let rim { Capsule().fill(rim) }
            ZStack {
                Capsule().fill(Theme.usageFill(role))
                if embossed {
                    Capsule().fill(LinearGradient(stops: [
                        .init(color: .white.opacity(emboss.highlight), location: 0),
                        .init(color: .white.opacity(0), location: emboss.highlightEnd),
                        .init(color: .black.opacity(emboss.shade), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    EdgeLine(offset: Self.lineWidth).fill(.white.opacity(emboss.glossLine))
                    EdgeLine(offset: -Self.lineWidth).fill(.black.opacity(emboss.shadeLine))
                }
            }
            .padding(rim == nil ? 0 : Self.rimWidth)
        }
    }
}

/// The sliver between a capsule and the same capsule moved down (or, for a negative offset, up):
/// a line of light or shade just inside one edge, following the rounded ends.
private struct EdgeLine: Shape {
    let offset: CGFloat

    func path(in rect: CGRect) -> Path {
        Capsule().path(in: rect).subtracting(Capsule().path(in: rect.offsetBy(dx: 0, dy: offset)))
    }
}
