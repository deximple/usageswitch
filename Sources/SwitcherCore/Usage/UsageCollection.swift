import Foundation

/// Focused scheduling seam for per-provider usage collection: up to 3 concurrent
/// jobs refilled continuously, deterministic allCases order, one job per provider.
/// This is not a configurable jobs framework — the shape is settled by the contract.
public enum UsageCollection {
    /// Whether a row is the installed-but-not-yet-connected placeholder the user can
    /// still opt in to: consent-required provider, connectionRequired, not already
    /// granted. Pure — no reads, no side effects, no tool calls.
    public static func canConnect(_ usage: AccountUsage,
                                  enabledProviders: Set<UsageProvider>) -> Bool {
        guard usage.provider.requiresConsent,
              !enabledProviders.contains(usage.provider)
        else { return false }
        if case .unavailable(.connectionRequired) = usage.state { return true }
        return false
    }

    public static let maxConcurrent = 3

    /// Collect readings for each installed provider. `enabledProviders` is the
    /// effective consent set; a consent-required provider not in it yields one
    /// stable connectionRequired placeholder WITHOUT invoking `collector` and is
    /// reported through `didCollect` immediately — it does not hold a worker slot.
    /// One in `hiddenProviders` (turned off by the user) reports no rows instead.
    /// Slots are refilled as each result arrives, so a stalled provider cannot
    /// prevent later providers starting. Cancellation is checked before each
    /// scheduling, before each child call, and before each callback.
    /// Returns rows flattened in fixed allCases order.
    public static func collect(
        installations: [UsageInstallation],
        enabledProviders: Set<UsageProvider>,
        hiddenProviders: Set<UsageProvider> = [],
        collector: @escaping @Sendable (UsageInstallation) async -> [AccountUsage],
        didCollect: @escaping @Sendable (UsageProvider, [AccountUsage]) async -> Void
    ) async -> [AccountUsage] {
        // allCases already unique; first-match dedups duplicate installations.
        var pending = UsageProvider.allCases.compactMap { provider in
            installations.first { $0.provider == provider }
        }

        var byProvider: [UsageProvider: [AccountUsage]] = [:]

        // consent placeholders emit via didCollect immediately, before any job runs
        pending.removeAll { job in
            guard job.provider.requiresConsent, !enabledProviders.contains(job.provider)
            else { return false }
            // A connection the user turned off leaves no row (its empty report drops a stale
            // one); a connection never turned on keeps the Connect usage placeholder.
            byProvider[job.provider] = hiddenProviders.contains(job.provider)
                ? [] : [connectionRequired(job.provider)]
            return true
        }
        for (provider, rows) in byProvider where !Task.isCancelled {
            await didCollect(provider, rows)
        }

        await withTaskGroup(of: (UsageInstallation, [AccountUsage]).self) { group in
            var inFlight = 0
            func nextJob() -> UsageInstallation? {
                pending.isEmpty ? nil : pending.removeFirst()
            }
            // conditions short-circuit BEFORE nextJob() consumes a pending job
            while !Task.isCancelled, inFlight < maxConcurrent, let job = nextJob() {
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return (job, []) }
                    return (job, await collector(job))
                }
            }
            for await (job, rows) in group {
                inFlight -= 1
                byProvider[job.provider] = rows
                if !Task.isCancelled { await didCollect(job.provider, rows) }
                if !Task.isCancelled, let next = nextJob() {
                    inFlight += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (next, []) }
                        return (next, await collector(next))
                    }
                }
            }
        }
        return UsageProvider.allCases.flatMap { byProvider[$0] ?? [] }
    }

    /// The stable installed-but-not-connected row — ids must match what the real
    /// collector emits so a consent change doesn't remount the row.
    public static func connectionRequired(_ provider: UsageProvider) -> AccountUsage {
        let id = provider == .cursor ? CursorUsageCollector.rowID : "\(provider.rawValue):current"
        let ref = provider == .cursor ? CursorUsageCollector.rowAccountRef : "current"
        return AccountUsage(id: id, provider: provider, accountRef: ref,
                            label: UsageText.providerName(provider),
                            plan: nil, windows: [], state: .unavailable(.connectionRequired),
                            readAt: Date(), toolVersion: nil)
    }

    /// Consent-required providers without a grant in `enabledProviders`, in `allCases` order.
    /// Nothing of theirs may stay on screen, in memory or in the snapshot file.
    public static func revokedProviders(enabledProviders: Set<UsageProvider>) -> [UsageProvider] {
        UsageProvider.allCases.filter { $0.requiresConsent && !enabledProviders.contains($0) }
    }

    /// The list right after a consent change, before the next read: every revoked provider's
    /// readings leave at once. One that is installed and not turned off (`hiddenProviders`) keeps
    /// the Connect usage placeholder; an absent or turned-off one leaves no row. Rows of granted
    /// and consent-free providers are untouched — the next read refreshes them.
    public static func applyingConsent(to usages: [AccountUsage],
                                       enabledProviders: Set<UsageProvider>,
                                       hiddenProviders: Set<UsageProvider>,
                                       installedProviders: Set<UsageProvider>,
                                       now: Date) -> [AccountUsage] {
        revokedProviders(enabledProviders: enabledProviders).reduce(usages) { rows, provider in
            let placeholder = installedProviders.contains(provider) && !hiddenProviders.contains(provider)
                ? [connectionRequired(provider)] : []
            return replacing(provider: provider, readings: placeholder, in: rows, now: now)
        }
    }

    /// A demo's consent change, worked out from its original fixture rows and never from a read:
    /// a revoked provider's row becomes the Connect usage placeholder in place, or goes when the
    /// provider is turned off; every other row is the fixture itself, so granting again restores it.
    public static func substitutingConsent(in fixtures: [AccountUsage],
                                           enabledProviders: Set<UsageProvider>,
                                           hiddenProviders: Set<UsageProvider>) -> [AccountUsage] {
        let revoked = Set(revokedProviders(enabledProviders: enabledProviders))
        return fixtures.compactMap { fixture -> AccountUsage? in
            guard revoked.contains(fixture.provider) else { return fixture }
            return hiddenProviders.contains(fixture.provider) ? nil : connectionRequired(fixture.provider)
        }
    }

    /// Drops what the collectors of `revoked` providers kept in memory between reads (access
    /// tokens, Cursor's renewal mark): a withdrawn consent leaves nothing behind to reuse.
    public static func forgetSignIns(of revoked: [UsageProvider],
                                     antigravity: AntigravityAccessTokenCache,
                                     gemini: GeminiAccessTokenCache,
                                     cursor: CursorRenewalAttemptCache) {
        if revoked.contains(.antigravity) { antigravity.clear() }
        if revoked.contains(.gemini) { gemini.clear() }
        if revoked.contains(.cursor) { cursor.clear() }
    }

    /// Pure merge for partial results: the provider's incoming rows keep
    /// retained windows from the rows they replace (same-login only, decided by
    /// `retainingWindows`), then land in fixed provider order so the visible
    /// grouping never jumps between refreshes.
    public static func replacing(provider: UsageProvider,
                                 readings: [AccountUsage],
                                 in current: [AccountUsage],
                                 now: Date) -> [AccountUsage] {
        let merged = readings.map { row in
            row.retainingWindows(from: current.first { $0.id == row.id }, now: now)
        }
        var out = current.filter { $0.provider != provider }
        out += merged
        return out.sorted { a, b in
            let ia = UsageProvider.allCases.firstIndex(of: a.provider) ?? .max
            let ib = UsageProvider.allCases.firstIndex(of: b.provider) ?? .max
            return ia != ib ? ia < ib : false // stable: provider order preserves row order
        }
    }
}
