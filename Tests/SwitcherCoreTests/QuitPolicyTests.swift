import Testing
import SwitcherCore

@Suite("Quitting the app")
struct QuitPolicyTests {
    private func decide(switcherBusy: Bool = false, switcherDemo: Bool = false, codexBusy: Bool = false,
                        codexSigningIn: Bool = false, codexDemo: Bool = false) -> QuitPolicy.Decision {
        QuitPolicy.decide(switcherBusy: switcherBusy, switcherDemo: switcherDemo, codexBusy: codexBusy,
                          codexSigningIn: codexSigningIn, codexDemo: codexDemo)
    }

    @Test("an idle app quits at once")
    func idleQuits() {
        #expect(decide() == .now)
        #expect(!decide().waits)
    }

    @Test("a switch or a recovery under way waits for the user")
    func switchWaits() {
        #expect(decide(switcherBusy: true) == .waitForSwitch)
        #expect(decide(switcherBusy: true, codexBusy: true) == .waitForSwitch)
        #expect(decide(switcherBusy: true).waits)
    }

    @Test("another Codex action waits; a Codex sign-in is cancelled instead")
    func codexWaitsUnlessSigningIn() {
        #expect(decide(codexBusy: true) == .waitForCodex)
        #expect(decide(codexBusy: true, codexSigningIn: true) == .now)
    }

    @Test("a demo always quits: a snapshot of a busy screen ends instead of showing a window")
    func demoQuits() {
        // Audit D-05: `--snapshot` with `--ui-fixture switching` asked to quit, was refused as if a
        // real switch were running, and left a window up with the process still alive.
        #expect(decide(switcherBusy: true, switcherDemo: true) == .now)
        #expect(decide(codexBusy: true, codexDemo: true) == .now)
        #expect(decide(switcherBusy: true, switcherDemo: true, codexBusy: true) == .waitForCodex)
    }
}
