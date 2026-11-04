import AppKit
import SwiftUI
import SwitcherCore

/// The gear menu: every app-wide setting in one place (language, start at login, what the menu bar and the lists
/// show) plus the data folder and About.
struct SettingsMenu: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        Menu {
            Picker(L10n.t(.uiLanguage), selection: Binding(
                get: { model.languageChoice?.rawValue ?? "system" },
                set: { model.setLanguage($0 == "system" ? nil : AppLanguage(rawValue: $0)) })) {
                Text(L10n.t(.uiLanguageSystem, AppLanguage.system().nativeName)).tag("system")
                Divider()
                ForEach(AppLanguage.allCases) { lang in Text(lang.nativeName).tag(lang.rawValue) }
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy)   // the language is applied to everything at once; not during a switch
            Divider()
            Toggle(L10n.t(.uiLaunchAtLogin), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .disabled(model.isDemo)
            Toggle(L10n.t(.uiSettingShowName), isOn: Binding(get: { model.menuBarShowsName }, set: { model.setMenuBarShowsName($0) }))
            Toggle(L10n.t(.uiSettingShowEmails), isOn: Binding(get: { model.showEmails }, set: {
                model.setShowEmails($0)
                codex.revealedEmails = []
            }))
            Toggle(L10n.t(.uiSettingShowUsage), isOn: Binding(get: { model.menuBarShowsUsage },
                                                            set: { model.setMenuBarShowsUsage($0) }))
            // On-by-confirmation only: this toggle reads Cursor's sign-in and calls Cursor's API.
            Toggle(L10n.t(.uiSettingCursorUsage), isOn: Binding(get: { model.cursorUsageEnabled }, set: { on in
                if on { confirmCursorUsage() } else { model.setCursorUsageEnabled(false); usage.refresh() }
            }))
            .disabled(model.isDemo)
            if let hidden = codex.status?.hiddenCount, hidden > 0 {
                Divider()
                Button(L10n.t(.codexUnhide, hidden)) { codex.unhideAll() }
                    .disabled(codex.isBusy)
            }
            Divider()
            Button(L10n.t(.uiOpenDataFolder)) {
                NSWorkspace.shared.activateFileViewerSelecting([model.dataFolder])
            }
            .disabled(model.isDemo)
            Button(L10n.t(.uiCheckForUpdates)) { NSWorkspace.shared.open(ProductInfo.releasesURL) }
            Button(L10n.t(.uiAbout, ProductInfo.name)) {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t(.uiSettings))
        .accessibilityLabel(L10n.t(.uiSettings))
    }

    /// Turning Cursor usage on asks first: it is the only way the app reads the Keychain or goes online.
    private func confirmCursorUsage() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.usageCursorAlertTitle)
        alert.informativeText = L10n.t(.usageCursorAlertBody)
        alert.addButton(withTitle: L10n.t(.usageCursorAlertOn))
        alert.addButton(withTitle: L10n.t(.uiCancel))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.setCursorUsageEnabled(true)
            usage.refresh()
        }
    }

    /// Shown in the About panel under the version: what the app is, and that it's independent of both vendors.
    private static var aboutCredits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: L10n.t(.uiAboutCredits), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }
}
