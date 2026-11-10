import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion log read gate")
struct SuggestionLogReadGateTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRefreshGenerationBumpDoesNotDiscardTheResult() {
        var gate = SuggestionLogReadGate()
        #expect(gate.shouldStart(now: t0))
        let token = gate.begin()
        // Usage refreshes come and go while the log read runs; none of them touches the gate.
        let applied1 = gate.finish(token: token, now: t0.addingTimeInterval(30))
        #expect(applied1)
    }

    @Test func aDiscardedReadDoesNotStartTheThrottle() {
        var gate = SuggestionLogReadGate()
        let token = gate.begin()
        gate.invalidate()
        let applied2 = gate.finish(token: token, now: t0)
        #expect(!applied2)
        #expect(gate.shouldStart(now: t0.addingTimeInterval(1)))
    }

    @Test func anAppliedReadThrottlesForTenMinutes() {
        var gate = SuggestionLogReadGate()
        let token = gate.begin()
        let applied3 = gate.finish(token: token, now: t0)
        #expect(applied3)
        #expect(!gate.shouldStart(now: t0.addingTimeInterval(599)))
        #expect(gate.shouldStart(now: t0.addingTimeInterval(600)))
    }

    @Test func onlyOneReadRunsAtATime() {
        var gate = SuggestionLogReadGate()
        let token = gate.begin()
        #expect(!gate.shouldStart(now: t0))
        #expect(!gate.shouldStart(now: t0.addingTimeInterval(3600)))
        let applied4 = gate.finish(token: token, now: t0)
        #expect(applied4)
    }

    @Test func aStaleResultCannotEndANewerRead() {
        var gate = SuggestionLogReadGate()
        let old = gate.begin()
        gate.invalidate()
        let current = gate.begin()
        let applied5 = gate.finish(token: old, now: t0)
        #expect(!applied5)
        #expect(!gate.shouldStart(now: t0)) // the newer read is still running
        let applied6 = gate.finish(token: current, now: t0)
        #expect(applied6)
    }

    @Test func invalidatingClearsTheThrottle() {
        var gate = SuggestionLogReadGate()
        let token = gate.begin()
        let applied = gate.finish(token: token, now: t0)
        #expect(applied)
        gate.invalidate()
        #expect(gate.shouldStart(now: t0.addingTimeInterval(1)))
    }
}
