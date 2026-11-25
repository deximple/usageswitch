import Foundation
import Testing
@testable import SwitcherCore

/// Audit G-T-1: what a withdrawn consent takes off the screen and out of memory was decided in
/// the app shell, where no test saw it.
@Suite("Withdrawing a usage connection")
struct UsageConsentChangeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func row(_ provider: UsageProvider, _ ref: String = "current", state: UsageState = .ok) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider, accountRef: ref, label: "L", plan: "Pro",
                     windows: [UsageWindow(durationMinutes: 10080, usedPercent: 40,
                                           resetsAt: now.addingTimeInterval(3600))],
                     state: state, readAt: now, toolVersion: nil,
                     authentication: .subscription, identityKey: "login")
    }

    func apply(_ usages: [AccountUsage], enabled: Set<UsageProvider>, hidden: Set<UsageProvider> = [],
               installed: Set<UsageProvider>) -> [AccountUsage] {
        UsageCollection.applyingConsent(to: usages, enabledProviders: enabled, hiddenProviders: hidden,
                                        installedProviders: installed, now: now)
    }

    @Test("every consent-required provider without a grant is revoked; Claude and Codex never are")
    func revoked() {
        #expect(UsageCollection.revokedProviders(enabledProviders: [])
                == UsageProvider.allCases.filter(\.requiresConsent))
        #expect(UsageCollection.revokedProviders(enabledProviders: [.grok, .cursor])
                == [.gemini, .antigravity, .devin, .opencode, .copilot])
        #expect(UsageCollection.revokedProviders(enabledProviders: Set(UsageProvider.allCases)).isEmpty)
    }

    @Test("a revoked provider's reading leaves at once; an installed one keeps only the Connect usage row")
    func readingLeaves() {
        let out = apply([row(.claude, "cli"), row(.grok), row(.devin)],
                        enabled: [.devin], installed: [.claude, .grok, .devin])
        #expect(out.map(\.id) == ["claude:cli", "grok:current", "devin:current"])
        #expect(out[0] == row(.claude, "cli"))
        #expect(out[1].state == .unavailable(.connectionRequired))
        // Nothing of the reading survives the swap: no windows, no plan, no login fingerprint.
        #expect(out[1].windows.isEmpty)
        #expect(out[1].plan == nil)
        #expect(out[1].identityKey == nil)
        #expect(out[2] == row(.devin))
    }

    @Test("a revoked provider that was turned off, or isn't installed, leaves no row")
    func noRow() {
        let rows = [row(.claude, "cli"), row(.grok), row(.devin)]
        #expect(apply(rows, enabled: [], hidden: [.grok], installed: [.claude, .grok]).map(\.id)
                == ["claude:cli"])
        // Hidden counts only while the grant is gone: the caller passes the effective hidden set.
        #expect(apply(rows, enabled: [.grok, .devin], hidden: [], installed: [.claude]).map(\.id)
                == ["claude:cli", "grok:current", "devin:current"])
    }

    @Test("an installed, revoked provider gets its Connect usage row even with nothing read yet")
    func placeholderWithoutReading() {
        let out = apply([row(.codex, "a")], enabled: [], installed: [.codex, .cursor])
        #expect(out.map(\.id) == ["codex:a", CursorUsageCollector.rowID])
        #expect(UsageCollection.canConnect(out[1], enabledProviders: []))
    }

    @Test("consent-free providers are untouched whatever the grant set says")
    func consentFree() {
        let rows = [row(.claude, "cli"), row(.codex, "a")]
        #expect(apply(rows, enabled: [], hidden: [.claude, .codex], installed: []) == rows)
    }

    @Test("a demo swaps its fixture rows in place and never reads")
    func demo() {
        let fixtures = [row(.devin), row(.claude, "cli"), row(.grok), row(.cursor, "cursor")]
        let out = UsageCollection.substitutingConsent(in: fixtures, enabledProviders: [.devin],
                                                      hiddenProviders: [.grok])
        // Fixture order stays; the granted and consent-free rows are the fixtures themselves.
        #expect(out.map(\.id) == ["devin:current", "claude:cli", CursorUsageCollector.rowID])
        #expect(out[0] == fixtures[0])
        #expect(out[1] == fixtures[1])
        #expect(out[2].state == .unavailable(.connectionRequired))
        #expect(out[2].windows.isEmpty)
        // Granting again brings the original fixture rows back.
        #expect(UsageCollection.substitutingConsent(in: fixtures, enabledProviders: [.devin, .grok, .cursor],
                                                    hiddenProviders: []) == fixtures)
    }

    @Test("a revoked provider's sign-in kept in memory is dropped; a granted one's stays")
    func memory() {
        let antigravity = AntigravityAccessTokenCache()
        let gemini = GeminiAccessTokenCache()
        let cursor = CursorRenewalAttemptCache()
        let key = Data("refresh".utf8)
        func fill() {
            antigravity.store(accessToken: "a", validUntil: now.addingTimeInterval(600), projectID: nil)
            gemini.store(for: key, accessToken: "g", validUntil: now.addingTimeInterval(600))
            cursor.record("expired")
        }
        fill()
        UsageCollection.forgetSignIns(of: [.grok, .devin], antigravity: antigravity, gemini: gemini, cursor: cursor)
        #expect(antigravity.value(at: now) != nil)
        #expect(gemini.value(for: key, at: now) != nil)
        #expect(cursor.contains("expired"))

        UsageCollection.forgetSignIns(of: [.antigravity], antigravity: antigravity, gemini: gemini, cursor: cursor)
        #expect(antigravity.value(at: now) == nil)
        #expect(gemini.value(for: key, at: now) != nil)
        #expect(cursor.contains("expired"))

        fill()
        UsageCollection.forgetSignIns(of: [.gemini], antigravity: antigravity, gemini: gemini, cursor: cursor)
        #expect(antigravity.value(at: now) != nil)
        #expect(gemini.value(for: key, at: now) == nil)
        #expect(cursor.contains("expired"))

        fill()
        UsageCollection.forgetSignIns(of: [.cursor], antigravity: antigravity, gemini: gemini, cursor: cursor)
        #expect(antigravity.value(at: now) != nil)
        #expect(gemini.value(for: key, at: now) != nil)
        #expect(!cursor.contains("expired"))
    }

    @Test("the saved snapshot loses exactly the revoked providers' rows")
    func snapshot() {
        let snapshot = UsageSnapshot(usages: [row(.claude, "cli"), row(.grok), row(.devin)],
                                     generatedAt: now, showEmails: false)
        let revoked = UsageCollection.revokedProviders(enabledProviders: [.devin])
        #expect(snapshot.removing(providers: Set(revoked)).accounts.map(\.provider) == ["claude", "devin"])
    }

    @Test("a token a read keeps after the consent was withdrawn is gone once that read ends")
    func tokenKeptAfterWithdrawal() {
        // Audit D-04: the read is abandoned at once, but a token request already on its way still
        // answers, and the collector keeps the token after the consent change forgot the old one.
        let antigravity = AntigravityAccessTokenCache()
        let gemini = GeminiAccessTokenCache()
        let cursor = CursorRenewalAttemptCache()
        let key = Data("refresh".utf8)
        UsageCollection.forgetSignIns(of: UsageCollection.revokedProviders(enabledProviders: []),
                                      antigravity: antigravity, gemini: gemini, cursor: cursor)
        antigravity.store(accessToken: "late", validUntil: now.addingTimeInterval(600), projectID: nil)
        gemini.store(for: key, accessToken: "late", validUntil: now.addingTimeInterval(600))
        cursor.record("late")
        UsageCollection.readEnded(enabledProviders: [], antigravity: antigravity, gemini: gemini,
                                  cursor: cursor)
        #expect(antigravity.value(at: now) == nil)
        #expect(gemini.value(for: key, at: now) == nil)
        #expect(!cursor.contains("late"))
    }

    @Test("a read ending leaves a granted provider's sign-in in place")
    func readEndedKeepsGrantedSignIns() {
        let antigravity = AntigravityAccessTokenCache()
        let gemini = GeminiAccessTokenCache()
        let cursor = CursorRenewalAttemptCache()
        let key = Data("refresh".utf8)
        antigravity.store(accessToken: "a", validUntil: now.addingTimeInterval(600), projectID: nil)
        gemini.store(for: key, accessToken: "g", validUntil: now.addingTimeInterval(600))
        cursor.record("expired")
        UsageCollection.readEnded(enabledProviders: [.antigravity, .gemini, .cursor],
                                  antigravity: antigravity, gemini: gemini, cursor: cursor)
        #expect(antigravity.value(at: now) != nil)
        #expect(gemini.value(for: key, at: now) != nil)
        #expect(cursor.contains("expired"))
    }
}
