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

    @Test("Claude app roots require an ok row and leave cli ungated")
    func claudeAppRootRequiresOk() {
        let accountRef = "app:profile-id"
        let ok = usage(.claude, accountRef: accountRef, state: .ok,
                       readAt: Date(timeIntervalSince1970: 1))
        let noSignIn = usage(.claude, accountRef: accountRef,
                             state: .unavailable(.noSignIn),
                             readAt: Date(timeIntervalSince1970: 2))
        let profileInvalid = usage(.claude, accountRef: accountRef,
                                   state: .failed(.profileInvalid),
                                   readAt: Date(timeIntervalSince1970: 3))
        let timeout = usage(.claude, accountRef: accountRef,
                            state: .failed(.timeout),
                            readAt: Date(timeIntervalSince1970: 4))

        #expect(SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                 usages: [ok]))
        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: [noSignIn]))
        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: [profileInvalid]))
        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: [timeout]))
        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: []))
        #expect(SuggestionLogRootPolicy.includes(provider: .claude, accountRef: "cli",
                                                 usages: [profileInvalid]))
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
