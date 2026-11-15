import Foundation
import SwitcherCore
import Testing

private let feed = "https://example.com/usageswitch/appcast.xml"
private let key = Data(repeating: 7, count: 32).base64EncodedString()

@Suite("UpdaterLaunchPolicy")
struct UpdaterLaunchPolicyTests {
    @Test func enabledWhenFeedAndKeyAreValid() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: key, isDemo: false) == .enabled)
    }

    @Test func demoIsAlwaysDisabled() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: key, isDemo: true) == .disabledDemo)
    }

    @Test func missingFeedDisables() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: nil, publicEDKey: key, isDemo: false) == .disabledMissingFeedURL)
        #expect(UpdaterLaunchPolicy.decide(feedURLString: "", publicEDKey: key, isDemo: false) == .disabledMissingFeedURL)
    }

    @Test func nonHTTPSFeedDisables() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: "http://example.com/a.xml", publicEDKey: key, isDemo: false) == .disabledInvalidFeedURL)
        #expect(UpdaterLaunchPolicy.decide(feedURLString: "not a url", publicEDKey: key, isDemo: false) == .disabledInvalidFeedURL)
    }

    @Test func missingKeyDisables() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: nil, isDemo: false) == .disabledMissingPublicKey)
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: "", isDemo: false) == .disabledMissingPublicKey)
    }

    @Test func malformedKeyDisables() {
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: "!!!", isDemo: false) == .disabledInvalidPublicKey)
        // Valid base64 but not 32 bytes — Sparkle's EdDSA key is raw 32-byte.
        #expect(UpdaterLaunchPolicy.decide(feedURLString: feed, publicEDKey: "aGVsbG8=", isDemo: false) == .disabledInvalidPublicKey)
    }

    @Test("the shipped Info.plist never lets Sparkle install updates unattended")
    func shippedPlistDisallowsUnattendedInstalls() throws {
        // README and PRIVACY promise that installing an update always asks first. Without this key
        // Sparkle offers "Automatically download and install updates" once automatic checks are on.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any])
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] == nil)
    }

    @Test("a signed feed is never required without the key Sparkle demands with it")
    func signedFeedRequirementComesWithPreExtractionVerification() throws {
        // The feed is signed already, but no build requires it yet. When one does: Sparkle refuses
        // to start the updater if SURequireSignedFeed is set without
        // SUVerifyUpdateBeforeExtraction — that build could never update itself again.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let requiresSignedFeed = info["SURequireSignedFeed"] as? Bool ?? false
        let verifiesBeforeExtraction = info["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false
        #expect(!requiresSignedFeed || verifiesBeforeExtraction)
    }
}
