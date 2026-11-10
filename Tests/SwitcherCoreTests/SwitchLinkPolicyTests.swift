import Testing
@testable import SwitcherCore

/// The `usageswitch://switch` decision table (audit B-04): a cold-launch link waits for recovery
/// and status, a mid-action link reports busy, an unknown id stays silent.
@Suite("switch link policy")
struct SwitchLinkPolicyTests {
    let known: Set<String> = ["a1", "b2"]

    private func decide(isDemo: Bool = false, recovering: Bool = false, hasStatus: Bool = true,
                        working: Bool = false, hasPending: Bool = false, renaming: Bool = false,
                        knownIDs: Set<String> = ["a1", "b2"], id: String = "a1",
                        force: Bool = false) -> SwitchLinkPolicy.Decision {
        SwitchLinkPolicy.decide(isDemo: isDemo, recovering: recovering, hasStatus: hasStatus,
                                working: working, hasPending: hasPending, renaming: renaming,
                                knownIDs: knownIDs, id: id, force: force)
    }

    @Test func demoIgnores() { #expect(decide(isDemo: true) == .ignore) }
    @Test func recoveringWaits() { #expect(decide(recovering: true) == .wait) }
    @Test func missingStatusWaits() { #expect(decide(hasStatus: false) == .wait) }
    @Test func workingIsBusy() { #expect(decide(working: true) == .busy) }
    @Test func pendingConfirmationIsBusy() { #expect(decide(hasPending: true) == .busy) }
    @Test func renamingIsBusy() { #expect(decide(renaming: true) == .busy) }
    @Test func unknownIDIgnores() { #expect(decide(id: "nope") == .ignore) }
    @Test func knownIDConfirms() { #expect(decide(id: "a1") == .confirm(id: "a1", force: false)) }
    @Test func forcedUnknownIDConfirms() {
        #expect(decide(id: "nope", force: true) == .confirm(id: "nope", force: true))
    }
}
