import Foundation
import Testing
@testable import SwitcherCore

@Suite("Glass chrome and the action button's look")
struct GlassChromeTests {
    private let chromes: [GlassChrome] = [.none, .surface, .onGlass]
    private let kinds: [(prominent: Bool, small: Bool)] =
        [(true, false), (true, true), (false, false), (false, true)]

    @Test("a window gets glass only on macOS 26 and later, and never with Reduce Transparency")
    func windowChrome() {
        #expect(GlassChrome.window(glassAvailable: true, reduceTransparency: false) == .surface)
        #expect(GlassChrome.window(glassAvailable: true, reduceTransparency: true) == .none)
        #expect(GlassChrome.window(glassAvailable: false, reduceTransparency: false) == .none)
        #expect(GlassChrome.window(glassAvailable: false, reduceTransparency: true) == .none)
    }

    @Test func whatSitsInAGlassBarIsOnGlass() {
        #expect(GlassChrome.surface.insideBar == .onGlass)
        #expect(GlassChrome.onGlass.insideBar == .onGlass)
        // Without glass there is no glass bar either.
        #expect(GlassChrome.none.insideBar == .none)
    }

    @Test func theActionBarFloatsOnlyWithGlass() {
        #expect(!GlassChrome.none.floatsActionBar)
        #expect(GlassChrome.surface.floatsActionBar)
    }

    /// macOS 15, Reduce Transparency and the menu keep the look they had before glass.
    @Test func withoutGlassTheButtonKeepsItsFlatLook() {
        #expect(ActionButtonLook(prominent: true, small: false, chrome: .none)
                == ActionButtonLook(background: .fill, label: .onFill, cornerRadius: 8, fontSize: 12, semibold: true,
                                    horizontalPadding: 12, verticalPadding: 6))
        #expect(ActionButtonLook(prominent: false, small: false, chrome: .none)
                == ActionButtonLook(background: .wash, label: .tint, cornerRadius: 8, fontSize: 12, semibold: true,
                                    horizontalPadding: 12, verticalPadding: 6))
        #expect(ActionButtonLook(prominent: false, small: true, chrome: .none)
                == ActionButtonLook(background: .wash, label: .tint, cornerRadius: 6, fontSize: 11, semibold: false,
                                    horizontalPadding: 8, verticalPadding: 3))
        #expect(ActionButtonLook(prominent: true, small: true, chrome: .none)
                == ActionButtonLook(background: .fill, label: .onFill, cornerRadius: 6, fontSize: 11, semibold: false,
                                    horizontalPadding: 8, verticalPadding: 3))
    }

    /// The label's 4.5:1 is measured against a fill the app chooses; glass would lighten it.
    @Test func thePrimaryButtonIsNeverGlass() {
        for chrome in chromes {
            for small in [false, true] {
                #expect(ActionButtonLook(prominent: true, small: small, chrome: chrome).background == .fill)
            }
        }
    }

    @Test func aSecondaryButtonCarriesGlassOnlyOnAnOpaqueSurface() {
        for small in [false, true] {
            #expect(ActionButtonLook(prominent: false, small: small, chrome: .surface).background == .glass)
            // No glass on glass: inside the bar the wash sits on an opaque plate.
            #expect(ActionButtonLook(prominent: false, small: small, chrome: .onGlass).background == .plate)
            #expect(ActionButtonLook(prominent: false, small: small, chrome: .none).background == .wash)
        }
    }

    /// A muted or accent label would lose contrast against a backdrop the app does not control.
    @Test func aLabelOnGlassIsTheBodyColor() {
        for small in [false, true] {
            #expect(ActionButtonLook(prominent: false, small: small, chrome: .surface).label == .ink)
            // On its own opaque plate the label keeps the button's color, as in the flat look.
            #expect(ActionButtonLook(prominent: false, small: small, chrome: .onGlass).label == .tint)
            for chrome in chromes {
                #expect(ActionButtonLook(prominent: true, small: small, chrome: chrome).label == .onFill)
            }
        }
    }

    @Test func withGlassTheButtonsAreOneStepLarger() {
        #expect(ActionButtonLook(prominent: true, small: false, chrome: .surface)
                == ActionButtonLook(background: .fill, label: .onFill, cornerRadius: nil, fontSize: 13, semibold: true,
                                    horizontalPadding: 14, verticalPadding: 6.5))
        #expect(ActionButtonLook(prominent: false, small: false, chrome: .surface)
                == ActionButtonLook(background: .glass, label: .ink, cornerRadius: nil, fontSize: 13, semibold: false,
                                    horizontalPadding: 14, verticalPadding: 6.5))
        #expect(ActionButtonLook(prominent: false, small: true, chrome: .surface)
                == ActionButtonLook(background: .glass, label: .ink, cornerRadius: nil, fontSize: 11, semibold: false,
                                    horizontalPadding: 10, verticalPadding: 4))
        #expect(ActionButtonLook(prominent: false, small: false, chrome: .onGlass)
                == ActionButtonLook(background: .plate, label: .tint, cornerRadius: nil, fontSize: 13, semibold: false,
                                    horizontalPadding: 14, verticalPadding: 6.5))
    }

    /// The flat look's contrast was measured with these: the fill fades to 92% under the pointer.
    @Test func theBackgroundAnswersThePointerAsItDidBeforeGlass() {
        typealias Background = ActionButtonLook.Background
        #expect(Background.fill.opacity(hovering: false, pressed: false) == 1)
        #expect(Background.fill.opacity(hovering: true, pressed: false) == StatusPalette.hoverOpacity)
        #expect(Background.fill.opacity(hovering: true, pressed: true) == 0.78)
        #expect(Background.fill.opacity(hovering: false, pressed: true) == 0.78)
        for pressed in [false, true] {
            #expect(Background.wash.opacity(hovering: false, pressed: pressed) == 0.09)
            #expect(Background.wash.opacity(hovering: true, pressed: pressed) == 0.16)
            // The plate carries the same wash.
            #expect(Background.plate.opacity(hovering: false, pressed: pressed) == 0.09)
            #expect(Background.plate.opacity(hovering: true, pressed: pressed) == 0.16)
            // Glass is the resting background; the wash only answers the pointer.
            #expect(Background.glass.opacity(hovering: false, pressed: pressed) == 0)
            #expect(Background.glass.opacity(hovering: true, pressed: pressed) == 0.1)
        }
    }

    @Test func withGlassEveryButtonIsACapsuleOfOneHeightPerSize() {
        for chrome in [GlassChrome.surface, .onGlass] {
            for kind in kinds {
                let look = ActionButtonLook(prominent: kind.prominent, small: kind.small, chrome: chrome)
                #expect(look.cornerRadius == nil, "\(chrome) \(kind)")
            }
            // A primary and a secondary button side by side line up.
            for small in [false, true] {
                let primary = ActionButtonLook(prominent: true, small: small, chrome: chrome)
                let secondary = ActionButtonLook(prominent: false, small: small, chrome: chrome)
                #expect(primary.fontSize == secondary.fontSize)
                #expect(primary.verticalPadding == secondary.verticalPadding)
                #expect(primary.horizontalPadding == secondary.horizontalPadding)
            }
        }
    }

    @Test func withGlassOnlyThePrimaryButtonIsSemibold() {
        for chrome in [GlassChrome.surface, .onGlass] {
            #expect(ActionButtonLook(prominent: true, small: false, chrome: chrome).semibold)
            #expect(!ActionButtonLook(prominent: false, small: false, chrome: chrome).semibold)
        }
    }

    @Test func nothingIsSmallerThanTheSmallestTextSize() {
        for chrome in chromes {
            for kind in kinds {
                #expect(ActionButtonLook(prominent: kind.prominent, small: kind.small, chrome: chrome).fontSize >= 11)
            }
        }
    }
}
