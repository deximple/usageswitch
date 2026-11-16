import SwitcherCore
import Testing

@Suite("Visible surfaces")
struct VisibleSurfacesTests {
    @Test func nothingIsVisibleAtFirst() {
        #expect(!VisibleSurfaces().anyVisible)
    }

    @Test func aWindowShownAgainAfterBeingHiddenStillClosesToNothingVisible() {
        // Minimizing or hiding a window sends no close, so showing it again reports it open a
        // second time. One close must still leave nothing visible — the slow poll cadence returns.
        var surfaces = VisibleSurfaces()
        let flips = [
            surfaces.note(.mainWindow, open: true),
            surfaces.note(.mainWindow, open: true),
            surfaces.note(.mainWindow, open: false),
        ]
        #expect(flips == [true, false, true])
        #expect(!surfaces.anyVisible)
    }

    @Test func closingASurfaceThatWasNeverReportedOpenChangesNothing() {
        var surfaces = VisibleSurfaces()
        let flipped = surfaces.note(.detailWindow, open: false)
        #expect(!flipped)
        #expect(!surfaces.anyVisible)
    }

    @Test func theFlagOnlyFlipsWithTheFirstOpenAndTheLastClose() {
        var surfaces = VisibleSurfaces()
        let flips = [
            surfaces.note(.menuPanel, open: true),
            surfaces.note(.detailWindow, open: true),
            surfaces.note(.menuPanel, open: false),
            surfaces.note(.detailWindow, open: false),
        ]
        #expect(flips == [true, false, false, true])
        #expect(!surfaces.anyVisible)
    }
}
