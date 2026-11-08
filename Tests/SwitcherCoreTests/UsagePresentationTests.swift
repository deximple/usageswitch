import Foundation
import Testing
@testable import SwitcherCore

private func usage(_ p: UsageProvider, _ ref: String, state: UsageState = .ok,
                   age: TimeInterval = 0, auth: UsageAuthentication = .unknown,
                   identityKey: String? = nil) -> AccountUsage {
    AccountUsage(id: "\(p.rawValue):\(ref)", provider: p, accountRef: ref, label: ref,
                 plan: nil, windows: [], state: state, readAt: Date().addingTimeInterval(-age),
                 toolVersion: nil, authentication: auth, identityKey: identityKey)
}
private func inst(_ p: UsageProvider) -> UsageInstallation {
    UsageInstallation(provider: p, cli: URL(fileURLWithPath: "/bin/x"), app: nil)
}

@Suite("Usage presentation")
struct UsagePresentationTests {
    @Test("claude-only readings keep every account row, CLI env, verified when fresh")
    func claudeOnly() {
        let rows = [usage(.claude, "cli", auth: .subscription, identityKey: "k"),
                    usage(.claude, "cli2", auth: .subscription, identityKey: "j")]
        let out = UsagePresentations.accounts(readings: rows, installations: [inst(.claude)],
                                              claude: nil, codex: nil, now: Date())
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.environment == .cli && $0.login == .verified })
    }

    @Test("exactly three providers present -> three presentations")
    func three() {
        let rows = [usage(.claude, "cli"), usage(.codex, "standard"), usage(.cursor, "cursor")]
        let out = UsagePresentations.accounts(
            readings: rows, installations: [.claude, .codex, .cursor].map { inst($0) },
            claude: nil, codex: nil, now: Date())
        #expect(out.count == 3)
        #expect(out.map { $0.usage.provider } == [.claude, .codex, .cursor])
    }

    @Test("same-email CLI and App stay distinct owners, no quota fabricated for App")
    func cliVsApp() {
        let acc = AccountStatus(id: "acc1", label: "Work", customName: nil,
                                defaultName: "a@x.com", email: "a@x.com",
                                accountUuid: "u1", orgUuid: "o1", isActive: true,
                                snapshot: .ready, capturedAt: nil, sessionExpiresAt: nil)
        let cs = ClaudeStatus(installed: true, running: true, pid: 1, version: "1",
                              activeAccountUuid: "u1", activeOrgUuid: "o1",
                              activeEmail: "a@x.com", codeSessions: 0)
        let claude = SwitcherStatus(
            claude: cs, accounts: [acc],
            relaunchers: [], suspendedRelaunchers: [], originalBackup: nil,
            pendingJournal: false, nativeMultiAccount: false, warnings: [])
        let rows = [usage(.claude, "cli", auth: .subscription, identityKey: "k")]
        let out = UsagePresentations.accounts(readings: rows, installations: [inst(.claude)],
                                              claude: claude, codex: nil, now: Date())
        #expect(out.count == 2)
        let cli = out.first { $0.environment == .cli }
        let app = out.first { $0.environment == .app }
        #expect(cli?.usage.id == "claude:cli" && app?.usage.id == "claude:app:acc1")
        #expect(app?.login == .saved && app?.badgeActive == true)
        #expect(app?.usage.windows.isEmpty == true) // App quota never fabricated
    }

    @Test("registered-but-uncollected codex profile gets neutral row; phantom excluded")
    func codexRegistration() {
        let codex = CodexStatus(
            installed: true, version: "1",
            accounts: [
                CodexAccount(id: "extra", kind: .found, label: "Extra", customName: nil,
                             defaultName: "Extra", home: "/h", homePath: "/h",
                             identity: nil, state: .signedIn, pids: []),
                CodexAccount(id: "standard", kind: .standard, label: "Home", customName: nil,
                             defaultName: "~", home: "/h", homePath: "/h",
                             identity: nil, state: .signedIn, pids: []),
            ], hiddenCount: 0)
        // no codex readings, no codex installation -> phantom standard must not appear
        let out = UsagePresentations.accounts(readings: [], installations: [],
                                              claude: nil, codex: codex, now: Date())
        #expect(out.count == 1)
        #expect(out[0].usage.accountRef == "extra" && out[0].usage.state == .notReporting)
    }

    @Test("stale or failed readings make no login claim")
    func honestLogin() {
        let now = Date()
        let rows = [usage(.claude, "cli", state: .ok, age: 601),        // stale -> unknown
                    usage(.claude, "cli2", state: .failed(.network))]   // failed -> unknown
        let out = UsagePresentations.accounts(readings: rows, installations: [inst(.claude)],
                                              claude: nil, codex: nil, now: now)
        #expect(out.allSatisfy { $0.login == .unknown && !$0.badgeActive })
    }

    @Test("Antigravity app-only rows use the app environment and provider glyph")
    func antigravityEnvironment() {
        let installation = UsageInstallation(
            provider: .antigravity, cli: nil, app: URL(fileURLWithPath: "/Applications/Antigravity.app"))
        let out = UsagePresentations.accounts(
            readings: [usage(.antigravity, "current")], installations: [installation],
            claude: nil, codex: nil, now: Date())
        #expect(out.first?.environment == .app)
        #expect(UsageText.providerName(.antigravity) == "Antigravity")
        #expect(UsageText.providerGlyph(.antigravity) == "sparkles")
    }
}

@Suite("Usage name draft")
struct UsageNameDraftTests {
    @Test("ordinary name seeds editable draft; unchanged cannot save")
    func ordinary() {
        let d = UsageNameDraft(currentName: "Work", customName: nil,
                               defaultName: "Work", showEmails: true)
        #expect(d.text == "Work" && !d.canSave) // unchanged is not a save
    }

    @Test("hidden-email alias starts empty+masked placeholder, disabled until edit")
    func hiddenEmail() {
        var d = UsageNameDraft(currentName: "a@x.com", customName: "a@x.com",
                               defaultName: "a@x.com", showEmails: false)
        #expect(d.text.isEmpty && !d.canSave && d.placeholder != nil)
        d.edit("Renamed")
        #expect(d.canSave && (try? d.saveValue()) == "Renamed")
    }

    @Test("restore sets intent only when an alias exists; typing clears it")
    func restore() {
        var d = UsageNameDraft(currentName: "Work", customName: "Work",
                               defaultName: "a@x.com", showEmails: true)
        #expect(d.canRestore)
        d.restoreDefault()
        let v = try? d.saveValue()
        #expect(d.restoreToDefault && v == nil)
        d.edit("New")
        #expect(!d.restoreToDefault)
        // no alias -> Default is a no-op, restore can't be armed
        let d2 = UsageNameDraft(currentName: "a@x.com", customName: nil,
                                defaultName: "a@x.com", showEmails: true)
        #expect(!d2.canRestore)
    }

    @Test("blank is INVALID never a restore; 41/newline/bidi all fail")
    func invalid() throws {
        var d = UsageNameDraft(currentName: "Work", customName: nil,
                               defaultName: "Work", showEmails: true)
        d.edit("   ")
        #expect(!d.canSave)
        #expect(throws: SwitcherError.self) { try d.saveValue() }
        d.edit(String(repeating: "a", count: 41))
        #expect(!d.canSave)
        #expect(throws: SwitcherError.self) { try d.saveValue() }
        d.edit("a\nb")
        #expect(!d.canSave)
        d.edit("a\u{202E}b")
        #expect(!d.canSave)
    }
}
