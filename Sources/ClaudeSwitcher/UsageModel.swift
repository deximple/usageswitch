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
    private(set) var refreshedWithoutClaudeStatus = false
    /// Drain speed per window key; `unknown` until two readings line up.
    @Published private(set) var pace: [String: UsagePace.Reading] = [:]
    /// Guide / All Usage, not persisted.
    @Published var segment: Segment
    /// Whether the collapsed Guide auxiliary is open; memory only, starts closed.
    @Published var guideExpanded = false
    let isDemo: Bool

    private let settings: SwitcherModel
    private var generation = 0
    private var abandonedRefreshes = 0
    private var abandonedRefreshGenerations: Set<Int> = []
    private var pendingRefresh = false
    /// The in-flight refresh; a consent change cancels it so superseded work
    /// can't overwrite revoked-provider values.
    private var refreshTask: Task<Void, Never>?
    private var suggestionStore: SuggestionStateStore?
    /// Original fixture rows for consent substitution — demo never destroys them.
    private var demoRows: [AccountUsage] = []
    private var claudeBindings: [ClaudeProfileBinding]
    private var timer: Timer?
    /// When the in-flight (or last) read began; the refresh policy compares resets against it.
    private var lastReadStartedAt: Date?
    private var refreshStartedAt: Date?
    /// Last ok sample per window key, for pace. Session-scoped: a restart starts over.
    private var previousSamples: [String: UsagePace.Sample] = [:]
    /// Window keys that already alerted, per `UsageAlerts` hysteresis rules.
    private var alertedKeys: Set<String> = []

    static let interval: TimeInterval = 300
    static let tick: TimeInterval = 30
    private static let suggestionCatalog = try? SuggestionCatalog.bundled()

    init(settings: SwitcherModel) {
        self.settings = settings
        segment = .guide
        isDemo = false
        claudeBindings = settings.claudeUsageProfiles
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickNow() }
        }
    }

    init(demo: [AccountUsage], segment: Segment = .guide, isRefreshing: Bool = false,
         settings: SwitcherModel) {
        self.settings = settings
        self.segment = segment
        claudeBindings = []
        usages = demo
        // Inventory comes from the fixture rows only — a demo never runs live discovery.
        let fixtureRoot = URL(fileURLWithPath: "/usage-switch-fixture")
        installations = UsageProvider.allCases.filter { provider in demo.contains { $0.provider == provider } }
            .map {
                UsageInstallation(provider: $0, cli: fixtureRoot.appendingPathComponent("bin/\($0.rawValue)"),
                                  app: [.claude, .codex, .cursor].contains($0)
                                    ? fixtureRoot.appendingPathComponent("\($0.rawValue).app") : nil)
            }
        demoRows = demo
        self.isRefreshing = isRefreshing
        isDemo = true
    }

    var pins: Set<String> { Set(settings.usagePins) }

    func suggestionResult(now: Date = Date()) -> SuggestionResult {
        guard let catalog = Self.suggestionCatalog else { return .none(.noCandidates) }
        return SuggestionEngine.suggest(
            mode: settings.effectiveSuggestionMode(now: now),
            task: settings.suggestionTask,
            catalog: catalog,
            harnessMap: .standard,
            usages: usages,
            pace: pace,
            now: now,
            warnThreshold: Double(settings.usageWarnPercent))
    }

    func hasSuggestion(now: Date = Date()) -> Bool {
        switch suggestionResult(now: now) {
        case .suggest, .neutral:
            return true
        case .none:
            return !UsageGuidance.proposals(usages, now: now,
                                            warnAt: Double(settings.usageWarnPercent)).isEmpty
        }
    }

    func suggestionModelName(for key: String) -> String? {
        Self.suggestionCatalog?.models.first { $0.key == key }?.name
    }

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
            let fresh = usage.windows.filter {
                !($0.isStale(now: now)) && $0.usedPercent.isFinite
            }
            for window in MenuBarTitle.preferredUsageWindows(fresh) {
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

    private func restartStalledRefreshIfAllowed() -> Bool {
        guard UsageRefreshPolicy.shouldRestartStalledRefresh(
            startedAt: refreshStartedAt, now: Date(), abandoned: abandonedRefreshes) else { return false }
        abandonedRefreshes += 1
        abandonedRefreshGenerations.insert(generation)
        refresh()
        return true
    }

    /// A tick is not a manual refresh: it waits out a busy Codex tab and fires on the interval or
    /// when a window reset since the last read began.
    private func tickNow() {
        guard !isDemo else { return }
        if isRefreshing {
            _ = restartStalledRefreshIfAllowed()
            return
        }
        guard !AppModel.codex.isBusy else { return }
        if UsageRefreshPolicy.isDue(now: Date(), nextRefresh: nextRefresh,
                                    lastReadStartedAt: lastReadStartedAt, usages: usages) {
            refresh()
        }
    }

    func refresh() {
        guard !isDemo else { return }
        pendingRefresh = false
        refreshedWithoutClaudeStatus = AppModel.shared.status == nil
        generation += 1
        let generation = generation
        isRefreshing = true
        let startedAt = Date()
        refreshStartedAt = startedAt
        lastReadStartedAt = startedAt
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        let enabled = settings.enabledUsageProviders
        let bindings = settings.claudeUsageProfiles
        let registeredClaudeIds = Set(AppModel.shared.status?.accounts.map(\.id) ?? [])
        let activeBindings = bindings.filter { registeredClaudeIds.contains($0.accountId) }
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
                        let binaryPaths = installation.cli.map { [$0] } ?? []
                        var rows = [ClaudeUsageCollector(runner: runner,
                            binaryPaths: binaryPaths).collect()]
                        let excludedRoots = [env.claudeUserData, env.storeDir]
                        for binding in activeBindings {
                            if Task.isCancelled { break }
                            if let row = ClaudeProfileUsageCollector(binding: binding, runner: runner,
                                home: env.home, managed: .system, binaryPaths: binaryPaths,
                                excludedRoots: excludedRoots).collect() {
                                rows.append(row)
                            }
                        }
                        return rows
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

    func requestRefresh() {
        guard !isDemo else { return }
        if isRefreshing {
            if !restartStalledRefreshIfAllowed() {
                pendingRefresh = true
            }
        } else {
            refresh()
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
        suggestionStore?.invalidateBefore(generation)
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

    func applyClaudeProfiles(_ bindings: [ClaudeProfileBinding]) {
        guard !isDemo else { return }
        generation += 1
        refreshTask?.cancel()
        suggestionStore?.invalidateBefore(generation)
        let next = Dictionary(uniqueKeysWithValues: bindings.map { ($0.accountId, $0) })
        for old in claudeBindings where next[old.accountId] != old {
            let rowID = "claude:app:\(old.accountId)"
            usages.removeAll { $0.id == rowID }
            clearPace(rowID: rowID)
        }
        claudeBindings = bindings
        refresh()
    }

    /// Identity presentations for the current readings. Demo passes registry
    /// metadata ONLY for providers present in its fixture inventory — canned
    /// accounts can never leak into a fixture that doesn't show that provider.
    func presentations(claude: SwitcherStatus?, codex: CodexStatus?, now: Date = Date())
        -> [UsageAccountPresentation] {
        var claude = claude, codex = codex
        if isDemo {
            let present = Set(installations.map { $0.provider })
            if !present.contains(.claude) { claude = nil }
            if !present.contains(.codex) { codex = nil }
        }
        return UsagePresentations.accounts(readings: usages, installations: installations,
                                           claude: claude, codex: codex, now: now)
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

    private func clearPace(rowID: String) {
        let prefix = rowID + "/"
        pace = pace.filter { !$0.key.hasPrefix(prefix) }
        previousSamples = previousSamples.filter { !$0.key.hasPrefix(prefix) }
        alertedKeys = alertedKeys.filter { !$0.hasPrefix(prefix) }
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
        guard generation == self.generation else {
            if abandonedRefreshGenerations.remove(generation) != nil {
                abandonedRefreshes = max(0, abandonedRefreshes - 1)
            }
            return
        }
        let now = Date()
        installations = installed
        // Same-login subscription readings keep their previous windows on failure; every other
        // case stands on its own — AccountUsage.retainingWindows decides, fail-closed.
        usages = UsageInstallations.visible(fresh, installations: installed).map { reading in
            reading.retainingWindows(from: usages.first(where: { $0.id == reading.id }))
        }
        updatePace()
        if fresh.contains(where: { $0.state == .ok }) {
            let store = suggestionStore ?? SuggestionStateStore(env: env, fs: SafeFS(env: env))
            suggestionStore = store
            Task.detached(priority: .utility) {
                store.record(fresh, now: now, generation: generation)
            }
        }
        // The `--cli usage` file: display-safe identity, authentication and window
        // data only — labels always email-masked, never credentials or raw emails.
        if AppModel.shared.status != nil {
            try? UsageSnapshot(presentations: presentations(claude: settings.status,
                                                            codex: AppModel.codex.status,
                                                            now: now),
                               generatedAt: now)
                .write(env: env, fs: SafeFS(env: env))
        }
        deliverAlerts(now: now)
        isRefreshing = false
        refreshStartedAt = nil
        nextRefresh = now.addingTimeInterval(Self.interval)
        if pendingRefresh {
            pendingRefresh = false
            refresh()
        }
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
