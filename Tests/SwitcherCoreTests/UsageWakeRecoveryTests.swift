import Foundation
import Testing
@testable import SwitcherCore

/// Audit D1-D-03: the first read after the Mac wakes often runs before the network is back, and
/// its failure used to stay on screen for the whole five-minute interval.
@Suite("Re-reading after the Mac wakes")
struct UsageWakeRecoveryTests {
    let woke = Date(timeIntervalSince1970: 1_000_000)
    let interval: TimeInterval = 300

    func row(_ state: UsageState, id: String = "grok:current") -> AccountUsage {
        AccountUsage(id: id, provider: .grok, accountRef: "current", label: "A", plan: nil,
                     windows: [], state: state, readAt: woke, toolVersion: nil)
    }

    /// The Mac woke with `before` on screen.
    func awake(_ before: [AccountUsage] = []) -> UsageWakeRecovery {
        UsageWakeRecovery().waking(at: woke, usages: before)
    }

    /// A read that ended `after` seconds past the wake; the regular next read is an interval later.
    /// Returns the wait until the next read and the recovery to carry on with.
    func next(_ recovery: UsageWakeRecovery, _ rows: [AccountUsage],
              after: TimeInterval) -> (wait: TimeInterval, recovery: UsageWakeRecovery) {
        let now = woke.addingTimeInterval(after)
        let result = recovery.nextRead(scheduled: now.addingTimeInterval(interval), usages: rows, now: now)
        return (result.at.timeIntervalSince(now), result.recovery)
    }

    @Test("without a wake, a failed read waits the regular interval")
    func noWake() {
        let result = next(UsageWakeRecovery(), [row(.failed(.network))], after: 5)
        #expect(result.wait == interval)
        #expect(result.recovery == UsageWakeRecovery())
    }

    @Test("after waking, a read that got no answer is read again in 30 s",
          arguments: [UsageProblem.network, .timeout, .refused])
    func unansweredReadIsRetried(problem: UsageProblem) {
        #expect(next(awake(), [row(.ok, id: "codex:a"), row(.failed(problem))], after: 5).wait == 30)
    }

    @Test("the waits grow and stop after three re-reads")
    func boundedBackoff() {
        let failed = [row(.failed(.network))]
        let first = next(awake(), failed, after: 5)
        let second = next(first.recovery, failed, after: 40)
        let third = next(second.recovery, failed, after: 110)
        let fourth = next(third.recovery, failed, after: 240)
        #expect([first.wait, second.wait, third.wait] == UsageWakeRecovery.retryDelays)
        #expect(UsageWakeRecovery.retryDelays == [30, 60, 120])
        // A read that keeps failing goes back to the regular interval: no endless vendor runs.
        #expect(fourth.wait == interval)
        #expect(next(fourth.recovery, failed, after: 545).wait == interval)
    }

    @Test("a clean read after waking waits the regular interval and spends no re-read")
    func cleanRead() {
        let clean = next(awake(), [row(.ok)], after: 5)
        #expect(clean.wait == interval)
        #expect(next(clean.recovery, [row(.failed(.timeout))], after: 310).wait == 30)
    }

    @Test("a failure the vendor answered with is not read again early",
          arguments: [UsageState.failed(.rateLimited), .failed(.signInRejected), .failed(.accountMismatch),
                      .failed(.schemaChanged), .failed(.signInExpired), .failed(.notEligible),
                      .unavailable(.noSignIn), .unavailable(.cliMissing), .unavailable(.managed),
                      .unavailable(.connectionRequired), .notReporting])
    func answeredFailure(state: UsageState) {
        #expect(next(awake(), [row(state)], after: 5).wait == interval)
    }

    @Test("a row that had numbers when the Mac woke and has none after is read again",
          arguments: [UsageState.notReporting, .unavailable(.refused), .unavailable(.schemaChanged)])
    func readableBeforeWaking(state: UsageState) {
        let recovery = awake([row(.ok, id: "claude:cli"), row(.notReporting, id: "codex:a")])
        #expect(next(recovery, [row(state, id: "claude:cli")], after: 5).wait == 30)
        // The same state on a row that was already without numbers is its normal state.
        #expect(next(recovery, [row(state, id: "codex:a")], after: 5).wait == interval)
        // Even for a row that had numbers, an answered failure is not worth an early read —
        // nor is a connection the user turned off after waking.
        #expect(next(recovery, [row(.failed(.rateLimited), id: "claude:cli")], after: 5).wait == interval)
        #expect(next(recovery, [row(.unavailable(.connectionRequired), id: "claude:cli")], after: 5).wait
                == interval)
    }

    @Test("only reads that end within ten minutes of waking count")
    func window() {
        let failed = [row(.failed(.network))]
        #expect(UsageWakeRecovery.window == 600)
        #expect(next(awake(), failed, after: 600).wait == 30)
        #expect(next(awake(), failed, after: 601).wait == interval)
        // A clock set back to before the wake is not "just after waking".
        #expect(next(awake(), failed, after: -1).wait == interval)
    }

    @Test("waking again gives the re-reads back")
    func wakingAgain() {
        let failed = [row(.failed(.network))]
        var recovery = awake()
        for after in [5.0, 40, 110] { recovery = next(recovery, failed, after: after).recovery }
        #expect(next(recovery, failed, after: 240).wait == interval)
        let again = recovery.waking(at: woke.addingTimeInterval(250), usages: failed)
        #expect(next(again, failed, after: 255).wait == 30)
    }

    @Test("each wake remembers only the rows that had numbers at that wake")
    func wakingAgainForgetsEarlierRows() {
        let first = awake([row(.ok, id: "claude:cli")])
        let second = first.waking(at: woke.addingTimeInterval(60), usages: [row(.notReporting, id: "claude:cli"),
                                                                              row(.ok, id: "codex:a")])
        #expect(next(second, [row(.notReporting, id: "claude:cli")], after: 65).wait == interval)
        #expect(next(second, [row(.notReporting, id: "codex:a")], after: 65).wait == 30)
    }

    @Test("waking with a failed read on screen pulls the next read in")
    func failedReadOnScreenWhenWaking() {
        // The read ended a moment before the wake was noticed: its regular next read is far off.
        let failed = [row(.failed(.network))]
        let scheduled = woke.addingTimeInterval(290)
        let result = awake(failed).nextRead(scheduled: scheduled, usages: failed, now: woke)
        #expect(result.at == woke.addingTimeInterval(30))
        // That read was the first of the three.
        #expect(next(result.recovery, failed, after: 40).wait == 60)
    }

    @Test("a read already due sooner is left alone and spends no re-read")
    func scheduledSooner() {
        let failed = [row(.failed(.network))]
        // After a long sleep the regular read is overdue: it runs first.
        let overdue = woke.addingTimeInterval(-3600)
        let result = awake(failed).nextRead(scheduled: overdue, usages: failed, now: woke)
        #expect(result.at == overdue)
        #expect(next(result.recovery, failed, after: 5).wait == 30)
    }
}
