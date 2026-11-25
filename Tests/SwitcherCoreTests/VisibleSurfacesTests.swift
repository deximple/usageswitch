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

    @Test func aMinimizedWindowIsNotOnScreen() {
        // Minimizing sends no close: the window sits in the Dock, nothing of the app is on screen,
        // and the status pollers go back to their slow cadence until it comes back.
        var surfaces = VisibleSurfaces()
        _ = surfaces.note(.mainWindow, open: true)
        let flips = [
            surfaces.noteMinimized(.mainWindow, true),
            surfaces.noteMinimized(.mainWindow, false),
        ]
        #expect(flips == [true, true])
        #expect(surfaces.anyVisible)
    }

    @Test func aMinimizedWindowShownAgainCountsAgain() {
        // Reopening from the menu bar shows the minimized window: it is on screen once more.
        var surfaces = VisibleSurfaces()
        _ = surfaces.note(.mainWindow, open: true)
        _ = surfaces.noteMinimized(.mainWindow, true)
        let shown = surfaces.note(.mainWindow, open: true)
        #expect(shown)
        #expect(surfaces.anyVisible)
    }

    @Test func aWindowClosedWhileMinimizedLeavesNoMarkBehind() {
        var surfaces = VisibleSurfaces()
        _ = surfaces.note(.detailWindow, open: true)
        _ = surfaces.noteMinimized(.detailWindow, true)
        _ = surfaces.note(.detailWindow, open: false)
        #expect(!surfaces.anyVisible)
        // Opened again later, it is on screen — the old minimized mark is gone.
        _ = surfaces.note(.detailWindow, open: true)
        #expect(surfaces.anyVisible)
    }

    @Test func anotherSurfaceOnScreenKeepsTheFastCadence() {
        var surfaces = VisibleSurfaces()
        _ = surfaces.note(.mainWindow, open: true)
        _ = surfaces.note(.detailWindow, open: true)
        let flipped = surfaces.noteMinimized(.mainWindow, true)
        #expect(!flipped)
        #expect(surfaces.anyVisible)
    }

    @Test func hidingTheAppTakesItsWindowsOffScreenButNotTheMenuPanel() {
        // ⌘H hides the windows; the menu bar panel opened afterwards is still on screen.
        var surfaces = VisibleSurfaces()
        _ = surfaces.note(.mainWindow, open: true)
        let flips = [
            surfaces.noteAppHidden(true),
            surfaces.note(.menuPanel, open: true),
            surfaces.note(.menuPanel, open: false),
            surfaces.noteAppHidden(false),
        ]
        #expect(flips == [true, true, true, true])
        #expect(surfaces.anyVisible)
    }
}
