/// Which of the app's own surfaces are on screen. A set, not a count: a window shown again after
/// being minimized or hidden is reported open twice, and a count would then never return to zero —
/// leaving the status pollers on their fast cadence for good.
public struct VisibleSurfaces: Sendable {
    public enum Surface: Hashable, Sendable { case mainWindow, detailWindow, menuPanel }

    private var open: Set<Surface> = []

    public init() {}

    public var anyVisible: Bool { !open.isEmpty }

    /// Records one surface opening or closing. True when `anyVisible` changed.
    public mutating func note(_ surface: Surface, open isOpen: Bool) -> Bool {
        let was = anyVisible
        if isOpen { open.insert(surface) } else { open.remove(surface) }
        return anyVisible != was
    }
}
