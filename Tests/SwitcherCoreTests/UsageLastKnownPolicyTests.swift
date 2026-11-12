import Foundation
import Testing
@testable import SwitcherCore

private let T0 = Date(timeIntervalSince1970: 1_800_000_000)

private func row(_ state: UsageState, provider: UsageProvider = .claude,
                 accountRef: String = "app:acct-1__org-1",
                 id: String = "claude:app:acct-1__org-1",
                 windows: [UsageWindow], readAgo: TimeInterval = 0,
                 auth: UsageAuthentication = .unknown, key: String? = nil) -> AccountUsage {
    AccountUsage(id: id, provider: provider, accountRef: accountRef, label: "L",
                 plan: nil, windows: windows, state: state,
                 readAt: T0.addingTimeInterval(-readAgo), toolVersion: nil,
                 authentication: auth, identityKey: key)
}

private func win(used: Double = 40, resetsAt: Date? = nil, duration: Int? = 10080) -> UsageWindow {
    UsageWindow(durationMinutes: duration, usedPercent: used, resetsAt: resetsAt)
}

@Suite("windowDisplay policy")
struct UsageWindowDisplayTests {
    private let future = T0.addingTimeInterval(86400)
    private let past = T0.addingTimeInterval(-60)

    @Test("fresh ok row renders current")
    func current() {
        let u = row(.ok, windows: [win(resetsAt: future)])
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .current)
    }

    @Test("reset-passed window drops the number even on an ok row")
    func okReset() {
        let u = row(.ok, windows: [win(resetsAt: past)])
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .resetSinceRead)
    }

    @Test("failed row with retained windows shows last-known")
    func retained() {
        let u = row(.unavailable(.noSignIn), windows: [win(resetsAt: future)], readAgo: 300)
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .lastKnown)
    }

    @Test("retained row whose window reset since the read loses the number")
    func retainedReset() {
        let u = row(.unavailable(.noSignIn), windows: [win(resetsAt: past)], readAgo: 300)
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .resetSinceRead)
    }

    @Test("over-age and future-dated ok reads show last-known")
    func staleRead() {
        let u = row(.ok, windows: [win(resetsAt: future)], readAgo: 3600)
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .lastKnown)
        let fut = row(.ok, windows: [win(resetsAt: future)], readAgo: -300)
        #expect(UsagePresentations.windowDisplay(fut, fut.windows[0], now: T0) == .lastKnown)
    }

    @Test("invalid percent shows last-known")
    func invalidPercent() {
        let u = row(.ok, windows: [win(used: 240, resetsAt: future)])
        #expect(UsagePresentations.windowDisplay(u, u.windows[0], now: T0) == .lastKnown)
    }
}

@Suite("claude:app profile reason + sign-in hint")
struct ClaudeProfileHintTests {
    @Test("claude:app noSignIn uses the profile-specific reason")
    func profileReason() {
        let u = row(.unavailable(.noSignIn), windows: [])
        let r = UsageText.reason(for: u)
        #expect(r != nil && r == L10n.t(.usageReasonClaudeProfileNoSignIn, L10n.t(.uiDetails)))
    }

    @Test("claude:cli and other problems keep the generic reason")
    func genericReason() {
        let cli = row(.unavailable(.noSignIn), accountRef: "cli", id: "claude:cli", windows: [])
        #expect(UsageText.reason(for: cli) == UsageText.reason(cli.state, provider: .claude))
        let other = row(.failed(.timeout), windows: [])
        #expect(UsageText.reason(for: other) == UsageText.reason(other.state, provider: .claude))
    }

    @Test("sign-in hint command is display-safe and POSIX-quoted")
    func hintCommand() {
        #expect(ClaudeProfileSignInHint.command(profilePath: "/Users/x/.claude-profiles/a")
            == "CLAUDE_CONFIG_DIR='/Users/x/.claude-profiles/a' claude auth login")
        #expect(ClaudeProfileSignInHint.command(profilePath: "/Users/x/My Dir/o'clock")
            == "CLAUDE_CONFIG_DIR='/Users/x/My Dir/o'\\''clock' claude auth login")
        #expect(ClaudeProfileSignInHint.command(profilePath: "/路径")
            == "CLAUDE_CONFIG_DIR='/路径' claude auth login")
    }
}

@Suite("collection merge keeps claude:app last-known")
struct UsageCollectionRetentionTests {
    private let future = T0.addingTimeInterval(86400)

    @Test("failed claude:app row inherits live windows; reset windows are dropped")
    func merge() {
        let old = row(.ok, windows: [win(resetsAt: future)], readAgo: 300)
        let fresh = row(.unavailable(.noSignIn), windows: [])
        let merged = UsageCollection.replacing(provider: .claude, readings: [fresh],
                                               in: [old], now: T0)
        #expect(merged.count == 1 && merged[0].windows.count == 1)
        #expect(merged[0].readAt == old.readAt && merged[0].state == .unavailable(.noSignIn))
    }
}

@Suite("last-known rows stay out of every decision path")
struct LastKnownExclusionTests {
    private let future = T0.addingTimeInterval(86400)
    private func retained() -> AccountUsage {
        row(.unavailable(.noSignIn), windows: [win(used: 10, resetsAt: future)], readAgo: 7200)
    }

    @Test("alerts ignore non-ok rows")
    func alerts() {
        let result = UsageAlerts.update(usages: [retained()], threshold: 80,
                                        alerted: [:], now: T0)
        #expect(result.alerts.isEmpty)
        #expect(result.alerted.isEmpty)
    }

    @Test("compact windows fall back to raw order without ranking")
    func compact() {
        let u = retained()
        let out = UsagePresentations.compactWindows(u, now: T0)
        #expect(out == u.windows)
    }
}
