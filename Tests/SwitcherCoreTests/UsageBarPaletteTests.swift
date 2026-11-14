import Foundation
import Testing

@testable import SwitcherCore

@Suite("Usage bar palette")
struct UsageBarPaletteTests {
    /// Every fill a bar can take: one per provider plus the two status fills that override it.
    private var fills: [(name: String, tint: UsageBarTint)] {
        UsageProvider.allCases.map { ($0.rawValue, UsageBarPalette.tint(for: $0)) }
            + [("warning", UsageBarPalette.warning), ("exhausted", UsageBarPalette.exhausted)]
    }

    @Test("WCAG contrast math matches the reference values")
    func contrastMath() {
        #expect(abs(UsageBarPalette.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
        #expect(UsageBarPalette.contrast(0x777777, 0x777777) == 1)
        // order never matters
        #expect(UsageBarPalette.contrast(0xC15F3C, 0xEBEBEB) == UsageBarPalette.contrast(0xEBEBEB, 0xC15F3C))
        // #767676 on white is the classic 4.54:1 AA boundary grey
        #expect(abs(UsageBarPalette.contrast(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    }

    @Test("every fill reaches 3:1 against the window background in light and dark")
    func fillsAgainstCanvas() {
        for fill in fills {
            let light = UsageBarPalette.contrast(fill.tint.light, UsageBarPalette.canvas.light)
            let dark = UsageBarPalette.contrast(fill.tint.dark, UsageBarPalette.canvas.dark)
            #expect(light >= UsageBarPalette.minimumContrast, "\(fill.name) light \(light)")
            #expect(dark >= UsageBarPalette.minimumContrast, "\(fill.name) dark \(dark)")
        }
    }

    @Test("every fill reaches 3:1 against the track it sits on, so the bar's end is readable")
    func fillsAgainstTrack() {
        for fill in fills {
            let light = UsageBarPalette.contrast(fill.tint.light, UsageBarPalette.track.light)
            let dark = UsageBarPalette.contrast(fill.tint.dark, UsageBarPalette.track.dark)
            #expect(light >= UsageBarPalette.minimumContrast, "\(fill.name) light \(light)")
            #expect(dark >= UsageBarPalette.minimumContrast, "\(fill.name) dark \(dark)")
        }
    }

    @Test("a black-and-white logo reads dark on light and light on dark")
    func monochromeFlipsWithAppearance() {
        for provider in [UsageProvider.codex, .cursor, .grok, .devin, .opencode, .copilot] {
            let tint = UsageBarPalette.tint(for: provider)
            #expect(tint == UsageBarPalette.monochrome, "\(provider.rawValue)")
        }
        let mono = UsageBarPalette.monochrome
        #expect(UsageBarPalette.relativeLuminance(mono.light) < 0.05)
        #expect(UsageBarPalette.relativeLuminance(mono.dark) > 0.7)
    }

    @Test("a vendor tint is never one of the status fills")
    func vendorTintsStayDistinctFromStatus() {
        for provider in UsageProvider.allCases {
            let tint = UsageBarPalette.tint(for: provider)
            #expect(tint != UsageBarPalette.warning, "\(provider.rawValue)")
            #expect(tint != UsageBarPalette.exhausted, "\(provider.rawValue)")
        }
    }

    @Test("stale beats exhausted beats warning beats the vendor tint")
    func rolePrecedence() {
        #expect(UsageBarPalette.role(usedPercent: 100, warnAt: 80, stale: true) == .stale)
        #expect(UsageBarPalette.role(usedPercent: 100, warnAt: 80, stale: false) == .exhausted)
        #expect(UsageBarPalette.role(usedPercent: 130, warnAt: 80, stale: false) == .exhausted)
        #expect(UsageBarPalette.role(usedPercent: 80, warnAt: 80, stale: false) == .warning)
        #expect(UsageBarPalette.role(usedPercent: 79.9, warnAt: 80, stale: false) == .vendor)
        #expect(UsageBarPalette.role(usedPercent: 0, warnAt: 70, stale: false) == .vendor)
    }
}
