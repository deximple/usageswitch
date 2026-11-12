import Foundation
import Testing
@testable import SwitcherCore

@Suite("Last-known windows")
struct UsageRetentionTests {
    private let now = Date()
    private var futureReset: Date { now.addingTimeInterval(86400) }
    private var pastReset: Date { now.addingTimeInterval(-60) }

    private func claudeApp(_ state: UsageState, id: String = "claude:app:acct-1__org-1",
                           windows: [UsageWindow] = [], readAgo: TimeInterval = 0,
                           plan: String? = nil) -> AccountUsage {
        AccountUsage(id: id, provider: .claude, accountRef: "app:acct-1__org-1",
                     label: "Masked", plan: plan, windows: windows, state: state,
                     readAt: now.addingTimeInterval(-readAgo), toolVersion: "2.0",
                     authentication: .unknown, identityKey: nil)
    }

    private func codex(_ state: UsageState, key: String? = "k1",
                       windows: [UsageWindow] = [], readAgo: TimeInterval = 0) -> AccountUsage {
        AccountUsage(id: "codex:a", provider: .codex, accountRef: "a", label: "L",
                     plan: nil, windows: windows, state: state,
                     readAt: now.addingTimeInterval(-readAgo), toolVersion: "1",
                     authentication: .subscription, identityKey: key)
    }

    private func window(used: Double = 40, duration: Int? = 10080, resetsAt: Date? = nil) -> UsageWindow {
        UsageWindow(durationMinutes: duration, usedPercent: used, resetsAt: resetsAt)
    }

    @Test("failed claude:app re-read keeps the previous windows and readAt")
    func retains() {
        let prev = claudeApp(.ok, windows: [window(resetsAt: futureReset)], readAgo: 300, plan: "Pro")
        let out = claudeApp(.unavailable(.noSignIn)).retainingWindows(from: prev, now: now)
        #expect(out.state == .unavailable(.noSignIn))
        #expect(out.windows.count == 1 && out.readAt == prev.readAt && out.plan == "Pro")
        #expect(out.showsLastKnown)
    }

    @Test("claude:app keeps windows on other non-identity failures too")
    func retainsOtherFailures() {
        let prev = claudeApp(.ok, windows: [window(resetsAt: futureReset)], readAgo: 120)
        for state: UsageState in [.failed(.timeout), .unavailable(.refused),
                                  .failed(.schemaChanged), .unavailable(.signInRejected)] {
            let out = claudeApp(state).retainingWindows(from: prev, now: now)
            #expect(out.windows.count == 1, "\(state) should keep")
            #expect(out.readAt == prev.readAt)
        }
    }

    @Test("a broken binding keeps nothing")
    func brokenBindingKeepsNothing() {
        let prev = claudeApp(.ok, windows: [window(resetsAt: futureReset)], readAgo: 120)
        #expect(claudeApp(.failed(.accountMismatch)).retainingWindows(from: prev, now: now).windows.isEmpty)
        #expect(claudeApp(.unavailable(.profileInvalid)).retainingWindows(from: prev, now: now).windows.isEmpty)
    }

    @Test("a different account id keeps nothing")
    func differentId() {
        let prev = claudeApp(.ok, windows: [window(resetsAt: futureReset)], readAgo: 120)
        let other = AccountUsage(id: "claude:app:acct-2__org-1", provider: .claude,
                                 accountRef: "app:acct-2__org-1", label: "M", plan: nil,
                                 windows: [], state: .unavailable(.noSignIn), readAt: now,
                                 toolVersion: nil)
        #expect(other.retainingWindows(from: prev, now: now).windows.isEmpty)
    }

    @Test("claude:cli never retains — the row names no account")
    func cliNeverRetains() {
        let prev = AccountUsage(id: "claude:cli", provider: .claude, accountRef: "cli",
                                label: "L", plan: nil,
                                windows: [window(resetsAt: futureReset)], state: .ok,
                                readAt: now.addingTimeInterval(-120), toolVersion: nil)
        let fresh = AccountUsage(id: "claude:cli", provider: .claude, accountRef: "cli",
                                 label: "L", plan: nil, windows: [],
                                 state: .unavailable(.noSignIn), readAt: now, toolVersion: nil)
        #expect(fresh.retainingWindows(from: prev, now: now).windows.isEmpty)
    }

    @Test("a reset-passed window is dropped; a live one survives")
    func resetBoundary() {
        let prev = claudeApp(.ok, windows: [window(used: 10, resetsAt: pastReset),
                                          window(used: 40, resetsAt: futureReset)],
                             readAgo: 300)
        let out = claudeApp(.unavailable(.noSignIn)).retainingWindows(from: prev, now: now)
        #expect(out.windows.count == 1 && out.windows[0].usedPercent == 40)
        let allPast = claudeApp(.ok, windows: [window(resetsAt: pastReset)], readAgo: 300)
        #expect(claudeApp(.unavailable(.noSignIn)).retainingWindows(from: allPast, now: now).windows.isEmpty)
    }

    @Test("unknown reset survives only inside one window length")
    func unknownResetWindowLength() {
        // duration 300 (5h), read 1h ago -> keeps
        let prev = claudeApp(.ok, windows: [window(duration: 300)], readAgo: 3600)
        #expect(claudeApp(.unavailable(.noSignIn)).retainingWindows(from: prev, now: now).windows.count == 1)
        // same window read 6h ago -> dropped
        let old = claudeApp(.ok, windows: [window(duration: 300)], readAgo: 21600)
        #expect(claudeApp(.unavailable(.noSignIn)).retainingWindows(from: old, now: now).windows.isEmpty)
        // no reset and no duration -> never
        let bare = claudeApp(.ok, windows: [window(duration: nil)], readAgo: 60)
        #expect(claudeApp(.unavailable(.noSignIn)).retainingWindows(from: bare, now: now).windows.isEmpty)
    }

    @Test("a retained row stays retained through later failures, filtered again")
    func chainedRetention() {
        let first = claudeApp(.ok, windows: [window(resetsAt: futureReset)], readAgo: 300)
        let retained = claudeApp(.failed(.timeout)).retainingWindows(from: first, now: now)
        let again = claudeApp(.unavailable(.noSignIn)).retainingWindows(from: retained, now: now)
        #expect(again.windows.count == 1 && again.readAt == first.readAt)
        // and once the window resets, the chain empties
        let pastOnly = claudeApp(.ok, windows: [window(resetsAt: pastReset)], readAgo: 300)
        let r1 = claudeApp(.failed(.timeout)).retainingWindows(from: pastOnly, now: now)
        #expect(r1.windows.isEmpty)
        let r2 = claudeApp(.unavailable(.noSignIn)).retainingWindows(from: r1, now: now)
        #expect(r2.windows.isEmpty)
    }

    @Test("codex retention unchanged apart from the reset rule")
    func codexStillWorks() {
        let prev = codex(.ok, windows: [window(resetsAt: futureReset)], readAgo: 120)
        #expect(codex(.unavailable(.noSignIn)).retainingWindows(from: prev, now: now).windows.count == 1)
        // a codex row whose windows have all reset keeps nothing
        let past = codex(.ok, windows: [window(resetsAt: pastReset)], readAgo: 120)
        #expect(codex(.unavailable(.noSignIn)).retainingWindows(from: past, now: now).windows.isEmpty)
        // wrong identity still never retains
        #expect(codex(.failed(.timeout), key: "other").retainingWindows(from: prev, now: now).windows.isEmpty)
    }
}
