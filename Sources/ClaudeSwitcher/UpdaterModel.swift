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
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Menu action. Inert while disabled — wired up with the menu item in the
    /// consent/feed milestone so a disabled build never reaches Sparkle at all.
    func checkForUpdates() {
        guard enabled else { return }
        startIfAllowed()
        controller?.checkForUpdates(nil)
    }
}
