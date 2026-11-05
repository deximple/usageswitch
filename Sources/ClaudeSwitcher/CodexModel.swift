import AppKit
import Foundation
import SwitcherCore

/// Codex tab state. Work runs off the main thread; results are published on the main actor.
@MainActor
final class CodexModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        /// A browser sign-in is waiting (`id` is nil while adding a new account).
        case signingIn(id: String?)
    }

    struct Pending: Identifiable, Equatable {
        enum Kind: Equatable { case remove(String), hide(String), reauth(String), adopt(String) }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    @Published private(set) var status: CodexStatus?
    /// Account the guide's "View account" asked the Codex tab to scroll to. Memory only —
    /// navigation, never an open/sign-in/switch. A removed account just leaves it dangling.
    @Published var focusedAccountID: String?
    @Published private(set) var phase: Phase = .idle
    @Published var banner: SwitcherModel.Banner?
    @Published var pending: Pending?
    @Published var renaming: CodexAccount?
    @Published var renameDraft = ""
    @Published var revealedEmails: Set<String> = []
    /// The sign-in page of a running `codex login`, in case the browser didn't open (memory only).
    @Published private(set) var signInLink: URL?
    let isDemo: Bool

    private let manager: CodexManager
    private let stop = StopFlag()
    private var timer: Timer?
    /// Each refresh gets a number; a slower, older one never overwrites a newer result.
    private var refreshGeneration = 0
    /// Signalled by background work as soon as the manager is done (before the result reaches the main actor).
    private var workDone: DispatchSemaphore?

    init(manager: CodexManager = CodexManager(), demo: CodexStatus? = nil, demoPhase: Phase = .idle) {
        self.manager = manager
        isDemo = demo != nil
        status = demo
        phase = demoPhase
        guard demo == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfIdle() }
        }
    }

    var isBusy: Bool { phase != .idle }

    func refreshIfIdle() {
        guard phase == .idle else { return }
        refresh()
    }

    func refresh() {
        guard !isDemo else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let manager = self.manager
        Task.detached(priority: .userInitiated) {
            let status = manager.status()
            await MainActor.run { if generation == self.refreshGeneration { self.status = status } }
        }
    }

    var isSigningIn: Bool {
        if case .signingIn = phase { return true }
        return false
    }

    /// Quitting during a sign-in: cancel it, end its `codex login` and give the work a moment to clean up.
    func stopSignInForQuit() {
        guard isSigningIn, !isDemo else { return }
        cancelSignIn()
        manager.stopRunningCommands()
        _ = workDone?.wait(timeout: .now() + 3)
    }

    // MARK: - Actions

    func open(_ account: CodexAccount) {
        run { manager in
            try manager.open(account.id)
            return nil
        }
    }

    func add() {
        guard !isBusy, !isDemo else { return }
        signIn(id: nil) { manager, stop, onLink in
            let account = try manager.addAccount(shouldStop: stop, onLink: onLink)
            let added = L10n.t(.codexSignedIn, SwitcherModel.displayName(account.label))
            do {
                try manager.open(account.id)
            } catch let error as SwitcherError {
                // The account is kept; say so along with why its window didn't open.
                throw OpenAfterAddFailed(text: added + " " + error.description)
            }
            return added
        }
    }

    /// Adds a found home to the list; asks first when the same account is already listed (it may be a copy).
    func requestAdopt(_ found: CodexAccount) {
        guard !isBusy, !isDemo, pending == nil, renaming == nil else { return }
        let name = SwitcherModel.displayName(found.label)
        if let email = found.email, status?.accounts.contains(where: { $0.email == email }) == true {
            // The same check `codex adopt` makes without --yes.
            pending = Pending(kind: .adopt(found.id), title: L10n.t(.codexActionAdopt, name),
                              detail: L10n.t(.codexConfirmAdoptSame, SwitcherModel.displayName(email)))
        } else {
            adopt(found.id)
        }
    }

    func dismiss(_ found: CodexAccount) {
        run { manager in
            try manager.dismiss(found.id)
            return nil
        }
    }

    func requestReauth(_ account: CodexAccount) {
        guard !isBusy, !isDemo, pending == nil, renaming == nil else { return }
        guard account.state == .running else { return reauth(account) }
        // Its window has to close first: ask.
        pending = Pending(kind: .reauth(account.id), title: L10n.t(.codexActionReauth, SwitcherModel.displayName(account.label)),
                          detail: L10n.t(.codexConfirmReauth, SwitcherModel.displayName(account.label)))
    }

    func requestRemove(_ account: CodexAccount) {
        guard !isBusy, !isDemo, pending == nil, renaming == nil, account.kind != .standard else { return }
        let name = SwitcherModel.displayName(account.label)
        pending = account.kind == .managed
            ? Pending(kind: .remove(account.id), title: L10n.t(.codexActionRemove, name), detail: L10n.t(.codexConfirmRemove, name))
            : Pending(kind: .hide(account.id), title: L10n.t(.codexActionHide, name), detail: L10n.t(.codexConfirmHide, name))
    }

    /// Demo screens: shows the removal question for an example account.
    func requestDemoRemoval(_ account: CodexAccount?) {
        guard isDemo, let account else { return }
        let name = SwitcherModel.displayName(account.label)
        pending = Pending(kind: .remove(account.id), title: L10n.t(.codexActionRemove, name), detail: L10n.t(.codexConfirmRemove, name))
    }

    func confirm(_ action: Pending) {
        pending = nil
        guard !isDemo else { return }
        switch action.kind {
        case .reauth(let id):
            guard let account = status?.accounts.first(where: { $0.id == id }) else { return }
            reauth(account)
        case .adopt(let id):
            adopt(id)
        case .remove(let id), .hide(let id):
            run { manager in
                let account = try manager.remove(id)
                let name = SwitcherModel.displayName(account.label)
                return account.kind == .managed ? L10n.t(.codexRemoved, name) : L10n.t(.codexHidden, name)
            }
        }
    }

    func cancelSignIn() { stop.set(true) }

    func openSignInLink() {
        guard let signInLink else { return }
        NSWorkspace.shared.open(signInLink)
    }

    func unhideAll() {
        run { manager in
            try manager.unhideAll()
            return nil
        }
    }

    func requestRename(_ account: CodexAccount) {
        guard !isBusy, pending == nil, renaming == nil else { return }
        renameDraft = account.customName ?? ""
        renaming = account
    }

    func rename(_ account: CodexAccount, to name: String) {
        renaming = nil
        guard !isDemo else { return }
        run { manager in
            try manager.renameAccount(account.id, to: name)
            return nil
        }
    }

    /// A Terminal command that runs the Codex CLI with this account's home.
    func copyCommand(_ account: CodexAccount) {
        let command = account.kind == .standard ? "codex" : "CODEX_HOME=\(Self.shellQuoted(account.home)) codex"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        banner = .init(kind: .success, text: L10n.t(.codexCopied, command))
    }

    func revealInFinder(_ account: CodexAccount) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: account.home, isDirectory: true)])
    }

    func toggleEmail(_ id: String) {
        if revealedEmails.contains(id) { revealedEmails.remove(id) } else { revealedEmails.insert(id) }
    }

    static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: - Running work

    private func adopt(_ id: String) {
        run { manager in
            let account = try manager.adopt(id)
            return L10n.t(.codexAdopted, SwitcherModel.displayName(account.label))
        }
    }

    private func reauth(_ account: CodexAccount) {
        signIn(id: account.id) { manager, stop, onLink in
            let signedIn = try manager.reauthenticate(account.id, shouldStop: stop, onLink: onLink)
            return L10n.t(.codexSignedIn, SwitcherModel.displayName(signedIn.label))
        }
    }

    /// Runs a quick action off the main thread; a returned text becomes a success banner.
    private func run(_ work: @escaping @Sendable (CodexManager) throws -> String?) {
        guard !isBusy, !isDemo else { return }
        phase = .working
        banner = nil
        let manager = self.manager
        let done = DispatchSemaphore(value: 0)
        workDone = done
        Task.detached(priority: .userInitiated) {
            let result = Result { try work(manager) }
            done.signal()
            let status = manager.status()
            await MainActor.run { self.finish(result, status: status) }
        }
    }

    private func signIn(id: String?,
                        _ work: @escaping @Sendable (CodexManager, @escaping @Sendable () -> Bool,
                                                     @escaping @Sendable (URL) -> Void) throws -> String?) {
        guard !isBusy, !isDemo else { return }
        phase = .signingIn(id: id)
        banner = nil
        signInLink = nil
        stop.set(false)
        let manager = self.manager
        let stop = self.stop
        let done = DispatchSemaphore(value: 0)
        workDone = done
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try work(manager, { stop.get() }, { link in Task { @MainActor in self.signInLink = link } })
            }
            done.signal()
            let status = manager.status()
            await MainActor.run {
                self.signInLink = nil
                self.finish(result, status: status)
            }
        }
    }

    private func finish(_ result: Result<String?, Error>, status: CodexStatus) {
        refreshGeneration += 1   // a refresh started before this work must not overwrite its result
        self.status = status
        phase = .idle
        workDone = nil
        switch result {
        case .failure(let error as OpenAfterAddFailed): banner = .init(kind: .error, text: error.text)
        case .success(let text?): banner = .init(kind: .success, text: text)
        case .success(nil): break
        case .failure(SwitcherError.codexSignInCancelled): banner = .init(kind: .info, text: L10n.t(.errCodexSignInCancelled))
        case .failure(let error):
            banner = .init(kind: .error, text: (error as? SwitcherError)?.description ?? error.localizedDescription)
        }
    }
}

/// A cancel switch shared with background work.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// An account was added but its window didn't open.
struct OpenAfterAddFailed: Error { let text: String }
