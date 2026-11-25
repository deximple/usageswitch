import Foundation
import Sparkle
import SwitcherCore

/// Owns the Sparkle updater controller. Until the bundle ships a feed URL and EdDSA
/// public key (`UpdaterLaunchPolicy` says enabled), this model constructs nothing and
/// starts nothing — the framework is bundled but completely inert.
@MainActor
final class UpdaterModel: ObservableObject {
    private(set) var decision: UpdaterLaunchPolicy.Decision
    private var controller: SPUStandardUpdaterController?
    /// Sparkle keeps its delegate weakly; made with the controller.
    private var relaunchGate: UpdateRelaunchGate?

    var enabled: Bool { decision == .enabled }

    init(bundle: Bundle = .main, isDemo: Bool) {
        decision = UpdaterLaunchPolicy.decide(
            feedURLString: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            isDemo: isDemo)
    }

    /// One-way latch: creates the controller and starts the updater the first time the
    /// policy allows it. Calls are free after that.
    func startIfAllowed() {
        guard enabled, controller == nil else { return }
        let gate = UpdateRelaunchGate()
        relaunchGate = gate
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil)
    }

    /// Menu action. Inert while disabled — wired up with the menu item in the
    /// consent/feed milestone so a disabled build never reaches Sparkle at all.
    func checkForUpdates() {
        guard enabled else { return }
        startIfAllowed()
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle asks before it quits the app to install an update. While a quit would be refused — a
/// switch, a recovery or a Codex action under way (`QuitPolicy`) — the relaunch waits, and goes
/// ahead on its own once the app could quit.
@MainActor
private final class UpdateRelaunchGate: NSObject, SPUUpdaterDelegate {
    private var pendingInstalls: [() -> Void] = []
    private var timer: Timer?

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppModel.quitDecision.waits else { return false }
        pendingInstalls.append(installHandler)
        guard timer == nil else { return true }
        // Common modes: the check keeps running while a menu is open.
        let check = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfIdle() }
        }
        RunLoop.main.add(check, forMode: .common)
        timer = check
        return true
    }

    private func installIfIdle() {
        guard !AppModel.quitDecision.waits else { return }
        timer?.invalidate()
        timer = nil
        let installs = pendingInstalls
        pendingInstalls = []
        installs.forEach { $0() }
    }
}
