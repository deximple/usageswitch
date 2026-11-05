import Foundation
import SwiftUI
import SwitcherCore

/// Usage tab state. Reads run off the main thread, sequentially, and a slower read never overwrites
/// a newer one. Usage is display-only: nothing switches, launches or signs out on a limit.
@MainActor
final class UsageModel: ObservableObject {
    enum Segment: String { case guide, all }

    @Published private(set) var usages: [AccountUsage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefresh = Date().addingTimeInterval(300)
    /// Drain speed per window key; `unknown` until two readings line up.
    @Published private(set) var pace: [String: UsagePace.Reading] = [:]
    /// Guide / All Usage, not persisted.
    @Published var segment: Segment
    /// Whether the collapsed Guide auxiliary is open; memory only, starts closed.
    @Published var guideExpanded = false
    let isDemo: Bool

    private let settings: SwitcherModel
    private var generation = 0
    private var timer: Timer?
    /// When the in-flight (or last) read began; the refresh policy compares resets against it.
    private var lastReadStartedAt: Date?
    /// Last ok sample per window key, for pace. Session-scoped: a restart starts over.
    private var previousSamples: [String: UsagePace.Sample] = [:]
    /// Window keys that already alerted, per `UsageAlerts` hysteresis rules.
    private var alertedKeys: Set<String> = []

    static let interval: TimeInterval = 300
    static let tick: TimeInterval = 30

    init(settings: SwitcherModel) {
        self.settings = settings
        segment = .guide
        isDemo = false
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
    }

    init(demo: [AccountUsage], segment: Segment = .guide, isRefreshing: Bool = false,
         settings: SwitcherModel) {
        self.settings = settings
        self.segment = segment
        usages = demo
        self.isRefreshing = isRefreshing
        isDemo = true
    }

    var pins: Set<String> { Set(settings.usagePins) }

    func togglePin(_ key: String) {
        var next = Set(settings.usagePins)
        if next.contains(key) { next.remove(key) } else { next.insert(key) }
        settings.setUsagePins(next.sorted())
    }

    func label(of usage: AccountUsage) -> String {
        UsageText.accountLabel(usage, showEmails: settings.showEmails)
    }

    /// The window the menu bar shows when usage is on: a pinned one first, else the most-used.
    /// Only ok, fresh windows count — a stale or failed read is never shown as current.
    var menuBarTitle: String? {
        let now = Date()
        var pinned: UsageWindow?
        var best: UsageWindow?
        for usage in usages where usage.state == .ok
            && (0...600).contains(now.timeIntervalSince(usage.readAt)) {
            for window in usage.windows
            where !window.isStale(now: now) && window.usedPercent.isFinite {
                if pins.contains(UsagePriority.key(usage, window)),
                   (pinned?.usedPercent ?? -1) < window.usedPercent { pinned = window }
                if (best?.usedPercent ?? -1) < window.usedPercent { best = window }
            }
        }
        guard let window = pinned ?? best, UsageText.percentLeft(window.usedPercent) != nil else { return nil }
        return MenuBarTitle.usage(windowName: UsageText.name(of: window, scoped: false),
                                usedPercent: window.usedPercent)
    }

    // MARK: - Refreshing

    /// A tick is not a manual refresh: it waits out a busy Codex tab and fires on the interval or
    /// when a window reset since the last read began.
    private func tickNow() {
        guard !isDemo, !isRefreshing, !AppModel.codex.isBusy else { return }
        if UsageRefreshPolicy.isDue(now: Date(), nextRefresh: nextRefresh,
                                    lastReadStartedAt: lastReadStartedAt, usages: usages) {
            refresh()
        }
    }

    func refresh() {
        guard !isDemo else { return }
        generation += 1
        let generation = generation
        isRefreshing = true
        lastReadStartedAt = Date()
        let cursorEnabled = settings.cursorUsageEnabled
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        Task.detached(priority: .userInitiated) {
            let env = SwitcherEnvironment.live()
            let runner = SystemUsageProcessRunner()
            var next = [ClaudeUsageCollector(runner: runner).collect()]
            next += CodexUsageCollector(status: { CodexManager().status() }, runner: runner,
                                        codexCLI: env.codexCLI, clientVersion: version).collect()
            next += CursorUsageCollector(enabled: cursorEnabled, runner: runner,
                                         http: SystemUsageHTTP(), home: env.home).collect()
            await MainActor.run { self.finish(next, generation: generation, env: env) }
        }
    }

    private func finish(_ fresh: [AccountUsage], generation: Int, env: SwitcherEnvironment) {
        guard generation == self.generation else { return }
        let now = Date()
        // Same-login subscription readings keep their previous windows on failure; every other
        // case stands on its own — AccountUsage.retainingWindows decides, fail-closed.
        usages = fresh.map { reading in
            reading.retainingWindows(from: usages.first(where: { $0.id == reading.id }))
        }
        updatePace()
        // The `--cli usage` file: percentages and reset times only, labels always email-masked.
        try? UsageSnapshot(usages: usages, generatedAt: now, showEmails: settings.showEmails)
            .write(env: env, fs: SafeFS(env: env))
        deliverAlerts(now: now)
        isRefreshing = false
        nextRefresh = now.addingTimeInterval(Self.interval)
    }

    /// Pace compares each fresh ok window with the previous sample of the same window. Samples are
    /// rebuilt from scratch each refresh and only admitted windows (known identity, future reset)
    /// leave one — a failure, a missing identity or a login change breaks the chain on its own.
    private func updatePace() {
        var readings: [String: UsagePace.Reading] = [:]
        var nextSamples: [String: UsagePace.Sample] = [:]
        for usage in usages where usage.state == .ok {
            for window in usage.windows {
                let key = UsagePriority.key(usage, window)
                readings[key] = UsagePace.reading(window, previous: previousSamples[key],
                                                  now: usage.readAt, identityKey: usage.identityKey)
                guard usage.identityKey != nil,
                      let resetsAt = window.resetsAt, resetsAt > usage.readAt else { continue }
                nextSamples[key] = UsagePace.Sample(at: usage.readAt, usedPercent: window.usedPercent,
                                                    identityKey: usage.identityKey,
                                                    resetsAt: resetsAt,
                                                    durationMinutes: window.durationMinutes)
            }
        }
        previousSamples = nextSamples
        pace = readings
    }

    private func deliverAlerts(now: Date) {
        guard settings.usageAlertsEnabled else { return }
        let (alerts, alerted) = UsageAlerts.update(usages: usages,
                                                 threshold: Double(settings.usageWarnPercent),
                                                 alerted: alertedKeys, now: now)
        alertedKeys = alerted
        if !alerts.isEmpty { UsageNotifier.deliver(alerts) { label(of: $0.usage) } }
    }
}
