import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion log root policy")
struct SuggestionLogRootPolicyTests {
    private func usage(_ provider: UsageProvider, accountRef: String, state: UsageState,
                       readAt: Date, authentication: UsageAuthentication = .unknown) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(accountRef)", provider: provider,
                     accountRef: accountRef, label: "Account", plan: nil,
                     windows: [], state: state, readAt: readAt, toolVersion: nil,
                     authentication: authentication)
    }

    @Test("Claude profile roots exclude a matching account mismatch")
    func claudeProfileRootExcludesAccountMismatch() {
        let accountRef = "app:profile-id"
        let mismatch = usage(.claude, accountRef: accountRef,
                             state: .failed(.accountMismatch),
                             readAt: Date(timeIntervalSince1970: 2))
        let olderOk = usage(.claude, accountRef: accountRef, state: .ok,
                            readAt: Date(timeIntervalSince1970: 1))
        let otherFailure = usage(.claude, accountRef: accountRef,
                                 state: .failed(.timeout),
                                 readAt: Date(timeIntervalSince1970: 3))

        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: [mismatch, olderOk]))
        #expect(SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                 usages: [mismatch, otherFailure]))
        #expect(SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                 usages: [olderOk]))
    }

    @Test("Codex API-key rows and missing rows remain eligible")
    func codexApiKeyAndMissingRowsAreIncluded() {
        let accountRef = "codex-home-id"
        let apiKey = usage(.codex, accountRef: accountRef, state: .notReporting,
                           readAt: Date(timeIntervalSince1970: 2), authentication: .apiKey)
        let mismatch = usage(.codex, accountRef: accountRef,
                             state: .failed(.accountMismatch),
                             readAt: Date(timeIntervalSince1970: 3))

        #expect(!SuggestionLogRootPolicy.includes(provider: .codex, accountRef: accountRef,
                                                   usages: [apiKey, mismatch]))
        #expect(SuggestionLogRootPolicy.includes(
            provider: .codex, accountRef: accountRef,
            usages: [apiKey]))
        #expect(SuggestionLogRootPolicy.includes(provider: .codex, accountRef: accountRef,
                                                 usages: []))
    }
}
