import Foundation
import Testing
@testable import SwitcherCore

@Suite("Connect-usage eligibility")
struct UsageConnectionTests {
    private func row(_ p: UsageProvider, _ state: UsageState) -> AccountUsage {
        AccountUsage(id: "\(p.rawValue):x", provider: p, accountRef: "x", label: "x",
                     plan: nil, windows: [], state: state, readAt: Date(), toolVersion: nil)
    }

    @Test("only consent-required providers in connectionRequired and ungranted are eligible")
    func eligible() {
        let enabled: Set<UsageProvider> = []
        for provider in UsageProvider.allCases where provider.requiresConsent {
            #expect(UsageCollection.canConnect(row(provider, .unavailable(.connectionRequired)),
                                               enabledProviders: enabled))
        }
    }

    @Test("granted provider is not eligible")
    func granted() {
        let enabled: Set<UsageProvider> = [.grok]
        #expect(!UsageCollection.canConnect(row(.grok, .unavailable(.connectionRequired)),
                                            enabledProviders: enabled))
    }

    @Test("other states are never eligible")
    func otherStates() {
        let enabled: Set<UsageProvider> = []
        for state in [UsageState.ok, .notReporting,
                      .unavailable(.noSignIn), .unavailable(.cliMissing),
                      .unavailable(.schemaChanged), .failed(.network),
                      .failed(.connectionRequired)] {
            #expect(!UsageCollection.canConnect(row(.grok, state), enabledProviders: enabled))
        }
    }

    @Test("non-consent providers are never eligible even for connectionRequired")
    func nonConsent() {
        let enabled: Set<UsageProvider> = []
        #expect(!UsageCollection.canConnect(row(.claude, .unavailable(.connectionRequired)),
                                            enabledProviders: enabled))
        #expect(!UsageCollection.canConnect(row(.codex, .unavailable(.connectionRequired)),
                                            enabledProviders: enabled))
    }
}
