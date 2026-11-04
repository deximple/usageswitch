import Foundation
import SwitcherCore

/// Demo data for `--ui-fixture` screenshots: example accounts only, clearly labelled as a demo, no real store.
@MainActor
enum Fixtures {
    static func model(named name: String?) -> SwitcherModel? {
        guard let name else { return nil }
        let base = status(active: "work")
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

    static func status(active: String, expired: Set<String> = []) -> SwitcherStatus {
        let rows = accounts.map { a in
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
        switch name {
        case "codex-signin": model = CodexModel(demo: codexStatus(), demoPhase: .signingIn(id: nil))
        default: model = CodexModel(demo: codexStatus())
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

    static func codexStatus() -> CodexStatus {
        func identity(_ email: String, _ plan: String) -> CodexIdentity { CodexIdentity(mode: .chatgpt, email: email, plan: plan) }
        let accounts = [
            CodexAccount(id: "standard", kind: .standard, label: "alex.kim@example.com", customName: nil,
                         defaultName: "alex.kim@example.com", home: "/Users/alex/.codex", homePath: "~/.codex",
                         identity: identity("alex.kim@example.com", "pro"), state: .running, pids: [4243]),
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
        return CodexStatus(installed: true, version: "26.1013.40934", accounts: accounts, found: found, hiddenCount: 1)
    }

    // MARK: - Usage tab

    /// Demo usage for `--ui-fixture usage|usage-all|usage-empty|usage-stale`. Dates are relative to now.
    static func usageModel(named name: String, settings: SwitcherModel) -> UsageModel {
        switch name {
        case "usage-all":
            return UsageModel(demo: usages(), segment: .all, settings: settings)
        case "usage-empty":
            return UsageModel(demo: [account(.claude, "cli", "CLI sign-in", .unavailable(.cliMissing))],
                              settings: settings)
        case "usage-stale":
            return UsageModel(demo: staleUsages(), segment: .all, settings: settings)
        default:
            settings.setUsagePins([personalWeeklyKey])
            return UsageModel(demo: usages(), settings: settings)
        }
    }

    private static let personalWeeklyKey = "codex:personal/weekly/"

    private static func window(_ minutes: Int?, _ used: Double, scope: String? = nil,
                               resetsIn: TimeInterval) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used,
                    resetsAt: Date().addingTimeInterval(resetsIn))
    }

    private static func account(_ provider: UsageProvider, _ ref: String, _ label: String,
                                _ state: UsageState, plan: String? = nil, toolVersion: String? = nil,
                                readAgo: TimeInterval = 0, windows: [UsageWindow] = []) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider, accountRef: ref,
                     label: label, plan: plan, windows: windows, state: state,
                     readAt: Date().addingTimeInterval(-readAgo), toolVersion: toolVersion)
    }

    /// Claude weekly 75% + Fable 3%; Codex Personal 31% (pinned), Work session 92% + weekly 64%,
    /// Side session used up; Cursor Auto 54% / API 12%.
    private static func usages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, toolVersion: "2.1.317", windows: [
                window(10080, 75, resetsIn: 2 * 86400 + 4 * 3600),
                window(10080, 3, scope: "Fable", resetsIn: 2 * 86400 + 4 * 3600),
            ]),
            account(.codex, "personal", "alex.kim@example.com", .ok, plan: "prolite",
                    toolVersion: "0.166.0-alpha.5.1", windows: [
                window(10080, 31, resetsIn: 4 * 86400 + 9 * 3600),
            ]),
            account(.codex, "work", "Work", .ok, plan: "team", toolVersion: "0.166.0-alpha.5.1", windows: [
                window(300, 92, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 64, resetsIn: 3 * 86400 + 2 * 3600),
            ]),
            account(.codex, "side", "Side project", .ok, plan: "plus",
                    toolVersion: "0.166.0-alpha.5.1", windows: [
                window(300, 100, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 41, resetsIn: 5 * 86400 + 7 * 3600),
            ]),
            account(.cursor, "cursor", "Cursor sign-in", .ok, windows: [
                window(43200, 54, scope: "Auto", resetsIn: 21 * 86400 + 5 * 3600),
                window(43200, 12, scope: "API", resetsIn: 21 * 86400 + 5 * 3600),
            ]),
        ]
    }

    /// A timed-out re-read that kept its previous windows: the windows' resets are still in the
    /// future, so the non-ok state itself is what greys them — with a fresh Claude card for contrast.
    private static func staleUsages() -> [AccountUsage] {
        [
            account(.claude, "cli", "CLI sign-in", .ok, toolVersion: "2.1.317", windows: [
                window(10080, 40, resetsIn: 3 * 86400),
            ]),
            account(.codex, "work", "Work", .failed(.timeout), plan: "team",
                    toolVersion: "0.166.0-alpha.5.1", readAgo: 40 * 60, windows: [
                window(300, 92, resetsIn: 1 * 3600 + 13 * 60),
                window(10080, 64, resetsIn: 2 * 86400 + 4 * 3600),
            ]),
        ]
    }
}
