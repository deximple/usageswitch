import AppKit

/// How a string sits in a fixed-width cell, measured the way SwiftUI lays out a one-line `Text`.
enum TextFit: Equatable, CustomStringConvertible {
    /// Fits at the design size.
    case fits
    /// Too wide at the design size; `minimumScaleFactor` shrinks it to this share of the size.
    case shrinks(to: Double)
    /// Too wide even at the smallest allowed size: the view cuts it off with an ellipsis.
    case truncates

    var description: String {
        switch self {
        case .fits: return "fits"
        case .shrinks(let scale): return "shrinks to \(Int((scale * 100).rounded()))%"
        case .truncates: return "truncates"
        }
    }
}

/// A system font as the views ask for it: `Font.system(size:weight:)`, optionally `.monospacedDigit()`.
struct TextStyle: Sendable {
    enum Weight: Sendable { case regular, medium, semibold }

    let size: Double
    var weight: Weight = .regular
    var monospacedDigits = false

    private var font: NSFont {
        let weight: NSFont.Weight = switch self.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        return monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                                : .systemFont(ofSize: size, weight: weight)
    }

    /// Width of `text` on one line, in points.
    func width(of text: String) -> Double {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// Width of an SF Symbol drawn at this font, as `Image(systemName:).font(…)` lays it out.
    func width(ofSymbol name: String) -> Double? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration).map { Double($0.size.width) }
    }
}

/// A fixed-width text cell: a one-line `Text` inside `.frame(width:)`.
struct TextSlot: Sendable {
    let width: Double
    let style: TextStyle
    /// The view's `minimumScaleFactor`; 1 means the text never shrinks.
    var minimumScale: Double = 1

    func fit(_ text: String) -> TextFit {
        let natural = style.width(of: text)
        if natural <= width { return .fits }
        let scale = width / natural
        return scale >= minimumScale ? .shrinks(to: scale) : .truncates
    }

    /// "'Mensualmente' is 91.2pt, the cell is 84pt (shrinks to 92%)" — the line a failing test prints.
    func describe(_ text: String) -> String {
        let natural = (style.width(of: text) * 10).rounded() / 10
        return "'\(text)' is \(natural)pt, the cell is \(Int(width))pt (\(fit(text)))"
    }
}
