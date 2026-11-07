import AppKit
import Foundation
import ServiceManagement
import SwitcherCore

/// UI state. All Switcher work runs off the main thread; results are published on the main actor.
@MainActor
final class SwitcherModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(action: String)
        case awaitingLogin
    }

    struct Banner: Equatable {
        enum Kind { case success, error, info }
        let kind: Kind
        let text: String
    }

    @Published private(set) var status: SwitcherStatus?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [SwitchStep] = []
    @Published var banner: Banner?
    @Published var pendingConfirmation: PendingAction?
    /// The account whose name is being edited, and the edited text (kept here so every window shows the same).
    @Published var renaming: AccountStatus?
    @Published var renameDraft = ""
    @Published var revealedEmails: Set<String> = []
    /// True until startup recovery has finished; actions stay disabled meanwhile.
    @Published private(set) var recovering = false
    /// The saved language choice; nil follows the system language.
    @Published private(set) var languageChoice: AppLanguage?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var menuBarShowsName = true
    /// Emails unmasked everywhere (rows, headers, menu bar), instead of masked until clicked.
    @Published private(set) var showEmails = false
    /// Usage windows the user pinned in the Priority view.
    @Published private(set) var usagePins: [String] = []
    /// Show the most constrained usage window in the menu bar instead of the account name.
    @Published private(set) var menuBarShowsUsage = true
    /// Cursor usage is opt-in: it reads Cursor's sign-in and calls Cursor's API.
    @Published private(set) var cursorUsageEnabled = false
    /// Consent grants for the four new consent-required providers (not Cursor's SSOT).
    @Published private(set) var usageConnections: Set<UsageProvider> = []
    @Published private(set) var claudeUsageProfiles: [ClaudeProfileBinding] = []
    /// Appearance choice persisted in settings; system follows the OS live.
    @Published private(set) var appearanceChoice: AppAppearance = .system
    @Published private(set) var usageWarnPercent = 80
    @Published private(set) var usageAlertsEnabled = true
    let isDemo: Bool

    struct PendingAction: Identifiable, Equatable {
        enum Kind: Equatable { case switchTo(String, force: Bool), capture, enroll, remove(String) }
        let id = UUID()
        let kind: Kind
        let title: String
        let codeSessions: Int
        /// Requested through the app's URL scheme (possibly from a web page): Return must not confirm it.
        var fromURL = false
        /// Confirmation text for actions that don't restart Claude.
        var detail = ""
    }

    private let switcher: Switcher
    private var timer: Timer?
    private var refreshGeneration = 0

    init(switcher: Switcher = Switcher(), demo: SwitcherStatus? = nil, demoPhase: Phase = .idle,
         demoSteps: [SwitchStep] = [], demoBanner: Banner? = nil) {
        self.switcher = switcher
        isDemo = demo != nil
        let settings = SwitcherSettings.load(env: switcher.env)
        languageChoice = settings.language
        // Demo screens always use the defaults, so screenshots stay masked whatever the real settings are.
        menuBarShowsName = demo == nil ? settings.effectiveMenuBarShowsName : true
        showEmails = demo == nil ? settings.effectiveShowEmails : false
        usagePins = demo == nil ? settings.effectiveUsagePins : []
        menuBarShowsUsage = demo == nil ? settings.effectiveMenuBarShowsUsage : true
        cursorUsageEnabled = demo == nil ? settings.effectiveCursorUsageEnabled : false
        usageConnections = demo == nil
            ? settings.enabledUsageProviders.subtracting([.cursor]) : []
        claudeUsageProfiles = demo == nil ? settings.effectiveClaudeUsageProfiles : []
        appearanceChoice = demo == nil ? settings.effectiveAppearance : .system
        usageWarnPercent = demo == nil ? settings.effectiveUsageWarnPercent : 80
        usageAlertsEnabled = demo == nil ? settings.effectiveUsageAlertsEnabled : true
        status = demo
        phase = demoPhase
        steps = demoSteps
        banner = demoBanner
        guard demo == nil else { return }
        recovering = true
        Task.detached(priority: .userInitiated) { [switcher] in
            let report = switcher.recoverIfNeeded()
            let s = switcher.status()
            // Notes that are also current status warnings are shown once, as warnings.
            let notes = report.filter { !s.warnings.contains($0) }
            await MainActor.run {
                if !notes.isEmpty { self.banner = Banner(kind: .info, text: notes.joined(separator: " · ")) }
                self.apply(s)
                self.recovering = false
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfIdle() }
        }
    }

    var isBusy: Bool {
        if recovering { return true }
        if case .working = phase { return true }
        return false
    }

    func refreshIfIdle() {
        if case .working = phase { return }
        refresh()
    }

    func refresh() {
        guard !isDemo else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let switcher = self.switcher
        Task.detached(priority: .userInitiated) {
            let s = switcher.status()
            await MainActor.run {
                if generation == self.refreshGeneration { self.apply(s) }
            }
        }
    }

    private func setStatus(_ s: SwitcherStatus) {
        let oldAccountIds = status.map { Set($0.accounts.map(\.id)) }
        let newAccountIds = Set(s.accounts.map(\.id))
        status = s
        guard !isDemo else { return }
        if UsageRefreshPolicy.shouldRefreshAfterClaudeStatusChange(
            oldAccountIds: oldAccountIds,
            newAccountIds: newAccountIds,
            refreshedWithoutClaudeStatus: AppModel.usage.refreshedWithoutClaudeStatus) {
            AppModel.usage.requestRefresh()
        }
    }

    private func apply(_ s: SwitcherStatus) {
        setStatus(s)
        // Picks up an approval given in System Settings after the checkbox was ticked.
        if !isDemo { launchAtLogin = SMAppService.mainApp.status == .enabled }
        guard phase == .awaitingLogin, s.claude.activeAccountUuid != nil else { return }
        if let active = s.activeAccount {
            if active.snapshot != .ready { banner = Banner(kind: .info, text: L10n.t(.uiLoginDetected, Self.displayLabel(active))) }
        } else {
            // Signed in to an account that isn't saved yet.
            banner = Banner(kind: .info, text: L10n.t(.uiLoginDetectedNew))
        }
    }

    // MARK: - Actions

    func requestSwitch(_ account: AccountStatus) {
        request(.switchTo(account.id, force: false), title: L10n.t(.uiActionSwitchTo, Self.displayLabel(account)))
    }

    /// Entry point for the `<scheme>://switch` URL; waits for the first status load if needed.
    func requestSwitch(id: String, force: Bool) {
        guard !isDemo, !isBusy, pendingConfirmation == nil, renaming == nil else { return }
        Task { @MainActor in
            for _ in 0..<40 where status == nil { try? await Task.sleep(for: .milliseconds(250)) }
            // Unknown ids are dropped silently; nothing from the URL is echoed into the UI.
            guard let account = status?.accounts.first(where: { $0.id == id }), !isBusy, pendingConfirmation == nil else { return }
            // URL requests can originate from a web page, so they always need an explicit click to proceed.
            request(.switchTo(account.id, force: force),
                    title: L10n.t(force ? .uiActionReapply : .uiActionSwitchTo, Self.displayLabel(account)),
                    alwaysConfirm: true, fromURL: true)
        }
    }

    func requestCapture() { request(.capture, title: L10n.t(.uiActionCapture)) }
    func requestEnroll() { request(.enroll, title: L10n.t(.uiActionEnroll)) }

    /// Deleting a saved sign-in can't be undone, so it is always confirmed.
    func requestRemove(_ account: AccountStatus) {
        guard !isBusy, !isDemo, !account.isActive, renaming == nil else { return }
        pendingConfirmation = Self.removeConfirmation(for: account)
    }

    static func removeConfirmation(for account: AccountStatus) -> PendingAction {
        let label = displayLabel(account)
        return PendingAction(kind: .remove(account.id), title: L10n.t(.uiActionRemove, label), codeSessions: 0,
                             detail: L10n.t(.uiRemoveSavedConfirm, label))
    }

    func requestRename(_ account: AccountStatus) {
        guard !isBusy, pendingConfirmation == nil, renaming == nil else { return }
        renameDraft = account.customName ?? ""
        renaming = account
    }

    /// Named only by the start of its id: nothing showed its email or display name.
    static func needsName(_ account: AccountStatus) -> Bool {
        account.customName == nil && account.email == nil && account.defaultName == String(account.accountUuid.prefix(8))
    }

    /// Saves the name off the main thread; a blank name goes back to the default one. Demo screens don't save.
    func rename(_ account: AccountStatus, to name: String) {
        renaming = nil
        guard !isDemo else { return }
        let switcher = self.switcher
        Task.detached(priority: .userInitiated) {
            let result = Result { try switcher.renameAccount(account.id, to: name) }
            let s = switcher.status()
            await MainActor.run {
                self.apply(s)
                if case .failure(let error) = result {
                    self.banner = Banner(kind: .error, text: (error as? SwitcherError)?.description ?? error.localizedDescription)
                }
            }
        }
    }

    private func request(_ kind: PendingAction.Kind, title: String, alwaysConfirm: Bool = false, fromURL: Bool = false) {
        guard !isBusy, !isDemo, renaming == nil else { return }
        let sessions = status?.claude.codeSessions ?? 0
        if alwaysConfirm || sessions > 0 || kind == .enroll {
            pendingConfirmation = PendingAction(kind: kind, title: title, codeSessions: sessions, fromURL: fromURL)
        } else {
            // Not confirmed: the core re-counts Code sessions and asks via .needsConfirmation if any appeared.
            perform(kind, title: title, confirmed: false)
        }
    }

    func confirm(_ action: PendingAction) {
        pendingConfirmation = nil
        guard !isDemo else { return }   // demo screens never reach the real switcher
        perform(action.kind, title: action.title, confirmed: true)
    }

    private func perform(_ kind: PendingAction.Kind, title: String, confirmed: Bool) {
        phase = .working(action: title)
        steps = []
        banner = nil
        let switcher = self.switcher
        // Names for result banners, resolved now (masked like the rows) instead of echoing raw emails.
        let names = Dictionary((status?.accounts ?? []).map { ($0.id, Self.displayLabel($0)) }, uniquingKeysWith: { a, _ in a })
        let report: @Sendable (SwitchStep) -> Void = { step in
            Task { @MainActor in self.steps.append(step) }
        }
        Task.detached(priority: .userInitiated) {
            let outcome: Result<String, Error>
            var unnamedCapture: String?
            do {
                switch kind {
                case .switchTo(let id, let force):
                    let r = try switcher.switchTo(id, confirmed: confirmed, force: force, progress: report)
                    let name = names[id] ?? r.to.email.map(Privacy.maskEmail) ?? r.to.accountUuid
                    var text = r.outcome == "already_active" ? L10n.t(.uiResultAlreadyActive, name)
                        : L10n.t(.uiResultSwitched, name, Int(r.durationSeconds))
                    if r.displacedPrevious != nil { text += " " + L10n.t(.uiResultDisplaced) }
                    outcome = .success(text)
                case .capture:
                    let snap = try switcher.captureCurrent(confirmed: confirmed, progress: report)
                    if snap.manifest.identity.email == nil { unnamedCapture = snap.manifest.identity.key }
                    outcome = .success(L10n.t(.uiResultCaptured,
                                              snap.manifest.identity.email.map(Privacy.maskEmail) ?? L10n.t(.uiResultCurrentAccount)))
                case .enroll:
                    try switcher.beginEnrollment(confirmed: confirmed, progress: report)
                    outcome = .success(L10n.t(.uiResultEnrollReady))
                case .remove(let id):
                    try switcher.removeSaved(id)
                    outcome = .success(L10n.t(.uiRemoveSavedDone, names[id] ?? id))
                }
            } catch {
                outcome = .failure(error)
            }
            let status = switcher.status()
            let askName = unnamedCapture
            await MainActor.run {
                self.setStatus(status)
                switch outcome {
                case .success(let text):
                    self.banner = Banner(kind: .success, text: text)
                    self.phase = kind == .enroll ? .awaitingLogin : .idle
                    // Nothing showed this account's email: ask for a name right away instead of showing an id prefix.
                    if let askName, let row = status.accounts.first(where: { $0.id == askName }), Self.needsName(row),
                       self.pendingConfirmation == nil {
                        self.renameDraft = ""
                        self.renaming = row
                    }
                case .failure(SwitcherError.needsConfirmation(let n)):
                    // Sessions appeared since the last refresh: ask again with the fresh count.
                    self.phase = .idle
                    self.steps = []
                    self.pendingConfirmation = PendingAction(kind: kind, title: title, codeSessions: n)
                case .failure(let error):
                    self.banner = Banner(kind: .error, text: (error as? SwitcherError)?.description ?? error.localizedDescription)
                    self.phase = .idle
                }
            }
        }
    }

    // MARK: - Settings

    var language: AppLanguage { languageChoice ?? AppLanguage.system() }

    /// A `--lang` launch override: shown without being saved.
    func previewLanguage(_ language: AppLanguage) {
        languageChoice = language
        L10n.language = language
    }

    /// Applies immediately; the demo screens change the language without saving it.
    func setLanguage(_ choice: AppLanguage?) {
        let before = languageChoice
        languageChoice = choice
        if !saveSettings({ $0.language = choice }) { languageChoice = before }
        L10n.language = language
        refreshIfIdle()   // status warnings are produced by the core in the current language
    }

    func setMenuBarShowsName(_ on: Bool) {
        let before = menuBarShowsName
        menuBarShowsName = on
        if !saveSettings({ $0.menuBarShowsName = on }) { menuBarShowsName = before }
    }

    /// Turning it either way also forgets the emails revealed one by one, so turning it off masks everything again.
    func setShowEmails(_ on: Bool) {
        let before = showEmails
        showEmails = on
        revealedEmails = []
        if !saveSettings({ $0.showEmails = on }) { showEmails = before }
    }

    func setUsagePins(_ pins: [String]) {
        let before = usagePins
        usagePins = pins
        if !saveSettings({ $0.usagePins = pins.isEmpty ? nil : pins }) { usagePins = before }
    }

    func setMenuBarShowsUsage(_ on: Bool) {
        let before = menuBarShowsUsage
        menuBarShowsUsage = on
        if !saveSettings({ $0.menuBarShowsUsage = on }) { menuBarShowsUsage = before }
    }

    /// system is stored as nil so old and new settings files both mean "follow macOS".
    func setAppearance(_ choice: AppAppearance) {
        let before = appearanceChoice
        appearanceChoice = choice
        if !saveSettings({ $0.appearance = choice == .system ? nil : choice.rawValue }) { appearanceChoice = before }
    }

    func setCursorUsageEnabled(_ on: Bool) {
        let before = cursorUsageEnabled
        cursorUsageEnabled = on
        if !saveSettings({ $0.cursorUsageEnabled = on }) { cursorUsageEnabled = before }
    }

    /// One entry point for any consent-required provider; Cursor delegates to its own
    /// SSOT. The setter performs no dialog — the caller asks first when turning on.
    func setUsageConnection(_ provider: UsageProvider, on: Bool) {
        guard provider.requiresConsent else { return }
        if provider == .cursor { setCursorUsageEnabled(on); return }
        let before = usageConnections
        if on { usageConnections.insert(provider) } else { usageConnections.remove(provider) }
        if !saveSettings({
            $0.usageConnections = self.usageConnections.isEmpty
                ? nil : self.usageConnections.map { $0.rawValue }.sorted()
        }) { usageConnections = before }
    }

    func setClaudeUsageProfiles(_ bindings: [ClaudeProfileBinding]) -> Bool {
        guard !isDemo,
              Set(bindings.map(\.accountId)).count == bindings.count,
              Set(bindings.map(\.profilePath)).count == bindings.count
        else { return false }
        let before = claudeUsageProfiles
        claudeUsageProfiles = bindings
        guard saveSettings({
            $0.claudeUsageProfiles = bindings.isEmpty ? nil : bindings
        }) else {
            claudeUsageProfiles = before
            return false
        }
        return true
    }

    /// Detail-window name editing: nil restores the default name. Reuses the
    /// existing locked rename paths; demo writes fixture copies only.
    @MainActor func renameDisplayName(_ id: String, to name: String?) async throws {
        guard !isBusy, pendingConfirmation == nil, renaming == nil else {
            throw SwitcherError.anotherSwitchInProgress
        }
        let normalized = try AccountNames.validated(name)
        guard name == nil || normalized != nil else {
            throw SwitcherError.invalidAccountName(maxLength: AccountNames.maxLength)
        }
        guard !isDemo else {
            // demo applies the same validation + duplicate policy on fixture copies
            guard let status, status.accounts.contains(where: { $0.id == id }) else {
                throw SwitcherError.unknownAccount(id)
            }
            if let name = normalized {
                let folded = SwitcherAccount.fold(name)
                let dup = status.accounts.contains {
                    $0.id != id && (SwitcherAccount.fold($0.label) == folded
                        || SwitcherAccount.fold($0.defaultName) == folded
                        || $0.email.map { SwitcherAccount.fold($0) } == folded)
                }
                if dup { throw SwitcherError.duplicateAccountName(name) }
            }
            setStatus(SwitcherStatus(
                claude: status.claude,
                accounts: status.accounts.map { a in
                    a.id == id
                        ? AccountStatus(id: a.id, label: normalized ?? a.defaultName,
                                        customName: normalized, defaultName: a.defaultName,
                                        email: a.email, accountUuid: a.accountUuid,
                                        orgUuid: a.orgUuid, isActive: a.isActive,
                                        snapshot: a.snapshot, capturedAt: a.capturedAt,
                                        sessionExpiresAt: a.sessionExpiresAt)
                        : a
                },
                relaunchers: status.relaunchers,
                suspendedRelaunchers: status.suspendedRelaunchers,
                originalBackup: status.originalBackup,
                pendingJournal: status.pendingJournal,
                nativeMultiAccount: status.nativeMultiAccount,
                warnings: status.warnings))
            return
        }
        let switcher = self.switcher
        phase = .working(action: L10n.t(.usageRename))
        refreshGeneration += 1
        defer { phase = .idle }
        let renamedStatus = try await Task.detached {
            try switcher.renameAccount(id, to: normalized)
            return switcher.status()
        }.value
        setStatus(renamedStatus)
    }

    /// Fixture-only: mark the providers a demo fixture shows as connected, in
    /// memory only — no saveSettings, no real collector. Lets the consent toggles
    /// simulate revocation/restoration against the original fixture rows.
    func seedDemoConnections(_ providers: Set<UsageProvider>) {
        guard isDemo else { return }
        if providers.contains(.cursor) { cursorUsageEnabled = true }
        usageConnections.formUnion(providers.filter { $0.requiresConsent && $0 != .cursor })
    }

    /// The effective consent set the usage model reads.
    var enabledUsageProviders: Set<UsageProvider> {
        var out = usageConnections
        if cursorUsageEnabled { out.insert(.cursor) }
        return out
    }

    func setUsageWarnPercent(_ percent: Int) {
        let before = usageWarnPercent
        usageWarnPercent = percent
        if !saveSettings({ $0.usageWarnPercent = percent }) { usageWarnPercent = before }
    }

    func setUsageAlertsEnabled(_ on: Bool) {
        let before = usageAlertsEnabled
        usageAlertsEnabled = on
        if !saveSettings({ $0.usageAlertsEnabled = on }) { usageAlertsEnabled = before }
    }

    /// Whether an email (by row id) is shown unmasked.
    func isRevealed(_ id: String) -> Bool { showEmails || revealedEmails.contains(id) }

    /// Changes only the given settings; the others are kept. Demo screens never save. A failure is shown in an alert
    /// (it can come from either tab) and the caller puts the old value back.
    private func saveSettings(_ change: (inout SwitcherSettings) -> Void) -> Bool {
        guard !isDemo else { return true }
        do {
            try SwitcherSettings.update(env: switcher.env, fs: switcher.fs) { change(&$0) }
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t(.uiSettings)
            alert.informativeText = (error as? SwitcherError)?.description ?? error.localizedDescription
            NSApp.activate()
            alert.runModal()
            return false
        }
    }

    /// This app's data folder (saved sign-ins, names, settings).
    var dataFolder: URL { switcher.env.storeDir }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // The login-launch fallback in AppDelegate only trusts logins that happen after this.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.launchAtLoginEnabledAtKey)
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            banner = Banner(kind: .error, text: L10n.t(.uiLaunchAtLoginFailed, error.localizedDescription))
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            // Registered but blocked in System Settings: say so instead of letting the checkbox snap back silently.
            banner = Banner(kind: .info, text: L10n.t(.uiLaunchAtLoginApproval, ProductInfo.name))
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Short menu bar title for the active account; emails are masked (the bar is visible when sharing screens)
    /// unless the user chose to always show them.
    var menuBarTitle: String? {
        MenuBarTitle.make(label: status?.activeAccount?.label, showsName: menuBarShowsName, showEmails: showEmails)
    }
    static let launchAtLoginEnabledAtKey = "launchAtLoginEnabledAt"
    /// Key in `revealedEmails` for the header's email.
    static let headerEmailID = "header"

    /// The name shown for an account: its label, with emails masked (an account without a custom name is
    /// named by its email, and a custom name may contain one).
    static func displayLabel(_ account: AccountStatus) -> String { displayName(account.label) }

    /// A name with any email in it masked (for labels that may contain one).
    nonisolated static func displayName(_ label: String) -> String { Privacy.maskEmails(in: label) }

    func toggleEmail(_ id: String) {
        guard !showEmails else { return }   // everything is shown already
        if revealedEmails.contains(id) { revealedEmails.remove(id) } else { revealedEmails.insert(id) }
    }
}
