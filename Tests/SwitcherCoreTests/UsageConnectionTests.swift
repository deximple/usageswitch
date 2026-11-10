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

/// Antigravity and Gemini were re-described in 2.1.5 (audit A-04): a grant given under the old
/// wording does not carry over.
@Suite("Usage connection disclosure versions")
struct UsageConnectionDisclosureTests {
    @Test func aGrantFromBeforeTheNewDisclosureIsNotEnough() {
        for (provider, marker) in [(UsageProvider.antigravity, "antigravity.v2"), (.gemini, "gemini.v2")] {
            let old = SwitcherSettings(usageConnections: [provider.rawValue])
            #expect(!old.enabledUsageProviders.contains(provider))
            let current = SwitcherSettings(usageConnections: [provider.rawValue, marker])
            #expect(current.enabledUsageProviders.contains(provider))
        }
        // The Gemini refresh entry is not the disclosure marker.
        #expect(SwitcherSettings(usageConnections: ["gemini", "gemini.tokenRefresh"]).enabledUsageProviders.isEmpty)
    }

    @Test func markersAloneNeverGrant() {
        #expect(SwitcherSettings(usageConnections: ["antigravity.v2", "gemini.v2"]).enabledUsageProviders.isEmpty)
        #expect(SwitcherSettings(usageConnections: ["gemini.v2", "antigravity"]).enabledUsageProviders.isEmpty)
    }

    @Test func providersWhoseBehaviourDidNotChangeKeepTheirGrant() {
        let settings = SwitcherSettings(usageConnections: ["grok", "devin", "opencode"])
        #expect(settings.enabledUsageProviders == [.grok, .devin, .opencode])
    }

    @Test func savingAGrantWritesItsMarker() {
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.antigravity, .grok], geminiTokenRefresh: false)
                == ["antigravity", "antigravity.v2", "grok"])
        #expect(SwitcherSettings.usageConnectionsValue(providers: [.gemini], geminiTokenRefresh: true)
                == ["gemini", "gemini.tokenRefresh", "gemini.v2"])
        // What is saved is granted when read back.
        for providers in [Set<UsageProvider>([.antigravity]), [.gemini, .antigravity, .devin]] {
            let saved = SwitcherSettings.usageConnectionsValue(providers: providers, geminiTokenRefresh: true)
            #expect(SwitcherSettings(usageConnections: saved).enabledUsageProviders == providers)
        }
    }

    @Test func everyConsentProviderHasItsOwnDisclosureNamingWhereRequestsGo() {
        let hosts: [UsageProvider: [String]] = [
            .cursor: ["api2.cursor.sh"], .grok: ["cli-chat-proxy.grok.com", "~/.grok/auth.json"],
            .gemini: ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com", "~/.gemini/oauth_creds.json"],
            .antigravity: ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com"],
            .devin: ["server.codeium.com", "devin --version", "credentials.toml"],
            .opencode: ["opencode.ai", "~/.local/share/opencode/auth.json", "opencode-go"],
        ]
        for provider in UsageProvider.allCases {
            guard provider.requiresConsent else {
                #expect(provider.consentBodyKey == nil)
                continue
            }
            let key = provider.consentBodyKey
            #expect(key != nil, "\(provider)")
            guard let key else { continue }
            for language in AppLanguage.allCases {
                let body = L10n.string(key, language: language)
                for fact in hosts[provider] ?? [] {
                    #expect(body.contains(fact), "\(provider) \(language) is missing \(fact)")
                }
            }
        }
        #expect(Set(UsageProvider.allCases.compactMap(\.consentBodyKey)).count == 6)
    }
}
