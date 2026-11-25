import Foundation
import Testing

@testable import SwitcherCore

@Suite("Usage bar palette")
struct UsageBarPaletteTests {
    private typealias Palette = UsageBarPalette

    /// The three levels a bar is filled in, best first; a used-up bar is empty and stale is grey.
    private var looks: [(name: String, look: Palette.Look)] {
        [("ample", Palette.ample), ("warning", Palette.warning), ("critical", Palette.critical)]
    }

    /// What a bar sits on: the window and its own track.
    private var backdrops: [(name: String, tint: UsageBarTint)] {
        [("canvas", Palette.canvas), ("track", Palette.track)]
    }

    @Test("WCAG contrast math matches the reference values")
    func contrastMath() {
        #expect(abs(Palette.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
        #expect(Palette.contrast(0x777777, 0x777777) == 1)
        // order never matters
        #expect(Palette.contrast(0xC15F3C, 0xEBEBEB) == Palette.contrast(0xEBEBEB, 0xC15F3C))
        // #767676 on white is the classic 4.54:1 AA boundary grey
        #expect(abs(Palette.contrast(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    }

    @Test("in dark the fill itself reaches 3:1 against the window and the track")
    func darkFills() {
        for item in looks {
            for backdrop in backdrops {
                let ratio = Palette.contrast(item.look.fill.dark, backdrop.tint.dark)
                #expect(ratio >= Palette.minimumContrast, "\(item.name) on \(backdrop.name) \(ratio)")
            }
        }
    }

    /// The light fills are the dark ones (the green a little deeper) and reach only 1.3–2.9:1, so a
    /// 1pt border in a deep tone of the same hue carries the contrast there.
    @Test("in light the border reaches 3:1 against the window and the track")
    func lightRims() {
        for item in looks {
            for backdrop in backdrops {
                let ratio = Palette.contrast(item.look.rim, backdrop.tint.light)
                #expect(ratio >= Palette.minimumContrast, "\(item.name) on \(backdrop.name) \(ratio)")
            }
        }
    }

    @Test("a level's marker reaches 3:1 against the window and the track, in light and dark")
    func markers() {
        for item in looks {
            #expect(item.look.marker == UsageBarTint(light: item.look.rim, dark: item.look.fill.dark))
            for backdrop in backdrops {
                let light = Palette.contrast(item.look.marker.light, backdrop.tint.light)
                let dark = Palette.contrast(item.look.marker.dark, backdrop.tint.dark)
                #expect(light >= Palette.minimumContrast, "\(item.name) on \(backdrop.name) light \(light)")
                #expect(dark >= Palette.minimumContrast, "\(item.name) on \(backdrop.name) dark \(dark)")
            }
        }
    }

    /// The emboss darkens the lower edge of a fill; in dark that edge still has to carry 3:1.
    @Test("the embossed fill's darkest edge still reaches 3:1 in dark")
    func embossKeepsTheDarkFillReadable() {
        let emboss = Palette.emboss
        for item in looks {
            let lined = StatusPalette.blend(0x000000, over: item.look.fill.dark, opacity: emboss.shadeLine)
            let edge = StatusPalette.blend(0x000000, over: lined, opacity: emboss.shade)
            for backdrop in backdrops {
                let ratio = Palette.contrast(edge, backdrop.tint.dark)
                #expect(ratio >= Palette.minimumContrast, "\(item.name) on \(backdrop.name) \(ratio)")
            }
        }
    }

    @Test("a stale bar is flat, and so is every bar under Reduce Transparency or Increase Contrast")
    func flatBars() {
        for role in Palette.Role.allCases {
            #expect(Palette.isEmbossed(role, reduceTransparency: false, increasedContrast: false)
                    == (role != .stale))
            #expect(!Palette.isEmbossed(role, reduceTransparency: true, increasedContrast: false))
            #expect(!Palette.isEmbossed(role, reduceTransparency: false, increasedContrast: true))
        }
    }

    @Test("the color distance math matches the reference values")
    func distanceMath() {
        #expect(ColorVision.normal.distance(0x123456, 0x123456) == 0)
        #expect(abs(ColorVision.normal.distance(0x000000, 0xFFFFFF) - 100) < 0.01)
        // The light warning and used-up colors that shipped through 2.5.1: apart with normal
        // vision, the same color with a green deficiency.
        #expect(abs(ColorVision.normal.distance(0x9E7200, 0xD70015) - 18.58) < 0.05)
        #expect(abs(ColorVision.deutan.distance(0x9E7200, 0xD70015) - 1.77) < 0.05)
    }

    /// Neighboring levels have to stay apart for every kind of color vision: the fills as drawn in
    /// each appearance, and the markers (the light ones are the borders).
    @Test("neighboring levels stay apart with normal vision and with each color vision deficiency")
    func neighborsStayApart() {
        let swatches: [(name: String, colors: [UInt32])] = [
            ("light fill", looks.map(\.look.fill.light)),
            ("dark fill", looks.map(\.look.fill.dark)),
            ("light marker", looks.map(\.look.marker.light)),
            ("dark marker", looks.map(\.look.marker.dark)),
        ]
        for swatch in swatches {
            for (better, worse) in zip(swatch.colors, swatch.colors.dropFirst()) {
                for vision in ColorVision.allCases {
                    let distance = vision.distance(better, worse)
                    #expect(distance >= vision.minimumDistance,
                            "\(swatch.name) #\(String(better, radix: 16)) #\(String(worse, radix: 16)) \(vision) \(distance)")
                }
            }
        }
    }

    @Test("a used-up bar's marker takes the critical look, and a stale bar has none")
    func looksByRole() {
        #expect(Palette.look(for: .ample) == Palette.ample)
        #expect(Palette.look(for: .warning) == Palette.warning)
        #expect(Palette.look(for: .critical) == Palette.critical)
        // An empty bar draws no fill; its marker is the critical one.
        #expect(Palette.look(for: .exhausted) == Palette.critical)
        #expect(Palette.look(for: .stale) == nil)
    }

    /// Color never carries a level alone: each level below ample has a glyph of its own shape.
    @Test("every level below ample has its own glyph")
    func glyphs() {
        #expect(Palette.Role.ample.symbol == nil)
        #expect(Palette.Role.stale.symbol == nil)
        let marked: [Palette.Role] = [.warning, .critical, .exhausted]
        #expect(Set(marked.compactMap(\.symbol)).count == marked.count)
    }

    // MARK: - Levels

    private func role(_ used: Double, warnAt: Double = 80, previous: Palette.Role? = nil) -> Palette.Role {
        Palette.role(usedPercent: used, warnAt: warnAt, stale: false, previous: previous)
    }

    @Test("stale beats every level")
    func staleFirst() {
        for used in [0.0, 50, 85, 95, 100, 130] {
            #expect(Palette.role(usedPercent: used, warnAt: 80, stale: true) == .stale)
        }
    }

    @Test("a reading that isn't a number shows no level")
    func invalidReadings() {
        #expect(role(.nan) == .stale)
        #expect(role(.infinity) == .stale)
        #expect(role(-1) == .stale)
    }

    /// The level follows the whole percent the row shows (`UsageText.percentLeft`), so two rows that
    /// read "20%" are never drawn differently.
    @Test("the level follows the number on screen, not the unrounded reading")
    func levelFollowsTheShownNumber() {
        // 79.6% and 80.4% used both read "20%": the warning line at 20% left catches both.
        #expect(UsageText.percentLeft(79.6) == 20)
        #expect(role(79.6) == .warning)
        #expect(role(80.4) == .warning)
        #expect(role(80) == .warning)
        // 79.4% used reads "21%".
        #expect(role(79.4) == .ample)
        #expect(role(0) == .ample)
    }

    @Test("a row that reads 0% is used up")
    func zeroIsUsedUp() {
        // 99.6% used reads "0%": the bar is empty, so it is used up, not merely low.
        #expect(UsageText.percentLeft(99.6) == 0)
        #expect(role(99.6) == .exhausted)
        #expect(role(100) == .exhausted)
        #expect(role(130) == .exhausted)
        // 99.5% used still reads "1%".
        #expect(UsageText.percentLeft(99.5) == 1)
        #expect(role(99.5) == .critical)
    }

    @Test("critical starts at 10% left, or at 5% when the warning line is at 10%")
    func criticalLine() {
        #expect(Palette.warningLine(warnAt: 70) == 30)
        #expect(Palette.warningLine(warnAt: 80) == 20)
        #expect(Palette.warningLine(warnAt: 90) == 10)
        #expect(Palette.criticalLine(warnAt: 70) == 10)
        #expect(Palette.criticalLine(warnAt: 80) == 10)
        #expect(Palette.criticalLine(warnAt: 90) == 5)

        for warnAt in [70.0, 80] {
            #expect(role(89, warnAt: warnAt) == .warning)   // 11% left
            #expect(role(90, warnAt: warnAt) == .critical)  // 10% left
            #expect(role(99, warnAt: warnAt) == .critical)  // 1% left
        }
        #expect(role(69, warnAt: 70) == .ample)             // 31% left
        #expect(role(70, warnAt: 70) == .warning)           // 30% left

        #expect(role(89, warnAt: 90) == .ample)             // 11% left
        #expect(role(90, warnAt: 90) == .warning)           // 10% left
        #expect(role(94, warnAt: 90) == .warning)           // 6% left
        #expect(role(94.6, warnAt: 90) == .critical)        // reads 5%
        #expect(role(95, warnAt: 90) == .critical)          // 5% left
    }

    /// Getting worse shows at once; getting better waits until the remaining share is two points
    /// above the line, so a reading that wobbles on a line doesn't flip the color back and forth.
    @Test("a level eases only once the remaining share is two points above its line")
    func recovery() {
        // warning line at 20% left
        #expect(role(79, previous: .warning) == .warning)   // 21% left
        #expect(role(78, previous: .warning) == .ample)     // 22% left
        // critical line at 10% left
        #expect(role(89, previous: .critical) == .critical) // 11% left
        #expect(role(88, previous: .critical) == .warning)  // 12% left
        // from critical straight back over the warning line
        #expect(role(79, previous: .critical) == .warning)  // 21% left
        #expect(role(78, previous: .critical) == .ample)    // 22% left
        // 5% line under a 10% warning line
        #expect(role(94, warnAt: 90, previous: .critical) == .critical) // 6% left
        #expect(role(93, warnAt: 90, previous: .critical) == .warning)  // 7% left
    }

    @Test("getting worse is never delayed, and 0% alone is used up")
    func recoveryNeverHidesAWorseLevel() {
        #expect(role(80, previous: .ample) == .warning)
        #expect(role(90, previous: .ample) == .critical)
        #expect(role(90, previous: .warning) == .critical)
        #expect(role(100, previous: .warning) == .exhausted)
        // Used up is the empty bar only: any share left is critical again, then eases like critical.
        #expect(role(99, previous: .exhausted) == .critical)
        #expect(role(89, previous: .exhausted) == .critical)
        #expect(role(88, previous: .exhausted) == .warning)
        // A stale bar remembers nothing.
        #expect(role(79, previous: .stale) == .ample)
        #expect(role(79, previous: nil) == .ample)
    }
}
