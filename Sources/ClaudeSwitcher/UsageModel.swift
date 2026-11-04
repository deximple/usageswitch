import Foundation
import SwiftUI
import SwitcherCore

/// Usage tab state. Reads run off the main thread, sequentially, and a slower read never overwrites
/// a newer one. Usage is display-only: nothing switches, launches or signs out on a limit.
@MainActor
final class UsageModel: ObservableObject {
    enum Segment: String { case priority, all }

    @Published private(set) var usages: [AccountUsage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefresh = Date().addingTimeInterval(300)
    /// Priority / All Usage, not persisted.
    @Published var segment: Segment
    let isDemo: Bool

    private let settings: SwitcherModel
    private var generation = 0
    private var timer: Timer?
    /// When the in-flight (or last) read began; the refresh policy compares resets against it.
    private var lastReadStartedAt: Date?

    static let interval: TimeInterval = 300
    static let tick: TimeInterval = 30

    init(settings: SwitcherModel) {
        self.settings = settings
        segment = .priority
        isDemo = false
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
    }

    init(demo: [AccountUsage], segment: Segment = .priority, settings: SwitcherModel) {
        self.settings = settings
        self.segment = segment
        usages = demo
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
        for usage in usages where usage.state == .ok {
            for window in usage.windows where !window.isStale(now: now) {
                if pins.contains(UsagePriority.key(usage, window)),
                   (pinned?.usedPercent ?? -1) < window.usedPercent { pinned = window }
                if (best?.usedPercent ?? -1) < window.usedPercent { best = window }
            }
        }
        guard let window = pinned ?? best else { return nil }
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
            await MainActor.run { self.finish(next, generation: generation) }
        }
    }

    private func finish(_ fresh: [AccountUsage], generation: Int) {
        guard generation == self.generation else { return }
        usages = fresh.compactMap { reading -> AccountUsage? in
            if reading.state == .ok { return reading }
            // A failed re-read keeps the previous windows, marked stale by their own readAt —
            // never shown as current.
            if let prev = usages.first(where: { $0.id == reading.id }), !prev.windows.isEmpty {
                return AccountUsage(id: reading.id, provider: reading.provider,
                                    accountRef: reading.accountRef, label: reading.label,
                                    plan: reading.plan ?? prev.plan, windows: prev.windows,
                                    state: reading.state, readAt: prev.readAt,
                                    toolVersion: reading.toolVersion)
            }
            // Not reporting with nothing to show stays out of the list entirely.
            return reading.state == .notReporting && reading.windows.isEmpty ? nil : reading
        }
        isRefreshing = false
        nextRefresh = Date().addingTimeInterval(Self.interval)
    }
}
