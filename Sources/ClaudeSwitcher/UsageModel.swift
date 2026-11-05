import Foundation
import SwiftUI
import SwitcherCore

/// Usage tab state. Reads run off the main thread, sequentially, and a slower read never overwrites
/// a newer one. Usage is display-only: nothing switches, launches or signs out on a limit.
@MainActor
final class UsageModel: ObservableObject {
    enum Segment: String { case guide, all }

    @Published private(set) var usages: [AccountUsage] = []
    /// Which providers are on this Mac; empty until the first refresh finishes.
    @Published private(set) var installations: [UsageInstallation] = []
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
    /// The in-flight refresh; a consent change cancels it so superseded work
    /// can't overwrite revoked-provider values.
    private var refreshTask: Task<Void, Never>?
    /// Original fixture rows for consent substitution — demo never destroys them.
    private var demoRows: [AccountUsage] = []
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
        // Inventory comes from the fixture rows only — a demo never runs live discovery.
        installations = UsageProvider.allCases.filter { provider in demo.contains { $0.provider == provider } }
            .map { UsageInstallation(provider: $0, cli: nil, app: nil) }
        demoRows = demo
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        let enabled = settings.enabledUsageProviders
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .userInitiated) {
            let env = SwitcherEnvironment.live()
            let runner = SystemUsageProcessRunner()
            let installed = UsageInstallations.discover(
                home: env.home, path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                bundledCodexCLI: env.codexCLI)
            // Inventory first: uninstalled providers vanish before any subprocess starts.
            await MainActor.run { self.publishInventory(installed, generation: generation) }
            let transport = SystemUsageHTTPTransport()
            let http = SystemUsageHTTP(transport: transport)
            let credentials = UsageFileCredentialReader()
            let environment = ProcessInfo.processInfo.environment

            let fresh = await UsageCollection.collect(
                installations: installed,
                enabledProviders: enabled,
                collector: { installation in
                    if Task.isCancelled { return [] }
                    switch installation.provider {
                    case .claude:
                        // App-only Claude gets an empty path list: honest cliMissing, never a guessed binary.
                        return [ClaudeUsageCollector(runner: runner,
                            binaryPaths: installation.cli.map { [$0] } ?? []).collect()]
                    case .codex:
                        // App-only Codex falls back to the bundled path -> existing missing state.
                        return CodexUsageCollector(status: { CodexManager().status() },
                            runner: runner, codexCLI: installation.cli ?? env.codexCLI,
                            clientVersion: version).collect()
                    case .cursor:
                        return CursorUsageCollector(enabled: true, runner: runner,
                            http: http, home: env.home).collect()
                    case .grok:
                        return GrokUsageCollector(enabled: true, http: transport,
                            credentials: credentials, home: env.home,
                            environment: environment).collect()
                    case .gemini:
                        return GeminiUsageCollector(enabled: true, http: transport,
                            credentials: credentials, home: env.home,
                            environment: environment).collect()
                    case .devin:
                        return DevinUsageCollector(enabled: true, http: transport,
                            credentials: credentials, runner: runner,
                            cli: installation.cli, clientVersion: version,
                            home: env.home, environment: environment).collect()
                    case .opencode:
                        return OpenCodeUsageCollector(enabled: true, http: transport,
                            credentials: credentials, home: env.home,
                            environment: environment).collect()
                    }
                },
                didCollect: { provider, rows in
                    // Each provider's result lands promptly — a slow peer can't hold the UI hostage.
                    await MainActor.run { self.publishPartial(provider, rows, generation: generation) }
                })
            await MainActor.run {
                self.finish(fresh, installed: installed, generation: generation, env: env)
            }
        }
    }

    /// A consent grant/revocation: invalidate in-flight work immediately, swap the
    /// affected providers' visible rows (fresh grant -> real read next refresh;
    /// revoked installed tool -> neutral placeholder; revoked absent tool -> gone),
    /// then refresh with the new enabled set. Demo keeps fixture rows in memory.
    func applyConsent(_ enabled: Set<UsageProvider>) {
        if isDemo {
            // memory-only substitution from the original fixture rows, never a real read
            var out: [AccountUsage] = []
            for fixture in demoRows {
                if fixture.provider.requiresConsent && !enabled.contains(fixture.provider) {
                    out.append(UsageCollection.connectionRequired(fixture.provider))
                } else {
                    out.append(fixture)
                }
            }
            usages = out
            return
        }
        generation += 1
        refreshTask?.cancel()
        // revoked providers drop their rows now — installed ones leave a neutral
        // placeholder, absent ones disappear entirely
        for provider in UsageProvider.allCases where provider.requiresConsent
            && !enabled.contains(provider) {
            let rows = installations.contains(where: { $0.provider == provider })
                ? [UsageCollection.connectionRequired(provider)] : []
            usages = UsageCollection.replacing(provider: provider, readings: rows, in: usages)
            clearPace(provider)
        }
        refresh()
    }

    /// A single provider's fresh rows replace its previous rows in place; the
    /// remaining providers' values are untouched. Called on MainActor.
    private func publishPartial(_ provider: UsageProvider, _ rows: [AccountUsage], generation: Int) {
        guard generation == self.generation else { return }
        // retained-window policy + stable provider order live in the core seam
        usages = UsageCollection.replacing(provider: provider, readings: rows, in: usages)
        // Old pace/ETA may belong to a different login behind the same label —
        // drop it now; the final finish recomputes pace once.
        clearPace(provider)
    }

    /// Pace keys are "<provider>:<accountRef>:<window>" — clearing by prefix is
    /// the safe narrow drop until the single final updatePace rebuilds them.
    private func clearPace(_ provider: UsageProvider) {
        let prefix = provider.rawValue + ":"
        pace = pace.filter { !$0.key.hasPrefix(prefix) }
    }

    private func publishInventory(_ installed: [UsageInstallation], generation: Int) {
        guard generation == self.generation else { return }
        let removed = Set(installations.map { $0.provider }).subtracting(installed.map { $0.provider })
        installations = installed
        usages = UsageInstallations.visible(usages, installations: installed)
        removed.forEach { clearPace($0) }
    }

    private func finish(_ fresh: [AccountUsage], installed: [UsageInstallation],
                        generation: Int, env: SwitcherEnvironment) {
        guard generation == self.generation else { return }
        let now = Date()
        installations = installed
        // Same-login subscription readings keep their previous windows on failure; every other
        // case stands on its own — AccountUsage.retainingWindows decides, fail-closed.
        usages = UsageInstallations.visible(fresh, installations: installed).map { reading in
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
