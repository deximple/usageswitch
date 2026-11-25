import Foundation
import Testing
@testable import SwitcherCore

@Suite("Status markers and filled buttons")
struct StatusPaletteTests {
    /// The surfaces a state chip or a marker sits on.
    private var surfaces: [(name: String, tint: UsageBarTint)] {
        [("canvas", UsageBarPalette.canvas), ("chip well", StatusPalette.chipWell),
         ("surface", StatusPalette.surface)]
    }

    /// A damaged and an expired saved sign-in share the same button: the glyph has to tell them apart.
    @Test func everyStateHasItsOwnGlyph() {
        #expect(Set(StatusMarker.allCases.map(\.symbol)).count == StatusMarker.allCases.count)
        #expect(StatusMarker.claude(.expired, active: false).symbol
                != StatusMarker.claude(.corrupt, active: false).symbol)
    }

    @Test func claudeStatesMapToMarkers() {
        #expect(StatusMarker.claude(.ready, active: false) == .ready)
        #expect(StatusMarker.claude(.expired, active: false) == .attention)
        #expect(StatusMarker.claude(.corrupt, active: false) == .damaged)
        // the signed-in account is current whatever its saved copy looks like
        for state in [SnapshotState.ready, .expired, .corrupt] {
            #expect(StatusMarker.claude(state, active: true) == .current)
        }
    }

    @Test func codexStatesMapToMarkers() {
        #expect(StatusMarker.codex(.running) == .current)
        #expect(StatusMarker.codex(.signedIn) == .ready)
        #expect(StatusMarker.codex(.signedOut) == .attention)
    }

    /// The current marker follows the user's accent color, which has no fixed value to hold to a ratio.
    @Test func onlyTheCurrentMarkerHasNoFixedColor() {
        for marker in StatusMarker.allCases {
            #expect((StatusPalette.tint(for: marker) == nil) == (marker == .current))
        }
    }

    @Test("every marker color reaches 3:1 on the surfaces it sits on, in light and dark")
    func markersAgainstSurfaces() {
        for marker in StatusMarker.allCases {
            guard let tint = StatusPalette.tint(for: marker) else { continue }
            for surface in surfaces {
                let light = UsageBarPalette.contrast(tint.light, surface.tint.light)
                let dark = UsageBarPalette.contrast(tint.dark, surface.tint.dark)
                #expect(light >= UsageBarPalette.minimumContrast, "\(marker) on \(surface.name) light \(light)")
                #expect(dark >= UsageBarPalette.minimumContrast, "\(marker) on \(surface.name) dark \(dark)")
            }
        }
    }

    /// The accent colors macOS 27 offers, measured in sRGB.
    private var systemAccents: [(name: String, tint: UsageBarTint)] {
        [("graphite", UsageBarTint(light: 0x989898, dark: 0x8C8C8C)),
         ("blue", UsageBarTint(light: 0x0088FF, dark: 0x0091FF)),
         ("purple", UsageBarTint(light: 0xCB30E0, dark: 0xDB34F2)),
         ("pink", UsageBarTint(light: 0xFF2D55, dark: 0xFF375F)),
         ("red", UsageBarTint(light: 0xFF383C, dark: 0xFF4245)),
         ("orange", UsageBarTint(light: 0xFF8D28, dark: 0xFF9230)),
         ("yellow", UsageBarTint(light: 0xFFCC00, dark: 0xFFD600)),
         ("green", UsageBarTint(light: 0x34C759, dark: 0x30D158))]
    }

    /// The primary button as it is drawn for one accent color.
    private func accentButton(_ accent: UsageBarTint) -> StatusPalette.FilledButton {
        StatusPalette.FilledButton(
            fill: UsageBarTint(light: StatusPalette.accentFill(accent.light, dark: false),
                               dark: StatusPalette.accentFill(accent.dark, dark: true)),
            label: StatusPalette.labelOnFill)
    }

    /// Six evenly spaced values per channel: 216 colors across the whole cube.
    private var anyAccents: [(name: String, tint: UsageBarTint)] {
        let steps: [UInt32] = [0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF]
        return steps.flatMap { red in
            steps.flatMap { green in
                steps.map { blue in
                    let hex = red << 16 | green << 8 | blue
                    return (String(format: "#%06X", hex), UsageBarTint(light: hex, dark: hex))
                }
            }
        }
    }

    private var buttons: [(name: String, pair: StatusPalette.FilledButton)] {
        [("confirm", StatusPalette.confirmButton), ("neutral", StatusPalette.neutralButton)]
            + (systemAccents + anyAccents).map { ("accent \($0.name)", accentButton($0.tint)) }
    }

    /// The fill moves along the line from the accent to black (light) or white (dark) and stops at
    /// the first step that carries the label, so the hue stays the user's.
    @Test func theAccentFillKeepsItsHueAndMovesOnlyAsFarAsNeeded() {
        // Light: white on system blue is 3.5:1, so the fill deepens.
        let blue = StatusPalette.accentFill(0x0088FF, dark: false)
        #expect(blue == StatusPalette.blend(0x000000, over: 0x0088FF, opacity: 0.21))
        // One step lighter no longer carries a white label while hovered.
        let lighter = StatusPalette.blend(0x000000, over: 0x0088FF, opacity: 0.20)
        #expect(UsageBarPalette.contrast(
            0xFFFFFF, StatusPalette.blend(lighter, over: StatusPalette.surface.light,
                                          opacity: StatusPalette.hoverOpacity)) < StatusPalette.minimumTextContrast)
        // Dark: graphite lightens a little for the dark label.
        #expect(StatusPalette.accentFill(0x8C8C8C, dark: true)
                == StatusPalette.blend(0xFFFFFF, over: 0x8C8C8C, opacity: 0.03))
    }

    @Test func anAccentThatAlreadyCarriesItsLabelIsLeftAlone() {
        #expect(StatusPalette.accentFill(0x004080, dark: false) == 0x004080)
        #expect(StatusPalette.accentFill(0xFFD600, dark: true) == 0xFFD600)
        #expect(StatusPalette.accentFill(0x0091FF, dark: true) == 0x0091FF)
    }

    @Test("a filled button's label reaches 4.5:1 on its fill, in light and dark")
    func filledButtonLabels() {
        for button in buttons {
            let light = UsageBarPalette.contrast(button.pair.label.light, button.pair.fill.light)
            let dark = UsageBarPalette.contrast(button.pair.label.dark, button.pair.fill.dark)
            #expect(light >= StatusPalette.minimumTextContrast, "\(button.name) light \(light)")
            #expect(dark >= StatusPalette.minimumTextContrast, "\(button.name) dark \(dark)")
        }
    }

    /// Hovering fades the fill to 92% over what is behind it; the label must still read.
    @Test("the label still reaches 4.5:1 while the button is hovered")
    func filledButtonLabelsWhileHovered() {
        for button in buttons {
            for surface in [UsageBarPalette.canvas, StatusPalette.surface] {
                let light = UsageBarPalette.contrast(
                    button.pair.label.light,
                    StatusPalette.blend(button.pair.fill.light, over: surface.light, opacity: StatusPalette.hoverOpacity))
                let dark = UsageBarPalette.contrast(
                    button.pair.label.dark,
                    StatusPalette.blend(button.pair.fill.dark, over: surface.dark, opacity: StatusPalette.hoverOpacity))
                #expect(light >= StatusPalette.minimumTextContrast, "\(button.name) light \(light)")
                #expect(dark >= StatusPalette.minimumTextContrast, "\(button.name) dark \(dark)")
            }
        }
    }

    @Test("a filled button stands out from the window at 3:1, in light and dark")
    func filledButtonsAgainstCanvas() {
        for button in buttons {
            let light = UsageBarPalette.contrast(button.pair.fill.light, UsageBarPalette.canvas.light)
            let dark = UsageBarPalette.contrast(button.pair.fill.dark, UsageBarPalette.canvas.dark)
            #expect(light >= UsageBarPalette.minimumContrast, "\(button.name) light \(light)")
            #expect(dark >= UsageBarPalette.minimumContrast, "\(button.name) dark \(dark)")
        }
    }

    // MARK: - Quiet buttons, the current marker and the environment dot

    /// The washes a quiet button is drawn on: its own color at rest and while hovered
    /// (`ActionButtonLook.Background.wash`), and the environment badge's tint.
    private var quietWashes: [Double] {
        [ActionButtonLook.Background.wash.opacity(hovering: false, pressed: false),
         ActionButtonLook.Background.wash.opacity(hovering: true, pressed: false),
         StatusPalette.environmentWashOpacity]
    }

    /// A quiet button's label is its own color over a wash of that color, on whatever it sits on.
    private func quietLabelContrasts(_ tint: UsageBarTint) -> [(String, Double)] {
        surfaces.flatMap { surface in
            quietWashes.flatMap { opacity -> [(String, Double)] in
                let light = UsageBarPalette.contrast(
                    tint.light, StatusPalette.blend(tint.light, over: surface.tint.light, opacity: opacity))
                let dark = UsageBarPalette.contrast(
                    tint.dark, StatusPalette.blend(tint.dark, over: surface.tint.dark, opacity: opacity))
                return [("\(surface.name) \(opacity) light", light), ("\(surface.name) \(opacity) dark", dark)]
            }
        }
    }

    @Test("a quiet grey button's label reaches 4.5:1 on its wash, in light and dark")
    func quietMutedLabel() {
        for (name, ratio) in quietLabelContrasts(StatusPalette.quietMuted) {
            #expect(ratio >= StatusPalette.minimumTextContrast, "\(name) \(ratio)")
        }
    }

    @Test("a quiet accent button's label reaches 4.5:1 on its wash for any accent color")
    func quietAccentLabel() {
        for accent in systemAccents + anyAccents {
            let label = UsageBarTint(light: StatusPalette.quietLabel(accent.tint.light, dark: false),
                                     dark: StatusPalette.quietLabel(accent.tint.dark, dark: true))
            for (name, ratio) in quietLabelContrasts(label) {
                #expect(ratio >= StatusPalette.minimumTextContrast, "\(accent.name) \(name) \(ratio)")
            }
        }
    }

    /// Where the current marker sits: the canvas, a chip well, the header card, and the current
    /// account's row, which carries a 10% wash of the raw accent color.
    @Test("the current marker reaches 3:1 for any accent color, in light and dark")
    func currentMarkerForAnyAccent() {
        for accent in systemAccents + anyAccents {
            for dark in [false, true] {
                let raw = dark ? accent.tint.dark : accent.tint.light
                let marker = StatusPalette.currentMarker(raw, dark: dark)
                let row = StatusPalette.blend(raw, over: dark ? UsageBarPalette.canvas.dark
                                                              : UsageBarPalette.canvas.light,
                                              opacity: StatusPalette.currentRowOpacity)
                for backdrop in surfaces.map({ dark ? $0.tint.dark : $0.tint.light }) + [row] {
                    let ratio = UsageBarPalette.contrast(marker, backdrop)
                    #expect(ratio >= UsageBarPalette.minimumContrast,
                            "\(accent.name) \(dark ? "dark" : "light") on #\(String(backdrop, radix: 16)) \(ratio)")
                }
            }
        }
    }

    @Test func aCurrentMarkerThatAlreadyReadsKeepsTheAccent() {
        // Dark system blue already reaches 3:1 everywhere it sits.
        #expect(StatusPalette.currentMarker(0x0091FF, dark: true) == 0x0091FF)
        // Light system blue does not, so it deepens toward black and keeps its hue.
        let blue = StatusPalette.currentMarker(0x0088FF, dark: false)
        #expect(blue != 0x0088FF)
        #expect(blue & 0xFF > (blue >> 16) & 0xFF)
    }

    /// The badge of a confirmed environment: a dot carries the color, the text stays at body contrast.
    @Test("the environment dot reaches 3:1 on its badge, in light and dark")
    func environmentDot() {
        let tint = StatusPalette.environmentMarker
        for surface in surfaces {
            let light = UsageBarPalette.contrast(tint.light, StatusPalette.blend(
                tint.light, over: surface.tint.light, opacity: StatusPalette.environmentWashOpacity))
            let dark = UsageBarPalette.contrast(tint.dark, StatusPalette.blend(
                tint.dark, over: surface.tint.dark, opacity: StatusPalette.environmentWashOpacity))
            #expect(light >= UsageBarPalette.minimumContrast, "\(surface.name) light \(light)")
            #expect(dark >= UsageBarPalette.minimumContrast, "\(surface.name) dark \(dark)")
        }
    }

    @Test func blendingMixesTwoColors() {
        #expect(StatusPalette.blend(0x000000, over: 0xFFFFFF, opacity: 1) == 0x000000)
        #expect(StatusPalette.blend(0x000000, over: 0xFFFFFF, opacity: 0) == 0xFFFFFF)
        #expect(StatusPalette.blend(0x000000, over: 0xFFFFFF, opacity: 0.5) == 0x808080)
    }
}
