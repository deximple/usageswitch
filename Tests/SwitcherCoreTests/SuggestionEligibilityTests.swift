import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion eligibility")
struct SuggestionEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(provider: UsageProvider, ref: String) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider, accountRef: ref,
                     label: ref, plan: nil, windows: [], state: .ok,
                     readAt: now, toolVersion: nil)
    }

    private func account(id: String, isActive: Bool = false,
                         snapshot: SnapshotState = .ready,
                         expiresAt: Date? = nil) -> AccountStatus {
        AccountStatus(id: id, label: id, customName: nil, defaultName: id, email: nil,
                      accountUuid: id, orgUuid: id, isActive: isActive, snapshot: snapshot,
                      capturedAt: now, sessionExpiresAt: expiresAt)
    }

    private func usable(_ u: AccountUsage, accounts: [AccountStatus] = [],
                        signedOut: Set<String> = []) -> Bool {
        SuggestionEligibility.usable(u, claudeAccounts: accounts,
                                     codexSignedOutIDs: signedOut, now: now)
    }

    @Test("expired non-active Claude App account is dropped")
    func expiredDropped() {
        let u = usage(provider: .claude, ref: "app:a1")
        let a = account(id: "a1", snapshot: .expired)
        #expect(!usable(u, accounts: [a]))
    }

    @Test("ready snapshot whose session already ended is dropped")
    func readyButSessionEnded() {
        let u = usage(provider: .claude, ref: "app:a1")
        let a = account(id: "a1", expiresAt: now.addingTimeInterval(-60))
        #expect(!usable(u, accounts: [a]))
    }

    @Test("expiry boundary: exactly at now counts as expired")
    func expiryBoundary() {
        let u = usage(provider: .claude, ref: "app:a1")
        #expect(!usable(u, accounts: [account(id: "a1", expiresAt: now)]))
        #expect(usable(u, accounts: [account(id: "a1", expiresAt: now.addingTimeInterval(1))]))
        #expect(usable(u, accounts: [account(id: "a1", expiresAt: nil)]))
    }

    @Test("corrupt snapshot is dropped")
    func corruptDropped() {
        let u = usage(provider: .claude, ref: "app:a1")
        #expect(!usable(u, accounts: [account(id: "a1", snapshot: .corrupt)]))
    }

    @Test("the active account stays even when its snapshot is expired")
    func activeStays() {
        let u = usage(provider: .claude, ref: "app:a1")
        let a = account(id: "a1", isActive: true, snapshot: .expired)
        #expect(usable(u, accounts: [a]))
    }

    @Test("a Claude App row with no status entry is kept")
    func unknownKept() {
        let u = usage(provider: .claude, ref: "app:ghost")
        #expect(usable(u, accounts: []))
    }

    @Test("the CLI row is always kept")
    func cliKept() {
        let u = usage(provider: .claude, ref: "cli")
        #expect(usable(u, accounts: []))
    }

    @Test("signed-out Codex accounts are dropped")
    func codexSignedOut() {
        #expect(!usable(usage(provider: .codex, ref: "c1"), signedOut: ["c1"]))
        #expect(usable(usage(provider: .codex, ref: "c2"), signedOut: ["c1"]))
        #expect(usable(usage(provider: .codex, ref: "c1"), signedOut: []))
    }

    @Test("other providers always pass")
    func othersPass() {
        for provider in [UsageProvider.cursor, .grok, .gemini, .antigravity, .devin, .opencode] {
            #expect(usable(usage(provider: provider, ref: "x")))
        }
    }
}
