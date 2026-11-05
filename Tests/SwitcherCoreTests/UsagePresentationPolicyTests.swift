import Foundation
import Testing
@testable import SwitcherCore

@Suite("Environment presentation regressions")
struct UsagePresentationPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func reading(_ provider: UsageProvider = .codex, ref: String = "standard",
                         age: TimeInterval = 0, state: UsageState = .ok,
                         windows: [UsageWindow] = []) -> AccountUsage {
        AccountUsage(id: "\(provider.rawValue):\(ref)", provider: provider,
                     accountRef: ref, label: "Old collected name", plan: nil, windows: windows,
                     state: state, readAt: now.addingTimeInterval(-age), toolVersion: nil)
    }

    private func account(_ id: String, name: String = "Personal",
                         kind: CodexProfile.Kind = .managed,
                         identity: CodexIdentity? = CodexIdentity(mode: .chatgpt, email: "a@work.example"),
                         pids: [Int32] = []) -> CodexAccount {
        CodexAccount(id: id, kind: kind, label: name, customName: name,
                     defaultName: "a@work.example", home: "/fixture/\(id)",
                     homePath: "/fixture/\(id)", identity: identity,
                     state: .signedIn, pids: pids)
    }

    private func present(_ readings: [AccountUsage], accounts: [CodexAccount],
                         found: [CodexAccount] = []) -> [UsageAccountPresentation] {
        UsagePresentations.accounts(
            readings: readings,
            installations: [UsageInstallation(provider: .codex, cli: URL(fileURLWithPath: "/fixture/codex"),
                                               app: URL(fileURLWithPath: "/fixture/Codex.app"))],
            claude: nil, codex: CodexStatus(installed: true, version: nil, accounts: accounts,
                                           found: found, hiddenCount: 0), now: now)
    }

    @Test("current registry names change without modifying collected usage")
    func currentNames() {
        let original = reading()
        let out = present([original], accounts: [account("standard", name: "Studio", kind: .standard)])
        #expect(out.first?.name == "Studio")
        #expect(out.first?.usage == original)
        #expect(out.first?.owner == .codex("standard"))
    }

    @Test("querying a managed home does not make it the current CLI")
    func managedNotCurrent() {
        let out = present([reading(ref: "managed")], accounts: [account("managed")])
        #expect(out.first?.login == .saved)
        #expect(out.first?.environment == .app)
        #expect(out.first?.badgeActive == false)
    }

    @Test("future timestamps never verify or activate the current CLI")
    func future() {
        let out = present([reading(age: -1)], accounts: [account("standard", kind: .standard)])
        #expect(out.first?.login == .saved)
        #expect(out.first?.badgeActive == false)
    }

    @Test("unregistered found homes cannot own a collected row")
    func foundIsNotOwner() {
        let out = present([reading(ref: "found")], accounts: [], found: [account("found", kind: .found)])
        #expect(out.first?.owner == nil)
        #expect(out.first?.name == "Old collected name")
    }

    @Test("API mode comes from explicit identity, never from missing credentials")
    func apiMode() {
        let out = present([], accounts: [
            account("api", kind: .found, identity: CodexIdentity(mode: .apiKey)),
            account("unknown", kind: .found, identity: nil),
        ])
        #expect(out.first { $0.usage.accountRef == "api" }?.usage.authentication == .apiKey)
        #expect(out.first { $0.usage.accountRef == "unknown" }?.usage.authentication == .unknown)
    }

    @Test("unusable usage credentials do not prove CLI logout")
    func unknownLogin() {
        let out = UsagePresentations.accounts(
            readings: [reading(.gemini, ref: "current", state: .unavailable(.noSignIn))],
            installations: [UsageInstallation(provider: .gemini, cli: URL(fileURLWithPath: "/fixture/gemini"), app: nil)],
            claude: nil, codex: nil, now: now)
        #expect(out.first?.login == .unknown)
        #expect(out.first?.environment == .cli)
        #expect(out.first?.badgeActive == false)
    }

    @Test("compact selection is constrained, common, then scoped, with stable ties")
    func compactOrder() {
        func window(_ scope: String?, _ used: Double) -> UsageWindow {
            UsageWindow(scope: scope, durationMinutes: 300, usedPercent: used,
                        resetsAt: now.addingTimeInterval(3600))
        }
        let windows = [window("first", 90), window(nil, 20), window("tied", 90),
                       window(nil, 10), window("invalid", 101)]
        let original = reading(windows: windows)
        #expect(UsagePresentations.compactWindows(original, now: now) == [windows[0], windows[1], windows[3]])
        #expect(original.windows == windows)
        #expect(UsagePresentations.compactWindows(reading(age: 601, windows: windows), now: now)
                == Array(windows.prefix(3)))
        #expect(UsagePresentations.compactWindows(reading(state: .failed(.network), windows: windows), now: now)
                == Array(windows.prefix(3)))
    }

    @Test("ordinary aliases remain editable even when the default is a hidden email")
    func ordinaryAlias() throws {
        var draft = UsageNameDraft(currentName: "Personal", customName: "Personal",
                                   defaultName: "a@work.example", showEmails: false)
        #expect(draft.text == "Personal")
        #expect(!draft.canSave)
        draft.edit("Personal ")
        #expect(!draft.canSave)
        draft.restoreDefault()
        #expect(draft.text.isEmpty && draft.canSave)
        #expect(try draft.saveValue() == nil)
        #expect(draft.placeholder == Privacy.maskEmails(in: "a@work.example"))
        draft.edit("Personal")
        #expect(!draft.restoreToDefault && !draft.canSave)
    }
}
