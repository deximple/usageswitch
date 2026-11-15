import SwiftUI
import SwitcherCore

// A key written out rather than `@Entry`: the Command Line Tools, which stand in for CI's compiler,
// ship without the SwiftUI macro plugin.
private struct GlassChromeKey: EnvironmentKey {
    static let defaultValue = GlassChrome.none
}

extension EnvironmentValues {
    /// Where glass is drawn around a view. `.none` until a window opts in, so the menu stays flat.
    var glassChrome: GlassChrome {
        get { self[GlassChromeKey.self] }
        set { self[GlassChromeKey.self] = newValue }
    }
}

/// Opts a window into glass chrome: macOS 26 and later, unless the user asked for reduced
/// transparency. An offscreen snapshot stays flat — `cacheDisplay` does not draw glass, and a
/// secondary button would come out as bare text.
struct WindowGlassChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.environment(\.glassChrome, GlassChrome.window(
            glassAvailable: Self.glassAvailable && LaunchOptions.snapshot == nil,
            reduceTransparency: reduceTransparency))
    }

    private static var glassAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}

/// A scrolling list with its action bar. Without glass the bar is pinned under a hairline; with
/// glass chrome it floats over the list as a capsule and the list scrolls beneath it. The Usage
/// tab's footer is not one of these: small status text does not read over a moving list.
///
/// The two arrangements are different view trees, so switching Reduce Transparency while the window
/// is open rebuilds the list and returns it to the top.
struct ActionBarLayout<List: View, Bar: View>: View {
    @ViewBuilder let list: List
    @ViewBuilder let bar: Bar
    @Environment(\.glassChrome) private var chrome

    var body: some View {
        if chrome.floatsActionBar, #available(macOS 26, *) {
            list.safeAreaInset(edge: .bottom, spacing: 0) {
                bar.environment(\.glassChrome, chrome.insideBar)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        } else {
            VStack(spacing: 0) {
                list
                Divider()
                bar.padding(.horizontal, Theme.gapGroup)
                    .padding(.vertical, 12)
                    .background(Theme.surface.opacity(0.6))
            }
        }
    }
}

/// Liquid Glass behind a control, where its look asks for it.
struct GlassBackdrop<S: Shape>: ViewModifier {
    let shape: S
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, #available(macOS 26, *) {
            // A resting glass button has no fill of its own. Naming the shape as the click target
            // keeps the padding around the label clickable by contract, not by how glass hit-tests.
            content.contentShape(shape).glassEffect(.regular.interactive(), in: shape)
        } else {
            content
        }
    }
}
