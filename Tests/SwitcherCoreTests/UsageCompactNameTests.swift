import Foundation
import Testing

@testable import SwitcherCore

@Suite("Compact window name")
struct UsageCompactNameTests {
    private func window(_ minutes: Int?, scope: String? = nil) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: 10, resetsAt: nil)
    }

    @Test("a window without a scope is named by its kind")
    func unscoped() {
        let weekly = window(10080)
        #expect(UsageText.compactName(of: weekly, among: [weekly, window(300)])
            == L10n.t(.usageWinWeekly))
    }

    @Test("a scope that names one window stands alone")
    func uniqueScope() {
        let fable = window(10080, scope: "Fable")
        #expect(UsageText.compactName(of: fable, among: [window(10080), fable]) == "Fable")
        // Cursor: three monthly windows, each scope its own
        let cursor = [window(43200), window(43200, scope: "Cursor Models"),
                      window(43200, scope: "Other Models")]
        #expect(cursor.map { UsageText.compactName(of: $0, among: cursor) }
            == [L10n.t(.usageWinMonthly), "Cursor Models", "Other Models"])
    }

    @Test("windows that share a scope are named by their kind; the scope is their group's caption")
    func sharedScope() {
        // Antigravity: a weekly and a 5-hour window per model group
        let windows = [window(10080, scope: "Gemini Models"), window(300, scope: "Gemini Models"),
                       window(10080, scope: "Claude And Gpt Models")]
        let names = windows.map { UsageText.compactName(of: $0, among: windows) }
        #expect(names == [L10n.t(.usageWinWeekly), L10n.t(.usageWinSession), "Claude And Gpt Models"])
    }

    @Test("the scope is matched as reported, not by position in the list")
    func sharedScopeAnyOrder() {
        let weekly = window(10080, scope: "Gemini Models")
        let session = window(300, scope: "Gemini Models")
        #expect(UsageText.compactName(of: session, among: [window(10080), session, weekly])
            == L10n.t(.usageWinSession))
        // the window alone in the list is not its own sibling
        #expect(UsageText.compactName(of: weekly, among: [weekly]) == "Gemini Models")
    }
}

@Suite("Menu window groups")
struct UsageMenuGroupTests {
    private func window(_ minutes: Int?, scope: String? = nil, used: Double = 10) -> UsageWindow {
        UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used, resetsAt: nil)
    }

    @Test("a scope shared by two windows becomes one caption over both")
    func sharedScopeIsCaptioned() {
        let weekly = window(10080, scope: "Claude And Gpt Models")
        let session = window(300, scope: "Claude And Gpt Models")
        #expect(UsageText.menuGroups([weekly, session], among: [weekly, session])
            == [UsageMenuGroup(caption: "Claude And Gpt Models", windows: [weekly, session])])
    }

    @Test("windows without a shared scope stand alone, in their own order")
    func otherWindowsStandAlone() {
        let cursor = [window(43200), window(43200, scope: "Cursor Models"), window(43200, scope: "Other Models")]
        #expect(UsageText.menuGroups(cursor, among: cursor)
            == cursor.map { UsageMenuGroup(caption: nil, windows: [$0]) })
    }

    @Test("a group sits where its first shown window is, and gathers its later windows")
    func groupsKeepFirstPosition() {
        // shown in priority order: Claude weekly, Gemini session, Claude session
        let claudeWeekly = window(10080, scope: "Claude And Gpt Models", used: 75)
        let geminiSession = window(300, scope: "Gemini Models", used: 60)
        let claudeSession = window(300, scope: "Claude And Gpt Models", used: 40)
        let geminiWeekly = window(10080, scope: "Gemini Models", used: 25)
        let all = [geminiWeekly, geminiSession, claudeWeekly, claudeSession]
        #expect(UsageText.menuGroups([claudeWeekly, geminiSession, claudeSession], among: all) == [
            UsageMenuGroup(caption: "Claude And Gpt Models", windows: [claudeWeekly, claudeSession]),
            UsageMenuGroup(caption: "Gemini Models", windows: [geminiSession]),
        ])
    }

    @Test("a shown window whose sibling is folded away still gets the caption")
    func siblingNotShown() {
        let weekly = window(10080, scope: "Gemini Models")
        let session = window(300, scope: "Gemini Models")
        #expect(UsageText.menuGroups([session], among: [weekly, session])
            == [UsageMenuGroup(caption: "Gemini Models", windows: [session])])
    }

    @Test("nothing shown, nothing grouped")
    func empty() {
        #expect(UsageText.menuGroups([], among: [window(300, scope: "Gemini Models")]).isEmpty)
    }
}
