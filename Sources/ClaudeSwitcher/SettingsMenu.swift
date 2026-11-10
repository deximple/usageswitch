import AppKit
import SwiftUI
import SwitcherCore

/// The gear menu: every app-wide setting in one place (language, start at login, what the menu bar and the lists
/// show) plus the data folder and About.
struct SettingsMenu: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var usage: UsageModel
    @State private var confirmingLearningFlush = false

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
            Picker(L10n.t(.uiAppearance), selection: Binding(
                get: { model.appearanceChoice }, set: { model.setAppearance($0) })) {
                Text(L10n.t(.uiAppearanceSystem)).tag(AppAppearance.system)
                Text(L10n.t(.uiAppearanceLight)).tag(AppAppearance.light)
                Text(L10n.t(.uiAppearanceDark)).tag(AppAppearance.dark)
            }
            .pickerStyle(.menu)
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
            Toggle(L10n.t(.uiSettingUsageAlerts), isOn: Binding(get: { model.usageAlertsEnabled },
                                                              set: { model.setUsageAlertsEnabled($0) }))
            Toggle(L10n.t(.suggestionQuietSignalSetting),
                   isOn: Binding(get: { model.suggestionQuietSignal },
                                 set: { model.setSuggestionQuietSignal($0) }))
            Picker(L10n.t(.uiSettingWarnLevel), selection: Binding(
                get: { model.usageWarnPercent }, set: { model.setUsageWarnPercent($0) })) {
                Text(L10n.t(.usageUsedPercent, 70)).tag(70)
                Text(L10n.t(.usageUsedPercent, 80)).tag(80)
                Text(L10n.t(.usageUsedPercent, 90)).tag(90)
            }
            .pickerStyle(.menu)
            // Usage Connections: only detected or previously granted consent-required
            // providers appear; an absent tool's old grant stays revocable here.
            let consentProviders = Set(usage.installations.map { $0.provider })
                .union(model.enabledUsageProviders)
                .filter { $0.requiresConsent }
                .sorted { $0.rawValue < $1.rawValue }
            if !consentProviders.isEmpty {
                Menu(L10n.t(.uiUsageConnections)) {
                    ForEach(consentProviders, id: \.self) { provider in
                        Toggle(UsageText.providerName(provider), isOn: Binding(
                            get: { model.enabledUsageProviders.contains(provider) },
                            set: { on in
                                if on {
                                    Self.enableUsageConnection(provider, model: model, usage: usage)
                                } else {
                                    model.setUsageConnection(provider, on: false)
                                    usage.applyConsent(model.enabledUsageProviders)
                                }
                            }))
                    }
                }
            }
            if let hidden = codex.status?.hiddenCount, hidden > 0 {
                Divider()
                Button(L10n.t(.codexUnhide, hidden)) { codex.unhideAll() }
                    .disabled(codex.isBusy)
            }
            Divider()
            Button(L10n.t(.suggestionFlushTitle), role: .destructive) {
                confirmingLearningFlush = true
            }
            .disabled(model.isDemo)
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
        .alert(L10n.t(.suggestionFlushTitle), isPresented: $confirmingLearningFlush) {
            Button(L10n.t(.uiCancel), role: .cancel) {}
            Button(L10n.t(.suggestionFlushConfirm), role: .destructive) {
                Task {
                    do {
                        try await usage.flushSuggestionLearningData()
                    } catch {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L10n.t(.suggestionFlushTitle)
                        alert.informativeText = L10n.t(.suggestionFlushFailure)
                        alert.runModal()
                    }
                }
            }
        } message: {
            Text(L10n.t(.suggestionFlushMessage))
        }
    }

    /// The single opt-in path used by the Settings toggle AND the inline Connect-usage
    /// buttons: confirm, then apply the effective saved consent set. Cancel is a no-op.
    static func enableUsageConnection(_ provider: UsageProvider, model: SwitcherModel,
                                      usage: UsageModel) {
        guard provider.requiresConsent, !model.enabledUsageProviders.contains(provider)
        else { return }
        confirmUsageConnection(provider) {
            model.setUsageConnection(provider, on: true)
            usage.applyConsent(model.enabledUsageProviders)
        }
    }

    /// Opt-in explanation for a consent-required provider. Each provider has its own text naming
    /// what is read, what is run, and the hosts requests go to.
    /// Turning off never asks. Returns via `enable` only on the explicit action.
    static func confirmUsageConnection(_ provider: UsageProvider, enable: () -> Void) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.uiConnectUsageTitle, UsageText.providerName(provider))
        alert.informativeText = provider.consentBodyKey.map { L10n.t($0) } ?? ""
        alert.addButton(withTitle: L10n.t(.uiConnectUsageEnable))
        alert.addButton(withTitle: L10n.t(.uiCancel))
        if alert.runModal() == .alertFirstButtonReturn { enable() }
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
