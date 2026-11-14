import AppKit
import SwiftUI
import Testing
@testable import SwitcherCore

/// The menu's limit row, from DESIGN.md › "한도 행 (메뉴 목록)": window name 84 · bar ≤88 · marker +
/// percent 58 · compact reset 52, 8pt gaps, in a 360pt menu with 14pt insets. Fonts are the ones
/// `UsageBarRow` sets. These are copies — `limitRowContractMatchesTheViews` pins the widths to the code.
enum MenuLimitRow {
    static let menuWidth = 360.0
    static let inset = 14.0
    static let gap = 8.0
    static var contentWidth: Double { menuWidth - 2 * inset }

    static let name = TextSlot(width: 84, style: TextStyle(size: 12), minimumScale: 0.85)
    static let barMaxWidth = 88.0
    static let percentWidth = 58.0
    /// Medium is the wider of the two weights the percent has had; what fits here fits at regular.
    static let percentStyle = TextStyle(size: 12, weight: .medium, monospacedDigits: true)
    static let markerStyle = TextStyle(size: 10)
    static let markerGap = 3.0
    static let markers = ["exclamationmark.triangle.fill", "xmark.octagon.fill", "clock"]
    static let reset = TextSlot(width: 52, style: TextStyle(size: 11, monospacedDigits: true), minimumScale: 0.8)
}

/// Strings that must fit a fixed-width cell or a one-line row, in every shipped language. The app's own
/// words must fit at full size: text that only fits by shrinking is smaller than the rows around it.
/// Defects that exist today are listed next to their test as known issues, and a listed one that no
/// longer occurs fails, so the lists stay true.
@Suite("UI string fit")
struct UIStringFitTests {
    // MARK: - Menu limit row

    @Test func limitRowColumnsFitTheMenu() {
        // name | bar | flexible spacer | percent | reset: four gaps
        let fixed = MenuLimitRow.name.width + MenuLimitRow.barMaxWidth + MenuLimitRow.percentWidth
            + MenuLimitRow.reset.width + 4 * MenuLimitRow.gap
        #expect(fixed <= MenuLimitRow.contentWidth)
    }

    /// "Session", "Weekly", … — every window kind, found by key so a new kind is covered.
    private static let windowNameKeys = L10nKey.allCases.filter {
        $0.rawValue.hasPrefix("usage.win.") && $0 != .usageWinScope
    }

    @Test(arguments: AppLanguage.allCases)
    func windowNamesFitTheNameColumn(language: AppLanguage) {
        #expect(Self.windowNameKeys.count >= 5)
        for key in Self.windowNameKeys {
            let text = L10n.string(key, language: language)
            #expect(MenuLimitRow.name.fit(text) == .fits,
                    "\(language.rawValue) \(key.rawValue): \(MenuLimitRow.name.describe(text))")
        }
    }

    /// A scoped window is named by its scope. The app names Cursor's two pools; the rest are vendor names
    /// as they arrive today.
    private static let scopes = [CursorUsageParser.cursorModelsScope, CursorUsageParser.otherModelsScope,
                                 "Fable", "Gemini Models", "Claude And Gpt Models"]
    /// Antigravity's group name needs 134pt: the menu's 84pt column shows "Claude And G…".
    private static let scopesCutToday: Set<String> = ["Claude And Gpt Models"]

    @Test(arguments: scopes)
    func scopeIsNotCutInTheNameColumn(scope: String) {
        withKnownIssue("vendor scope name is cut off in the menu") {
            #expect(MenuLimitRow.name.fit(scope) != .truncates, "\(MenuLimitRow.name.describe(scope))")
        } when: {
            Self.scopesCutToday.contains(scope)
        }
    }

    @Test func percentColumnHoldsAMarkerAndAFullPercent() throws {
        for symbol in MenuLimitRow.markers {
            let marker = try #require(MenuLimitRow.markerStyle.width(ofSymbol: symbol), "no symbol \(symbol)")
            let needed = marker + MenuLimitRow.markerGap + MenuLimitRow.percentStyle.width(of: "100%")
            #expect(needed <= MenuLimitRow.percentWidth, "\(symbol) + 100% needs \(needed)pt")
        }
    }

    /// Every reset the menu can print for a window of up to a month: `5m`, `23h 59m`, `30d 23h`.
    @Test func everyCompactCountdownFitsTheResetColumn() {
        let now = Date(timeIntervalSince1970: 0)
        var seen = Set<String>()
        var tooWide: [String] = []
        for minute in 1...(31 * 24 * 60) {
            let text = UsageText.compactCountdown(to: now.addingTimeInterval(Double(minute) * 60), from: now)
            guard seen.insert(text).inserted, MenuLimitRow.reset.fit(text) != .fits else { continue }
            tooWide.append(MenuLimitRow.reset.describe(text))
        }
        #expect(seen.count > 2000)
        #expect(tooWide.isEmpty, "\(tooWide.count) resets do not fit, e.g. \(tooWide.prefix(3))")
        #expect(MenuLimitRow.reset.fit("—") == .fits)
    }

    /// Longer windows (a yearly plan) may shrink, never lose characters.
    @Test func yearLongCountdownIsNeverCut() {
        let now = Date(timeIntervalSince1970: 0)
        for day in 32...366 {
            let text = UsageText.compactCountdown(to: now.addingTimeInterval(Double(day * 24 + 23) * 3600), from: now)
            #expect(MenuLimitRow.reset.fit(text) != .truncates, "\(MenuLimitRow.reset.describe(text))")
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func nowFitsTheResetColumn(language: AppLanguage) {
        let text = L10n.string(.usageNow, language: language)
        #expect(MenuLimitRow.reset.fit(text) == .fits, "\(language.rawValue): \(MenuLimitRow.reset.describe(text))")
    }

    // MARK: - Main window limit row

    /// The main window's name column: the full window name ("Monthly · Cursor Models"), never shrunk. Its
    /// width is read from the view, written either beside the menu's 84 or as `wideNameWidth`, so there is
    /// no copy here to fall behind.
    private static func wideNameColumn() throws -> TextSlot {
        let views = try viewSources()
        let match = try #require(views.firstMatch(of: /wideNameWidth: CGFloat = (\d+)/)
                                    ?? views.firstMatch(of: /frame\(width: compact \? 84 : (\d+)/),
                                 "the main window's name column width is not where this test reads it")
        return TextSlot(width: try #require(Double(match.output.1)), style: TextStyle(size: 12))
    }

    /// Antigravity's group name after a window kind is 168–196pt: cut wherever the column is narrower.
    /// It depends on the view's width, so it is not required to recur.
    private static let scopesTooWideForANarrowNameColumn: Set<String> = ["Claude And Gpt Models"]

    /// The widest full name a scope can get: the longest window kind in that language, then the scope.
    @Test(arguments: AppLanguage.allCases, scopes)
    func scopedWindowNameFitsTheWideNameColumn(language: AppLanguage, scope: String) throws {
        let column = try Self.wideNameColumn()
        let names = Self.windowNameKeys.map {
            L10n.string(.usageWinScope, language: language, [L10n.string($0, language: language), scope])
        }
        let widest = try #require(names.max { column.style.width(of: $0) < column.style.width(of: $1) })
        withKnownIssue("vendor scope name is cut off in the main window", isIntermittent: true) {
            #expect(column.fit(widest) == .fits, "\(language.rawValue): \(column.describe(widest))")
        } when: {
            Self.scopesTooWideForANarrowNameColumn.contains(scope)
        }
    }

    // MARK: - One-line rows of the menu

    /// Rows of the menu that hold localized text on one line. Their paddings and gaps are modelled from the
    /// views, not pinned to them; the `WRAPS` report of `scripts/ui-snapshots.sh` shows what really wrapped.
    enum MenuRow: String, CaseIterable, Sendable {
        case header, footer, bottomBar = "bottom bar", resetTickets = "reset tickets"
    }

    /// The width a row needs: its text plus the fixed padding, gaps and icons around it.
    private static func width(of row: MenuRow, in language: AppLanguage) throws -> Double {
        func text(_ key: L10nKey, _ args: CVarArg...) -> String { L10n.string(key, language: language, args) }
        let gap = MenuLimitRow.gap
        /// `ActionButtonStyle`: 12pt semibold with 12pt of padding either side.
        func button(_ title: String) -> Double { TextStyle(size: 12, weight: .semibold).width(of: title) + 24 }
        switch row {
        case .header:   // list title, then the Guide toggle with its dot and chevron
            let chevron = try #require(TextStyle(size: 9).width(ofSymbol: "chevron.right"))
            return TextStyle(size: 14, weight: .semibold).width(of: text(.usageListTitle)) + gap
                + TextStyle(size: 11.5).width(of: text(.usageSegGuide)) + 4 + 5 + 4 + chevron
        case .footer:   // the longer of two text lines beside the 16pt refresh button
            let longest = text(.usageDurDH, 30, 23)
            let lines = [text(.usageUpdatedAgo, longest), text(.usageNextUpdate, longest),
                         text(.usageRefreshingSoon), text(.usageRefreshing)]
            return (lines.map(TextStyle(size: 11).width(of:)).max() ?? 0) + gap + 16
        case .bottomBar:   // Open window · gear · Quit
            let gear = try #require(TextStyle(size: 13).width(ofSymbol: "gearshape"))
            return button(text(.uiOpenWindow)) + gear + button(text(.uiQuit)) + 3 * gap
        case .resetTickets:   // ticket icon, then the count and the first expiry; one line, cut if too long
            let small = TextStyle(size: 11)
            let ticket = try #require(small.width(ofSymbol: "ticket"))
            return ticket + gap + small.width(of: text(.usageResetCreditsExpiry, 99, text(.usageDurDH, 30, 23)))
        }
    }

    /// A row wider than the menu's content wraps to a second line or squeezes its neighbours.
    @Test(arguments: MenuRow.allCases, AppLanguage.allCases)
    func menuRowFitsOneLine(row: MenuRow, language: AppLanguage) throws {
        let needed = try Self.width(of: row, in: language)
        #expect(needed <= MenuLimitRow.contentWidth,
                "\(language.rawValue) \(row.rawValue) needs \(needed.rounded())pt of \(MenuLimitRow.contentWidth)")
    }

    // MARK: - Gear menu

    /// AppKit sizes a menu to its widest item and never cuts it, so the check is the menu's own width: the
    /// gear menu should not be wider than the 360pt panel it opens from. It can't be snapshotted offscreen
    /// (it only exists as an on-screen NSMenu), so this is its regression check.
    @Test(arguments: AppLanguage.allCases)
    @MainActor
    func gearMenuIsNoWiderThanTheMenuPanel(language: AppLanguage) throws {
        let menu = NSMenu()
        for key in try Self.gearMenuKeys() {
            // widest plausible arguments: a name for %@, two digits for %d
            let arguments: [CVarArg] = LocalizationTests.placeholders(Strings.en[key] ?? "")
                .map { $0.hasSuffix("@") ? ProductInfo.name as CVarArg : 99 as CVarArg }
            let item = menu.addItem(withTitle: L10n.string(key, language: language, arguments),
                                    action: nil, keyEquivalent: "")
            item.state = .on   // toggles reserve the checkmark column
        }
        menu.items.first?.submenu = NSMenu()   // the pickers are submenus: the arrow column is reserved too
        // Spanish: "Mostrar el nombre de la cuenta en la barra de menús" makes the menu about 396pt wide.
        withKnownIssue("the Spanish gear menu is wider than the menu panel") {
            #expect(menu.size.width <= MenuLimitRow.menuWidth,
                    "\(language.rawValue) gear menu is \(menu.size.width)pt wide")
        } when: {
            language == .es
        }
    }

    /// Strings in `SettingsMenu.swift` that are not menu items: the gear's own label, alerts and About.
    private static let notGearMenuItems: Set<L10nKey> = [
        .uiSettings, .uiCancel, .uiAboutCredits, .uiConnectUsageTitle, .uiConnectUsageEnable,
        .suggestionFlushConfirm, .suggestionFlushMessage, .suggestionFlushFailure,
    ]

    /// Every string the gear menu shows: all the keys `SettingsMenu.swift` uses except the ones listed
    /// above, so a new item is covered without editing this test (a new alert text has to be listed).
    private static func gearMenuKeys() throws -> [L10nKey] {
        let source = try String(contentsOf: appSources.appendingPathComponent("SettingsMenu.swift"), encoding: .utf8)
        let byName = Dictionary(uniqueKeysWithValues: L10nKey.allCases.map { ("\($0)", $0) })
        let keys = try Set(source.matches(of: /L10n\.t\(\.(\w+)/).map { try #require(byName[String($0.output.1)]) })
            .subtracting(notGearMenuItems)
        try #require(keys.count >= 10, "SettingsMenu.swift no longer names its strings as L10n.t(.key)")
        return keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - The measurement itself

    /// `Sources/ClaudeSwitcher`: the views. The test target can't import the app executable.
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ClaudeSwitcher")

    /// Every view file as one string, for the checks that read a layout number out of the code.
    private static func viewSources() throws -> String {
        try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// The widths in `MenuLimitRow` are copies of literals in the views. This fails when a column changes
    /// in the code, so DESIGN.md, the view and `MenuLimitRow` change together.
    @Test func limitRowContractMatchesTheViews() throws {
        let views = try Self.viewSources()
        for literal in [
            "frame(width: compact ? \(Int(MenuLimitRow.name.width)) :",
            "frame(maxWidth: compact ? \(Int(MenuLimitRow.barMaxWidth)) :",
            "frame(width: \(Int(MenuLimitRow.percentWidth)), alignment: .trailing)",
            "frame(width: compact ? \(Int(MenuLimitRow.reset.width)) :",
            ".frame(width: \(Int(MenuLimitRow.menuWidth)))",
        ] {
            #expect(views.contains(literal), "no view has `\(literal)`: update MenuLimitRow and DESIGN.md with the view")
        }
    }

    /// The tests measure with AppKit; the app lays out with SwiftUI. They must agree, or every result above is off.
    @Test @MainActor
    func appKitMeasurementMatchesSwiftUILayout() throws {
        let samples = ["Weekly", "Semanal", "주간", "セッション", "每周", "23h 59m", "100%", "Cursor Models"]
        let styles: [(TextStyle, Font)] = [
            (TextStyle(size: 12), .system(size: 12)),
            (TextStyle(size: 12, weight: .medium, monospacedDigits: true), .system(size: 12, weight: .medium).monospacedDigit()),
            (TextStyle(size: 11, monospacedDigits: true), .system(size: 11).monospacedDigit()),
            (TextStyle(size: 14, weight: .semibold), .system(size: 14, weight: .semibold)),
        ]
        for (style, font) in styles {
            for sample in samples {
                let laidOut = NSHostingView(rootView: Text(sample).font(font).fixedSize()).fittingSize.width
                #expect(abs(laidOut - style.width(of: sample).rounded(.up)) <= 1,
                        "'\(sample)' at \(style.size)pt: SwiftUI \(laidOut), AppKit \(style.width(of: sample))")
            }
        }
        for symbol in MenuLimitRow.markers {
            let laidOut = NSHostingView(rootView: Image(systemName: symbol).font(.system(size: 10)).fixedSize())
                .fittingSize.width
            let measured = try #require(MenuLimitRow.markerStyle.width(ofSymbol: symbol))
            #expect(abs(laidOut - measured) <= 1, "\(symbol): SwiftUI \(laidOut), AppKit \(measured)")
        }
    }
}
