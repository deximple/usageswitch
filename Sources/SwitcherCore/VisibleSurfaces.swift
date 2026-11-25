/// Which of the app's own surfaces are on screen. A set, not a count: a window shown again after
/// being minimized or hidden is reported open twice, and a count would then never return to zero —
/// leaving the status pollers on their fast cadence for good. A minimized window, and every window
/// while the app is hidden, is still open but not on screen, so it doesn't count either.
public struct VisibleSurfaces: Sendable {
    public enum Surface: Hashable, Sendable { case mainWindow, detailWindow, menuPanel }

    private var open: Set<Surface> = []
    /// Open windows sitting in the Dock.
    private var minimized: Set<Surface> = []
    /// ⌘H hides the windows; the menu bar panel is not one of them.
    private var appHidden = false

    public init() {}

    public var anyVisible: Bool {
        open.contains { $0 == .menuPanel || (!appHidden && !minimized.contains($0)) }
    }

    /// Records one surface opening or closing. True when `anyVisible` changed. Either way a
    /// window is no longer in the Dock: it was shown again or it is gone.
    public mutating func note(_ surface: Surface, open isOpen: Bool) -> Bool {
        let was = anyVisible
        if isOpen { open.insert(surface) } else { open.remove(surface) }
        minimized.remove(surface)
        return anyVisible != was
    }

    /// Records a window going into the Dock or coming back. True when `anyVisible` changed.
    public mutating func noteMinimized(_ surface: Surface, _ isMinimized: Bool) -> Bool {
        let was = anyVisible
        if isMinimized { minimized.insert(surface) } else { minimized.remove(surface) }
        return anyVisible != was
    }

    /// Records the app being hidden or shown again. True when `anyVisible` changed.
    public mutating func noteAppHidden(_ hidden: Bool) -> Bool {
        let was = anyVisible
        appHidden = hidden
        return anyVisible != was
    }
}
