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

    @Test("windows that share a scope lead with their kind, so no two rows read the same")
    func sharedScope() {
        // Antigravity: a weekly and a 5-hour window per model group
        let windows = [window(10080, scope: "Gemini Models"), window(300, scope: "Gemini Models"),
                       window(10080, scope: "Claude And Gpt Models")]
        let names = windows.map { UsageText.compactName(of: $0, among: windows) }
        #expect(names == [UsageText.name(of: windows[0]), UsageText.name(of: windows[1]),
                          "Claude And Gpt Models"])
        #expect(Set(names).count == names.count)
        #expect(names[0].hasPrefix(L10n.t(.usageWinWeekly)))
        #expect(names[1].hasPrefix(L10n.t(.usageWinSession)))
    }

    @Test("the scope is matched as reported, not by position in the list")
    func sharedScopeAnyOrder() {
        let weekly = window(10080, scope: "Gemini Models")
        let session = window(300, scope: "Gemini Models")
        #expect(UsageText.compactName(of: session, among: [window(10080), session, weekly])
            == UsageText.name(of: session))
        // the window alone in the list is not its own sibling
        #expect(UsageText.compactName(of: weekly, among: [weekly]) == "Gemini Models")
    }
}
