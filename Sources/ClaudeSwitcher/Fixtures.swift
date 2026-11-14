import Foundation
import SwitcherCore

/// Demo data for `--ui-fixture` screenshots: example accounts only, clearly labelled as a demo, no real store.
@MainActor
enum Fixtures {
    static func model(named name: String?) -> SwitcherModel? {
        guard let name else { return nil }
        let compactUsage = ["usage-local-three", "usage-claude-only", "usage-seven",
                            "usage-connecting", "usage-readme", "usage-readme-guide"].contains(name)
        let base = status(active: "work", keys: compactUsage ? ["personal", "work"] : nil)
        let switchSteps: [SwitchStep] = [.preflight, .suspendingRelaunchers, .quittingClaude, .capturingOutgoing, .swapping,
                                         .launching, .verifying]
        switch name {
        case "switching":
            return SwitcherModel(demo: base, demoPhase: .working(action: L10n.t(.uiActionSwitchTo, "Personal")),
                                 demoSteps: switchSteps)
        case "success":
            return SwitcherModel(demo: status(active: "personal"), demoSteps: switchSteps + [.restoringRelaunchers, .done],
                                 demoBanner: .init(kind: .success, text: L10n.t(.uiResultSwitched, "Personal", 24)))
        case "relogin":
            return SwitcherModel(demo: status(active: "work", expired: ["personal"]),
                                 demoBanner: .init(kind: .info, text: L10n.t(.demoExpired, "Personal")))
        case "error":
            return SwitcherModel(demo: base,
                                 demoSteps: [.preflight, .suspendingRelaunchers, .quittingClaude, .swapping, .launching, .verifying,
                                             .rollingBack, .restoringRelaunchers],
                                 demoBanner: .init(kind: .error, text: SwitcherError.verificationFailed(
                                     L10n.t(.reasonFaultInjected), rollback: .verified).description))
        case "remove":
            let model = SwitcherModel(demo: base)
            model.pendingConfirmation = base.accounts.first { !$0.isActive }.map(SwitcherModel.removeConfirmation(for:))
            return model
        case "enroll-waiting":
            let work = accounts.first { $0.key == "work" }!
            return SwitcherModel(demo: base, demoPhase: .awaitingLogin,
                                 demoEnrollment: .init(previousAccountID: "\(work.account)__\(work.org)"))
        case "enroll-detected":
            // Live sign-in is an identity no saved account has — the save offer shows.
            let work = accounts.first { $0.key == "work" }!
            let st = SwitcherStatus(
                claude: ClaudeStatus(installed: true, running: true, pid: 4242, version: "1.0.0",
                                     activeAccountUuid: "e5e5e5e5-0000-4000-8000-000000000005",
                                     activeOrgUuid: "e5e5e5e5-0000-4000-8000-0000000000f5",
                                     activeEmail: "new.person@example.com", codeSessions: 0),
                accounts: base.accounts.map {
                    AccountStatus(id: $0.id, label: $0.label, customName: $0.customName,
                                  defaultName: $0.defaultName, email: $0.email,
                                  accountUuid: $0.accountUuid, orgUuid: $0.orgUuid,
                                  isActive: false, snapshot: $0.snapshot,
                                  capturedAt: $0.capturedAt, sessionExpiresAt: $0.sessionExpiresAt)
                },
                relaunchers: [], suspendedRelaunchers: [],
                originalBackup: base.originalBackup, pendingJournal: false,
                nativeMultiAccount: false, warnings: [])
            return SwitcherModel(demo: st, demoPhase: .awaitingLogin,
                                 demoEnrollment: .init(previousAccountID: "\(work.account)__\(work.org)",
                                                       detectedNewLogin: true))
        case "rename":
            let model = SwitcherModel(demo: base)
            model.renameDraft = ""
            model.renaming = base.accounts.first { $0.customName == nil }
            return model
        default:
            return SwitcherModel(demo: base)
        }
    }

    struct DemoAccount {
        let key: String
        let name: String?
        let email: String
        let account: String
        let org: String
    }

    /// In the app's name order; one account keeps its default (email) name to show the masking.
    static let accounts = [
        DemoAccount(key: "personal", name: "Personal", email: "alex.kim@example.com",
                    account: "a1a1a1a1-0000-4000-8000-000000000001", org: "a1a1a1a1-0000-4000-8000-0000000000f1"),
        DemoAccount(key: "side", name: "Side project", email: "alex.lab@example.com",
                    account: "b2b2b2b2-0000-4000-8000-000000000002", org: "b2b2b2b2-0000-4000-8000-0000000000f2"),
        DemoAccount(key: "team", name: nil, email: "studio.team@example.com",
                    account: "c3c3c3c3-0000-4000-8000-000000000003", org: "c3c3c3c3-0000-4000-8000-0000000000f3"),
        DemoAccount(key: "work", name: "Work", email: "alex@work.example.com",
                    account: "d4d4d4d4-0000-4000-8000-000000000004", org: "d4d4d4d4-0000-4000-8000-0000000000f4"),
    ]

    static func status(active: String, expired: Set<String> = [], keys: Set<String>? = nil) -> SwitcherStatus {
        let rows = accounts.filter { keys?.contains($0.key) ?? true }.map { a in
            AccountStatus(id: "\(a.account)__\(a.org)", label: a.name ?? a.email, customName: a.name, defaultName: a.email,
                          email: a.email, accountUuid: a.account, orgUuid: a.org, isActive: a.key == active,
                          snapshot: expired.contains(a.key) ? .expired : .ready, capturedAt: Date(), sessionExpiresAt: nil)
        }
        let current = accounts.first { $0.key == active }
        return SwitcherStatus(
            claude: ClaudeStatus(installed: true, running: true, pid: 4242, version: "1.0.0",
                                 activeAccountUuid: current?.account, activeOrgUuid: current?.org,
                                 activeEmail: current?.email, codeSessions: 1),
            accounts: rows, relaunchers: [], suspendedRelaunchers: [],
            originalBackup: "~/Library/Application Support/\(ProductInfo.defaultBundleID)/backups/original", pendingJournal: false,
            nativeMultiAccount: false, warnings: [])
    }

    // MARK: - Codex tab

    static func codexModel(named name: String) -> CodexModel {
        let model: CodexModel
        let usagePreview = ["usage-local-three", "usage-seven", "usage-connecting",
                            "usage-long", "usage-readme", "usage-readme-guide"].contains(name)
        switch name {
        case "codex-signin": model = CodexModel(demo: codexStatus(), demoPhase: .signingIn(id: nil))
        default: model = CodexModel(demo: codexStatus(usagePreview: usagePreview))
        }
        switch name {
        case "codex-remove":
            model.requestDemoRemoval(codexStatus().accounts.first { $0.kind == .managed })
        case "codex-rename":
            model.renameDraft = ""
            model.renaming = codexStatus().accounts.first { $0.customName == nil && $0.identity?.mode == .apiKey }
        default: break
        }
        return model
    }

    static func codexStatus(usagePreview: Bool = false) -> CodexStatus {
        func identity(_ email: String, _ plan: String) -> CodexIdentity { CodexIdentity(mode: .chatgpt, email: email, plan: plan) }
        let accounts = [
            CodexAccount(id: "standard", kind: .standard,
                         label: usagePreview ? "Personal" : "alex.kim@example.com",
                         customName: usagePreview ? "Personal" : nil,
                         defaultName: "alex.kim@example.com", home: "/Users/alex/.codex", homePath: "~/.codex",
                         identity: identity("alex.kim@example.com", usagePreview ? "prolite" : "pro"),
                         state: .running, pids: [4243]),
            CodexAccount(id: "m-3c4d5e6f", kind: .managed, label: "Side project", customName: "Side project",
                         defaultName: "alex.lab@example.com",
                         home: "/Users/alex/Library/Application Support/\(ProductInfo.defaultBundleID)/codex/m-3c4d5e6f/home",
                         homePath: "~/Library/Application Support/\(ProductInfo.defaultBundleID)/codex/m-3c4d5e6f/home",
                         identity: identity("alex.lab@example.com", "plus"), state: .signedIn, pids: []),
            CodexAccount(id: "found:.codex-work", kind: .found, label: "Work", customName: "Work",
                         defaultName: "alex@work.example.com", home: "/Users/alex/.codex-work", homePath: "~/.codex-work",
                         identity: identity("alex@work.example.com", "team"), state: .running, pids: [4244]),
            CodexAccount(id: "found:.codex_second", kind: .found, label: L10n.t(.codexApiKeyName, ".codex_second"),
                         customName: nil, defaultName: L10n.t(.codexApiKeyName, ".codex_second"),
                         home: "/Users/alex/.codex_second", homePath: "~/.codex_second",
                         identity: CodexIdentity(mode: .apiKey), state: .signedIn, pids: []),
            CodexAccount(id: "found:.codex-test", kind: .found, label: "~/.codex-test", customName: nil,
                         defaultName: "~/.codex-test", home: "/Users/alex/.codex-test", homePath: "~/.codex-test",
                         identity: nil, state: .signedOut, pids: []),
        ]
        let found = [
            CodexAccount(id: "found:.codex-backup", kind: .found, label: "alex.kim@example.com · .codex-backup",
                         customName: nil, defaultName: "alex.kim@example.com", home: "/Users/alex/.codex-backup",
                         homePath: "~/.codex-backup", identity: identity("alex.kim@example.com", "pro"), state: .signedIn, pids: []),
        ]
        let selected = usagePreview
            ? accounts.filter { ["standard", "m-3c4d5e6f", "found:.codex_second"].contains($0.id) }
            : accounts
        return CodexStatus(installed: true, version: "26.1013.40934",
                           accounts: selected, found: usagePreview ? [] : found, hiddenCount: 1)
    }

    // MARK: - Usage tab

    /// Demo usage for `--ui-fixture usage|usage-all|usage-empty|usage-loading|usage-stale`. Dates are relative to now.
    static func usageModel(named name: String, settings: SwitcherModel) -> UsageModel {
        func demo(_ rows: [AccountUsage], segment: UsageModel.Segment = .guide,
                  isRefreshing: Bool = false) -> UsageModel {
            // consent-required providers that show quota in this fixture start
            // flagged connected in memory — never persisted, never a real read
            settings.seedDemoConnections(Set(rows.map { $0.provider }))
            return UsageModel(demo: rows, segment: segment, isRefreshing: isRefreshing,
                              settings: settings)
        }
        switch name {
        case "usage-all":
            return demo(usages(), segment: .all)
        case "usage-empty":
            return demo([account(.claude, "cli", "CLI sign-in", .unavailable(.cliMissing))])
        case "usage-loading":
            return demo([], isRefreshing: true)
        case "usage-stale":
            return demo(staleUsages(), segment: .all)
        case "usage-failed":
            return demo(staleUsages(), segment: .guide)
        case "usage-guide", "usage-guide-basis":
            let model = demo(guideUsages(), segment: .guide)
            model.guideExpanded = true
            model.guideBasisExpanded = name == "usage-guide-basis"
            return model
        case "usage-guide-none":
            // Every account at or past the warning level: no pick, only when one frees up.
            let model = demo([
                account(.claude, "cli", "CLI sign-in", .ok, windows: [
                    window(300, 100, resetsIn: 40 * 60),
                    window(10080, 85, resetsIn: 2 * 86400),
                ]),
                account(.codex, "standard", "alex.kim@example.com", .ok, plan: "prolite",
                        auth: .subscription, identityKey: "fixture-personal", windows: [
                    window(300, 95, resetsIn: 70 * 60),
                    window(10080, 31, resetsIn: 4 * 86400),
                ]),
            ], segment: .guide)
            model.guideExpanded = true
            model.guideBasisExpanded = true
            return model
        case "usage-readme", "usage-readme-guide":
            let personalID = "a1a1a1a1-0000-4000-8000-000000000001__a1a1a1a1-0000-4000-8000-0000000000f1"
            settings.seedDemoClaudeBindings([
                ClaudeProfileBinding(accountId: personalID,
                                     accountUuid: "a1a1a1a1-0000-4000-8000-000000000001",
                                     orgUuid: "a1a1a1a1-0000-4000-8000-0000000000f1",
                                     profilePath: "~/.claude-personal"),
            ])
            let model = demo([
                account(.claude, "cli", "CLI sign-in", .ok, windows: [
                    window(300, 30, resetsIn: 2 * 3600),
                    window(10080, 55, resetsIn: 4 * 86400),
                ]),
                account(.claude, "app:\(personalID)", "Personal", .ok, windows: [
                    window(300, 10, resetsIn: 2 * 3600),
                    window(10080, 20, resetsIn: 4 * 86400),
                ]),
                account(.codex, "standard", "Personal", .ok, plan: "prolite",
                        auth: .subscription, identityKey: "fixture-p", windows: [
                    window(300, 45, resetsIn: 1 * 3600),
                    window(10080, 70, resetsIn: 6 * 86400),
                ]),
                account(.codex, "m-3c4d5e6f", "Side project", .ok, plan: "plus",
                        auth: .subscription, identityKey: "fixture-side", windows: [
                    window(300, 92, resetsIn: 1 * 3600),
                    window(10080, 41, resetsIn: 6 * 86400),
                ], resetCredits: UsageResetCredits(available: 2, expiries: [
                    Date().addingTimeInterval(18 * 86400 + 6 * 3600), Date().addingTimeInterval(29 * 86400),
                ])),
                account(.cursor, "cursor", "Cursor sign-in", .ok, windows: [
                    window(43200, 30, resetsIn: 12 * 86400),
                    window(43200, 28, scope: CursorUsageParser.cursorModelsScope, resetsIn: 12 * 86400),
                    window(43200, 55, scope: CursorUsageParser.otherModelsScope, resetsIn: 12 * 86400),
                ]),
            ], segment: name == "usage-readme-guide" ? .guide : .all)
            if name == "usage-readme-guide" { model.guideExpanded = true }
            return model
        case "usage-many-long", "usage-long":
            return demo(manyLongUsages(), segment: .all)
        case "usage-local-three":
            return demo(localThreeUsages(), segment: .all)
        case "usage-cursor":
            return demo([account(.cursor, "cursor", "Cursor sign-in", .ok, windows: [
                window(43200, 30, resetsIn: 12 * 86400),
                window(43200, 28, scope: CursorUsageParser.cursorModelsScope, resetsIn: 12 * 86400),
                window(43200, 55, scope: CursorUsageParser.otherModelsScope, resetsIn: 12 * 86400),
            ])], segment: .all)
        case "usage-gemini":
            return demo([account(.gemini, "current", "Gemini", .ok, windows: [
                UsageWindow(scope: "gemini-pro [input]", durationMinutes: nil, usedPercent: 65,
                            resetsAt: Date().addingTimeInterval(3600)),
                UsageWindow(scope: "gemini-pro [output]", durationMinutes: nil, usedPercent: 42,
                            resetsAt: Date().addingTimeInterval(3600)),
            ])], segment: .all)
        case "usage-bound":
            let personalID = "a1a1a1a1-0000-4000-8000-000000000001__a1a1a1a1-0000-4000-8000-0000000000f1"
            settings.seedDemoClaudeBindings([
                ClaudeProfileBinding(accountId: personalID,
                                     accountUuid: "a1a1a1a1-0000-4000-8000-000000000001",
                                     orgUuid: "a1a1a1a1-0000-4000-8000-0000000000f1",
                                     profilePath: "~/.claude-personal"),
            ])
            return demo([
                account(.claude, "cli", "CLI sign-in", .ok, windows: [
                    window(10080, 40, resetsIn: 3 * 86400),
                ]),
                account(.claude, "app:\(personalID)", "Personal", .ok, windows: [
                    window(10080, 35, resetsIn: 4 * 86400),
                ]),
            ], segment: .all)
        case "usage-expired":
            return demo([account(.gemini, "current", "Gemini", .unavailable(.signInExpired),
                                 readAgo: 40 * 60)], segment: .all)
        case "usage-last-known":
            let personalID = "a1a1a1a1-0000-4000-8000-000000000001__a1a1a1a1-0000-4000-8000-0000000000f1"
            settings.seedDemoClaudeBindings([
                ClaudeProfileBinding(accountId: personalID,
                                     accountUuid: "a1a1a1a1-0000-4000-8000-000000000001",
                                     orgUuid: "a1a1a1a1-0000-4000-8000-0000000000f1",
                                     profilePath: "~/.claude-personal"),
            ])
            return demo([
                account(.claude, "cli", "CLI sign-in", .ok, windows: [
                    window(300, 30, resetsIn: 2 * 3600),
                    window(10080, 55, resetsIn: 4 * 86400),
                ]),
                // Saved account whose CLI profile signed out: last read kept — the weekly
                // still has time on it, the session window already reset.
                account(.claude, "app:\(personalID)", "Personal", .unavailable(.noSignIn),
                        readAgo: 2 * 3600, windows: [
                    window(10080, 76, resetsIn: 3 * 86400),
                    window(300, 40, resetsIn: -3600),
                ]),
                // Codex retention, same idea: signed out mid-refresh keeps the last read.
                account(.codex, "standard", "Personal", .unavailable(.noSignIn),
                        auth: .subscription, identityKey: "fixture-p",
                        readAgo: 3600, windows: [
                    window(300, 45, resetsIn: 3600),
                    window(10080, 70, resetsIn: 5 * 86400),
                ]),
            ], segment: .all)
        case "usage-claude-only":
            return demo([
                account(.claude, "cli", "CLI sign-in", .ok, windows: [
                    window(10080, 60, resetsIn: 3 * 86400),
                ]),
            ], segment: .all)
        case "usage-seven":
            return demo(sevenUsages(), segment: .all)
        case "usage-none":
            return demo([], segment: .all)
        case "usage-connecting":
            let model = demo(sevenUsages(), segment: .all)
            for provider in UsageProvider.allCases where provider.requiresConsent {
                settings.setUsageConnection(provider, on: false)
            }
            model.applyConsent(settings.enabledUsageProviders)
            return model
        default:
            settings.setUsagePins([personalWeeklyKey])
            return demo(usages())
        }
    }

    private static let personalWeeklyKey = "codex:standard/weekly/"

    private static func window(_ minutes: Int?, _ used: Double, scope: String? = nil,
                               resetsIn: TimeInterval) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used,
                    resetsAt: Date().addingTimeInterval(resetsIn))
    }

    private static func account(_ provider: UsageProvider, _ ref: String, _ label: String,
                                _ state: UsageState, plan: String? = nil, toolVersion: String? = nil,
                                auth: UsageAuthentication = .unknown, identityKey: String? = nil,
                                readAgo: TimeInterval = 0, windows: [UsageWindow] = [],
                                resetCredits: UsageResetCredits? = nil) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider, accountRef: ref,
                     label: label, plan: plan, windows: windows, state: state,
                     readAt: Date().addingTimeInterval(-readAgo), toolVersion: toolVersion,
                     authentication: auth, identityKey: identityKey, resetCredits: resetCredits)
    }

    /// Claude weekly 75% + Fable 3%; Codex Personal 31% (pinned), Work session 92% + weekly 64%,
    /// Side session used up; Cursor plan total 30% used (synthetic total, not a split sum).
    private static func usages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, toolVersion: "2.1.317", windows: [
                window(10080, 75, resetsIn: 2 * 86400 + 4 * 3600),
                window(10080, 3, scope: "Fable", resetsIn: 2 * 86400 + 4 * 3600),
            ]),
            account(.codex, "standard", "alex.kim@example.com", .ok, plan: "prolite",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-personal", windows: [
                window(300, 20, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 31, resetsIn: 4 * 86400 + 9 * 3600),
            ]),
            account(.codex, "found:.codex-work", "Work", .ok, plan: "team", toolVersion: "0.166.0-alpha.5.1",
                    auth: .subscription, identityKey: "fixture-work", windows: [
                window(300, 92, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 64, resetsIn: 3 * 86400 + 2 * 3600),
            ]),
            account(.codex, "m-3c4d5e6f", "Side project", .ok, plan: "plus",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-side", windows: [
                window(300, 100, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 41, resetsIn: 5 * 86400 + 7 * 3600),
            ], resetCredits: UsageResetCredits(available: 2, expiries: [
                Date().addingTimeInterval(18 * 86400 + 6 * 3600), Date().addingTimeInterval(29 * 86400),
            ])),
            // An API-key profile: billed separately, no subscription window — stays listed.
            account(.codex, "found:.codex_second", "API profile", .notReporting, auth: .apiKey),
            // Synthetic total + dashboard pools — declared fixture values, never summed.
            account(.cursor, "cursor", "Cursor sign-in", .ok, windows: [
                window(43200, 30, resetsIn: 21 * 86400 + 5 * 3600),
                window(43200, 28, scope: CursorUsageParser.cursorModelsScope, resetsIn: 21 * 86400 + 5 * 3600),
                window(43200, 55, scope: CursorUsageParser.otherModelsScope, resetsIn: 21 * 86400 + 5 * 3600),
            ]),
        ]
    }

    /// Two comparable subscription accounts plus a warning account and an API profile:
    /// personal min(80,69)=69 beats side min(55,59)=55; plans differ (Pro Lite vs Plus).
    /// Claude + Codex + Cursor, the three local-only environments.
    private static func localThreeUsages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, windows: [
                window(300, 30, resetsIn: 2 * 3600),
                window(10080, 55, resetsIn: 4 * 86400),
            ]),
            account(.codex, "standard", "alex.kim@work.example", .ok, plan: "prolite",
                    auth: .subscription, identityKey: "fixture-p", windows: [
                window(300, 45, resetsIn: 1 * 3600),
                window(10080, 70, resetsIn: 6 * 86400),
            ]),
            // Synthetic total + dashboard pools — declared fixture values, never summed.
            account(.cursor, "cursor", "Cursor sign-in", .ok, windows: [
                window(43200, 30, resetsIn: 12 * 86400),
                window(43200, 28, scope: CursorUsageParser.cursorModelsScope, resetsIn: 12 * 86400),
                window(43200, 55, scope: CursorUsageParser.otherModelsScope, resetsIn: 12 * 86400),
            ]),
        ]
    }

    /// All seven providers present, consent-required ones already connected.
    private static func sevenUsages() -> [AccountUsage] {
        localThreeUsages() + [
            account(.grok, "current", "Grok", .ok, windows: [
                window(10080, 40, resetsIn: 3 * 86400),
            ]),
            account(.gemini, "current", "Gemini", .ok, windows: [
                UsageWindow(scope: "gemini-pro [input]", durationMinutes: nil, usedPercent: 65,
                            resetsAt: Date().addingTimeInterval(3600)),
                UsageWindow(scope: "gemini-pro [output]", durationMinutes: nil, usedPercent: 42,
                            resetsAt: Date().addingTimeInterval(3600)),
                UsageWindow(scope: "gemini-flash [input]", durationMinutes: nil, usedPercent: 80,
                            resetsAt: Date().addingTimeInterval(7200)),
                UsageWindow(scope: "gemini-flash [output]", durationMinutes: nil, usedPercent: 20,
                            resetsAt: Date().addingTimeInterval(7200)),
            ]),
            account(.devin, "current", "Devin", .ok, plan: "Solo", windows: [
                window(1440, 20, resetsIn: 8 * 3600),
                window(10080, 50, resetsIn: 5 * 86400),
            ]),
            account(.opencode, "current", "OpenCode", .ok, plan: "Go",
                    auth: .subscription, windows: [
                window(300, 15, resetsIn: 90 * 60),
                window(10080, 35, resetsIn: 4 * 86400),
            ]),
        ]
    }

    private static func guideUsages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, toolVersion: "2.1.317", windows: [
                window(10080, 75, resetsIn: 2 * 86400 + 4 * 3600),
            ]),
            account(.codex, "standard", "alex.kim@example.com", .ok, plan: "prolite",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-personal", windows: [
                window(300, 20, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 31, resetsIn: 4 * 86400 + 9 * 3600),
            ]),
            account(.codex, "found:.codex-work", "Work", .ok, plan: "team",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-work", windows: [
                window(300, 92, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 64, resetsIn: 3 * 86400 + 2 * 3600),
            ]),
            account(.codex, "m-3c4d5e6f", "Side project", .ok, plan: "plus",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-side", windows: [
                window(300, 45, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 41, resetsIn: 5 * 86400 + 7 * 3600),
            ]),
            account(.codex, "found:.codex_second", "API profile", .notReporting, auth: .apiKey),
        ]
    }

    /// Many demo Codex readings — unique ids, deliberately long masked email labels, mixed
    /// states (ok / notReporting API / failed-kept) to prove the compact list scrolls and clamps.
    private static func manyLongUsages() -> [AccountUsage] {
        var usages = guideUsages()
        for i in 1...14 {
            let id = "m-long-\(i)"
            if i == 7 {
                usages.append(account(.codex, id,
                    "api.key.holder.account.number.seven@example-domain.org", .notReporting,
                    auth: .apiKey))
            } else if i == 11 {
                usages.append(account(.codex, id,
                    "eleventh.codex.subscription.holder@example-company.net", .failed(.timeout),
                    auth: .subscription, identityKey: "fixture-long-\(i)", readAgo: 30 * 60,
                    windows: [window(10080, 55, resetsIn: 2 * 86400)]))
            } else {
                usages.append(account(.codex, id,
                    "very.long.masked.account.holder.number.\(i)@example-domain.org", .ok,
                    plan: i % 3 == 0 ? "pro" : "plus", auth: .subscription,
                    identityKey: "fixture-long-\(i)",
                    windows: [window(300, Double(10 + i * 4), resetsIn: 2 * 3600),
                              window(10080, Double(15 + i * 3), resetsIn: 4 * 86400)]))
            }
        }
        return usages
    }

    /// A timed-out re-read that kept its previous windows: the windows' resets are still in the
    /// future, so the non-ok state itself greys them; Claude separately exercises an aged ok reading.
    private static func staleUsages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, toolVersion: "2.1.317",
                    readAgo: UsageGuidance.maximumAge + 60, windows: [
                window(10080, 40, resetsIn: 3 * 86400),
            ]),
            account(.codex, "found:.codex-work", "Work", .failed(.timeout), plan: "team",
                    toolVersion: "0.166.0-alpha.5.1", auth: .subscription,
                    identityKey: "fixture-work", readAgo: 40 * 60, windows: [
                window(300, 92, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 64, resetsIn: 2 * 86400 + 4 * 3600),
            ]),
            account(.gemini, "current", "Gemini", .unavailable(.signInExpired),
                    readAgo: 40 * 60),
        ]
    }
}
