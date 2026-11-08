import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion log root policy")
struct SuggestionLogRootPolicyTests {
    private func usage(_ provider: UsageProvider, accountRef: String, state: UsageState,
                       readAt: Date) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(accountRef)", provider: provider,
                     accountRef: accountRef, label: "Account", plan: nil,
                     windows: [], state: state, readAt: readAt, toolVersion: nil)
    }

    @Test("Claude profile roots require the latest matching read to be ok")
    func claudeProfileRootRequiresLatestOk() {
        let accountRef = "app:profile-id"
        let older = usage(.claude, accountRef: accountRef, state: .ok,
                          readAt: Date(timeIntervalSince1970: 1))
        let mismatch = usage(.claude, accountRef: accountRef,
                             state: .failed(.accountMismatch),
                             readAt: Date(timeIntervalSince1970: 2))
        let latestOk = usage(.claude, accountRef: accountRef, state: .ok,
                             readAt: Date(timeIntervalSince1970: 3))

        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                   usages: [mismatch, older]))
        #expect(SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                 usages: [latestOk, mismatch]))
        #expect(!SuggestionLogRootPolicy.includes(provider: .claude, accountRef: accountRef,
                                                  usages: []))
    }

    @Test("Codex account homes also require a matching successful read")
    func codexHomeRequiresLatestOk() {
        let accountRef = "codex-home-id"
        let mismatch = usage(.codex, accountRef: accountRef,
                             state: .failed(.accountMismatch), readAt: Date())

        #expect(!SuggestionLogRootPolicy.includes(provider: .codex, accountRef: accountRef,
                                                   usages: [mismatch]))
        #expect(SuggestionLogRootPolicy.includes(
            provider: .codex, accountRef: accountRef,
            usages: [usage(.codex, accountRef: accountRef, state: .ok, readAt: Date())]))
    }
}
