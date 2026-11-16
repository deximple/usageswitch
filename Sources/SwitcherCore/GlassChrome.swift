import Foundation

/// Where Liquid Glass is drawn. Glass belongs to the controls that float over the content — the
/// navigation strip, the bottom action bar, secondary buttons — never to the content itself, and
/// never on top of other glass.
public enum GlassChrome: Equatable, Sendable {
    /// No glass: before macOS 26, with Reduce Transparency, in the menu (a popover is already a
    /// material) and in offscreen snapshots, which cannot render it.
    case none
    /// On an opaque surface of a window: a secondary button carries its own glass.
    case surface
    /// Inside a glass bar: nothing adds a second layer.
    case onGlass

    /// A window's chrome.
    public static func window(glassAvailable: Bool, reduceTransparency: Bool) -> GlassChrome {
        glassAvailable && !reduceTransparency ? .surface : .none
    }

    /// The chrome for what sits inside the bottom action bar.
    public var insideBar: GlassChrome { self == .none ? .none : .onGlass }

    /// Whether the bottom action bar floats over the list as glass instead of being pinned under it.
    public var floatsActionBar: Bool { self != .none }
}

/// How an action button is drawn, as plain data so the rules are checked by tests: the flat look
/// stays exactly as it was wherever there is no glass, and the primary button is never glass.
public struct ActionButtonLook: Equatable, Sendable {
    public enum Background: Equatable, Sendable {
        /// The opaque fill of a primary button; `StatusPalette` holds its label to 4.5:1.
        case fill
        /// A faint wash of the button's own color.
        case wash
        /// The same wash on an opaque plate of the window's color: inside a glass bar the label
        /// must not depend on what scrolls behind it.
        case plate
        /// Liquid Glass.
        case glass

        /// How strongly the button's color is drawn. A pressed fill is not held to 4.5:1.
        public func opacity(hovering: Bool, pressed: Bool) -> Double {
            switch self {
            case .fill: pressed ? 0.78 : hovering ? StatusPalette.hoverOpacity : 1
            case .wash, .plate: hovering ? 0.16 : 0.09
            // The glass is the resting background; the wash only answers the pointer.
            case .glass: hovering ? 0.1 : 0
            }
        }
    }

    public enum Label: Equatable, Sendable {
        /// The label a filled button's pair names.
        case onFill
        /// The button's own color.
        case tint
        /// The body color.
        case ink
    }

    public let background: Background
    public let label: Label
    /// nil is a capsule.
    public let cornerRadius: Double?
    public let fontSize: Double
    public let semibold: Bool
    public let horizontalPadding: Double
    public let verticalPadding: Double

    init(background: Background, label: Label, cornerRadius: Double?, fontSize: Double, semibold: Bool,
         horizontalPadding: Double, verticalPadding: Double) {
        self.background = background
        self.label = label
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.semibold = semibold
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public init(prominent: Bool, small: Bool, chrome: GlassChrome) {
        let background: Background = switch chrome {
        case _ where prominent: .fill
        case .none: .wash
        case .surface: .glass
        case .onGlass: .plate
        }
        // On glass the label is the body color, as on the system's glass controls: a muted or
        // accent label would lose contrast against a backdrop the app does not control.
        let label: Label = prominent ? .onFill : background == .glass ? .ink : .tint
        guard chrome != .none else {
            // The flat look as it was before glass. 6 is the chip radius, 8 the button radius.
            self.init(background: background, label: label, cornerRadius: small ? 6 : 8, fontSize: small ? 11 : 12,
                      semibold: !small, horizontalPadding: small ? 8 : 12, verticalPadding: small ? 3 : 6)
            return
        }
        // Capsules, a step larger: the shape and size of the system's own glass controls. Weight
        // tells the primary action apart, since both kinds share one outline.
        self.init(background: background, label: label, cornerRadius: nil, fontSize: small ? 11 : 13,
                  semibold: prominent && !small, horizontalPadding: small ? 10 : 14,
                  verticalPadding: small ? 4 : 6.5)
    }
}
