import Foundation

/// Decides when the usage-log read behind the Guide and the API tab may start, and whether its
/// result may be applied. One read at a time; the ten-minute wait starts only when a result was
/// applied, so a discarded read is retried on the next refresh.
public struct SuggestionLogReadGate: Equatable, Sendable {
    public static let interval: TimeInterval = 600
    /// Bumped only when the inputs of a read change (consent, profile bindings, a data flush).
    private var epoch = 0
    private var inFlight: Int?
    private var lastAppliedAt: Date?
    /// Deletes of learning data under way: nothing starts and nothing is applied until each has
    /// called `resume()`. A count, so one delete ending can't reopen the gate under another.
    private var suspensions = 0

    public init() {}

    public func shouldStart(now: Date) -> Bool {
        suspensions == 0 && inFlight == nil && (lastAppliedAt.map { now.timeIntervalSince($0) >= Self.interval } ?? true)
    }

    /// Marks a read as running and returns the token to hand back to `finish`.
    public mutating func begin() -> Int {
        inFlight = epoch
        return epoch
    }

    /// True when the result may be applied; the throttle starts only then. With a `backlog`
    /// (logs still unread) there is no wait: the next refresh reads on.
    public mutating func finish(token: Int, now: Date, backlog: Bool = false) -> Bool {
        if inFlight == token { inFlight = nil }
        guard token == epoch, suspensions == 0 else { return false }
        lastAppliedAt = backlog ? nil : now
        return true
    }

    /// The inputs changed: a running read's result is no longer wanted, and the next may start at once.
    public mutating func invalidate() {
        epoch += 1
        inFlight = nil
        lastAppliedAt = nil
    }

    /// Learning data is about to be deleted. Called before the delete waits for the running read,
    /// so a refresh that ends meanwhile can't start another that writes cursors back afterwards.
    public mutating func suspend() {
        invalidate()
        suspensions += 1
    }

    /// One delete is over: once none is left, the next read starts from scratch; a read begun
    /// meanwhile is discarded.
    public mutating func resume() {
        invalidate()
        suspensions = max(0, suspensions - 1)
    }
}
