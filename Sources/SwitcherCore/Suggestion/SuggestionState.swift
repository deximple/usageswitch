import Foundation

public struct SuggestionObservation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case collector, log }

    public let at: Date
    public let accountRef: String
    public let provider: UsageProvider
    public let windowKey: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let source: Source
    public let toolVersion: String?

    public init(at: Date, accountRef: String, provider: UsageProvider, windowKey: String,
                usedPercent: Double, resetsAt: Date?, source: Source, toolVersion: String?) {
        self.at = at
        self.accountRef = accountRef
        self.provider = provider
        self.windowKey = windowKey
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.source = source
        self.toolVersion = toolVersion
    }

    public static func windowKey(for window: UsageWindow) -> String {
        "\(window.kind.rawValue):\(window.durationMinutes.map(String.init) ?? "?"):\(window.scope ?? "*")"
    }
}

public struct SuggestionDelta: Codable, Equatable, Sendable {
    public let windowKey: String
    public let accountRef: String
    public let from: Double
    public let to: Double
    public let usedDelta: Double
    public let seconds: TimeInterval

    public init(windowKey: String, accountRef: String, from: Double, to: Double,
                usedDelta: Double, seconds: TimeInterval) {
        self.windowKey = windowKey
        self.accountRef = accountRef
        self.from = from
        self.to = to
        self.usedDelta = usedDelta
        self.seconds = seconds
    }
}

public struct SuggestionResetEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hard, soft }

    public let windowKey: String
    public let accountRef: String
    public let at: Date
    public let kind: Kind
    public let before: Double
    public let after: Double
    public let expectedAt: Date?

    public init(windowKey: String, accountRef: String, at: Date, kind: Kind,
                before: Double, after: Double, expectedAt: Date?) {
        self.windowKey = windowKey
        self.accountRef = accountRef
        self.at = at
        self.kind = kind
        self.before = before
        self.after = after
        self.expectedAt = expectedAt
    }
}

public typealias Observation = SuggestionObservation
public typealias Delta = SuggestionDelta
public typealias ResetEvent = SuggestionResetEvent

public struct SuggestionStateTracker: Sendable {
    public struct Result: Sendable {
        public let observations: [SuggestionObservation]
        public let deltas: [SuggestionDelta]
        public let resets: [SuggestionResetEvent]
    }

    public init() {}

    public func track(previous: [String: SuggestionObservation],
                      previousIdentityKeys: [String: String],
                      fresh: [AccountUsage],
                      accountRefKey: (UsageProvider, String) -> String? = { _, value in value }) -> Result {
        var observations: [SuggestionObservation] = []
        var deltas: [SuggestionDelta] = []
        var resets: [SuggestionResetEvent] = []

        for usage in fresh where usage.state == .ok {
            for window in usage.windows where window.usedPercent.isFinite
                && (0...100).contains(window.usedPercent) {
                let windowKey = SuggestionObservation.windowKey(for: window)
                guard let accountRef = accountRefKey(usage.provider, usage.accountRef),
                      !accountRef.isEmpty else { continue }
                let key = Self.key(provider: usage.provider, accountRef: accountRef,
                                   windowKey: windowKey)
                let observation = SuggestionObservation(
                    at: usage.readAt, accountRef: accountRef, provider: usage.provider,
                    windowKey: windowKey, usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt, source: .collector,
                    toolVersion: usage.toolVersion.map(UsageSnapshot.maskedString))
                observations.append(observation)

                guard let prior = previous[key] else { continue }
                let identityMatches = usage.identityKey.map {
                    !$0.isEmpty && previousIdentityKeys[key] == $0
                } ?? false
                let gap = usage.readAt.timeIntervalSince(prior.at)
                guard prior.usedPercent.isFinite, (0...100).contains(prior.usedPercent) else { continue }
                let dropped = window.usedPercent < prior.usedPercent
                if identityMatches, dropped, let expectedAt = prior.resetsAt {
                    let hard = expectedAt <= usage.readAt
                        && window.resetsAt.map { $0 > expectedAt } == true
                    resets.append(SuggestionResetEvent(
                        windowKey: windowKey, accountRef: accountRef, at: usage.readAt,
                        kind: hard ? .hard : .soft, before: prior.usedPercent,
                        after: window.usedPercent, expectedAt: expectedAt))
                } else if identityMatches, let oldReset = prior.resetsAt, let newReset = window.resetsAt,
                          oldReset != newReset, !Self.resetShiftIsConsistent(oldReset, newReset, windowKey) {
                    resets.append(SuggestionResetEvent(
                        windowKey: windowKey, accountRef: accountRef, at: usage.readAt,
                        kind: .soft, before: prior.usedPercent, after: window.usedPercent,
                        expectedAt: oldReset))
                }

                let continuous = identityMatches && prior.resetsAt == window.resetsAt
                    && gap >= 60 && gap <= UsagePace.maximumSampleGap
                    && window.resetsAt.map { $0 > usage.readAt } == true
                    && !dropped && prior.provider == usage.provider
                if continuous {
                    deltas.append(SuggestionDelta(
                        windowKey: windowKey, accountRef: accountRef,
                        from: prior.usedPercent, to: window.usedPercent,
                        usedDelta: window.usedPercent - prior.usedPercent, seconds: gap))
                }
            }
        }
        return Result(observations: observations, deltas: deltas, resets: resets)
    }

    public static func key(provider: UsageProvider, accountRef: String, windowKey: String) -> String {
        "\(provider.rawValue)\u{1f}\(accountRef)\u{1f}\(windowKey)"
    }

    private static func resetShiftIsConsistent(_ old: Date, _ new: Date, _ windowKey: String) -> Bool {
        let parts = windowKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1, let minutes = Double(parts[1]), minutes > 0 else { return false }
        let cycle = minutes * 60
        let shift = abs(new.timeIntervalSince(old))
        let cycles = (shift / cycle).rounded()
        return cycles >= 1 && abs(shift - cycles * cycle) <= 60
    }
}
