import SwiftUI
import SwitcherCore

// MARK: - Tabs

enum AppTab: String, CaseIterable {
    case usage, api, claude, codex
}

/// The selected tab, shared by the window and the menu. Remembered between launches, except for demo screens.
@MainActor
final class TabSelection: ObservableObject {
    /// The key changed for 2.0: the remembered tab moves to Usage for everyone on first launch.
    static let defaultsKey = "selectedTab.v2"
    private let remembers: Bool

    @Published var tab: AppTab {
        didSet { if remembers { UserDefaults.standard.set(tab.rawValue, forKey: Self.defaultsKey) } }
    }

    private let forced: AppTab?

    init(forced: AppTab? = nil) {
        self.forced = forced
        remembers = forced == nil
        tab = forced ?? AppTab(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .usage
    }

    /// Usage and API are always available; Claude and Codex appear when present.
    func visibleTabs(_ providers: Set<UsageProvider>) -> [AppTab] {
        var tabs: [AppTab] = [.usage, .api]
        if providers.contains(.claude) || forced == .claude { tabs.append(.claude) }
        if providers.contains(.codex) || forced == .codex { tabs.append(.codex) }
        return tabs
    }

    /// The tab to show: the selection, or Usage when it has no tab. The selection itself is left
    /// alone so a not-yet-loaded inventory never overwrites the remembered tab.
    func effectiveTab(_ providers: Set<UsageProvider>) -> AppTab {
        visibleTabs(providers).contains(tab) ? tab : .usage
    }

    /// Claude when installed or when it has accounts; Codex when installed or when it has a
    /// non-default home. Never Cursor — it has no management tab.
    static func providers(installations: [UsageInstallation], claudeAccounts: Int,
                          codexAccounts: [CodexAccount]) -> Set<UsageProvider> {
        var providers = Set(installations.map(\.provider)).subtracting([.cursor])
        if claudeAccounts > 0 { providers.insert(.claude) }
        // A phantom default home (standard, no identity) must not conjure a Codex tab.
        if codexAccounts.contains(where: { $0.kind != .standard || $0.identity != nil }) {
            providers.insert(.codex)
        }
        return providers
    }
}

struct TabSwitcher: View {
    @ObservedObject var selection: TabSelection
    let visibleProviders: Set<UsageProvider>

    var body: some View {
        let tabs = selection.visibleTabs(visibleProviders)
        if tabs.count == 1 {
            Text(L10n.t(.tabUsage)).font(.headline)
        } else {
            Picker(selection: Binding(get: { selection.effectiveTab(visibleProviders) },
                                      set: { selection.tab = $0 })) {
                ForEach(tabs, id: \.self) { tab in
                    Text(label(of: tab)).tag(tab)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func label(of tab: AppTab) -> String {
        switch tab {
        case .usage: return L10n.t(.tabUsage)
        case .api: return L10n.t(.tabAPI)
        case .claude: return L10n.t(.tabClaude)
        case .codex: return L10n.t(.tabCodex)
        }
    }
}

// MARK: - Rows

struct CodexRow: View {
    let account: CodexAccount
    let revealed: Bool
    let busy: Bool
    let onOpen: () -> Void
    let onSignIn: () -> Void
    let onToggleEmail: () -> Void
    let onRename: () -> Void
    let onCopyCommand: () -> Void
    let onReveal: () -> Void
    var onRemove: (() -> Void)? = nil
    var compact = false
    /// "Always show emails" is on: nothing to toggle.
    var alwaysRevealed = false
    /// Set when the guide pointed at this account — a subtle highlight only, no action.
    var focused = false
    @State private var hovering = false

    private var stateColor: Color {
        switch account.state {
        case .running: return Theme.active
        case .signedIn: return Theme.ready
        case .signedOut: return Theme.relogin
        }
    }

    private var stateText: String {
        switch account.state {
        case .running: return L10n.t(.codexStateRunning)
        case .signedIn: return L10n.t(.codexStateSignedIn)
        case .signedOut: return L10n.t(.codexStateSignedOut)
        }
    }

    private var title: String { revealed ? account.label : SwitcherModel.displayName(account.label) }
    private var titleIsMasked: Bool { SwitcherModel.displayName(account.label) != account.label }

    @ViewBuilder
    private func titleView(font: Font) -> some View {
        let text = Text(title).font(font).foregroundStyle(Theme.ink).lineLimit(compact ? 2 : 1).truncationMode(.middle)
        if titleIsMasked && !alwaysRevealed {
            Button(action: onToggleEmail) { text }
                .buttonStyle(.plain)
                .help(revealed ? L10n.t(.uiEmailHide) : L10n.t(.uiEmailShow))
        } else {
            text
        }
    }

    /// The home path lives behind Info so the title stays uncluttered — selectable in
    /// the popover, and opening it never reveals a masked email.
    @State private var showInfo = false

    private var infoButton: some View {
        Button { showInfo.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t(.uiAccountDetails))
        .popover(isPresented: $showInfo, arrowEdge: .top) {
            Text(alwaysRevealed ? account.homePath : Privacy.maskEmails(in: account.homePath))
                .font(Theme.mono).foregroundStyle(Theme.inkMuted)
                .textSelection(.enabled).padding(10)
        }
    }

    /// Chips hold only what must stay on one line: the readable state (fixed so a long
    /// locale never starves it) and the App source marker. Billing moves to its own line.
    private var chips: some View {
        HStack(spacing: 6) {
            Chip(text: stateText, color: stateColor, filled: account.state == .running)
                .layoutPriority(1).fixedSize()
            Text(L10n.t(.usageEnvApp)).font(.system(size: 10)).foregroundStyle(Theme.inkMuted).fixedSize()
        }
    }

    /// Billing never competes for chip-row width: nil/unknown identity shows nothing,
    /// API keys are billed separately, subscriptions name their plan when one exists.
    private var billingText: String? {
        switch account.identity?.mode {
        case .apiKey:
            return L10n.t(.usageAuthApi)
        case .chatgpt:
            guard let plan = account.identity?.plan, !plan.isEmpty else {
                return L10n.t(.usageAuthSubscription)
            }
            return L10n.t(.usageAuthSubscription) + " · " + plan.capitalized
        case .unknown, .none:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gapRow) {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                if compact {
                    titleView(font: Theme.rowTitle).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) { chips; infoButton }
                } else {
                    HStack(spacing: 8) {
                        titleView(font: Theme.rowTitle)
                        Button(action: onRename) {
                            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .opacity(hovering ? 1 : 0)
                        .help(L10n.t(.uiRename))
                        .accessibilityLabel(L10n.t(.uiRename))
                        chips
                        infoButton
                    }
                }
                if let billingText {
                    Text(billingText).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let email = account.email, email != account.label {
                    if alwaysRevealed {
                        Text(email).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    } else {
                        Button(action: onToggleEmail) {
                            Text(revealed ? email : Privacy.maskEmail(email)).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .help(revealed ? L10n.t(.uiEmailHide) : L10n.t(.uiEmailShow))
                    }
                }

            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 8 : 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard - 4, style: .continuous)
                .fill(account.state == .running || focused
                    ? Theme.active.opacity(0.10) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.t(.uiRename), action: onRename).disabled(busy)
            Button(L10n.t(.codexReauth), action: onSignIn).disabled(busy)
            Divider()
            Button(L10n.t(.codexCopyCommand), action: onCopyCommand)
            Button(L10n.t(.codexRevealInFinder), action: onReveal)
            if let onRemove {
                Divider()
                Button(account.kind == .managed ? L10n.t(.codexRemove) : L10n.t(.codexHide), role: .destructive, action: onRemove)
                    .disabled(busy)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        switch account.state {
        case .running:
            Button(L10n.t(.codexShow), action: onOpen)
                .buttonStyle(ActionButtonStyle(tint: Theme.active, prominent: false))
                .disabled(busy)
                .help(L10n.t(.codexOpenHelp))
        case .signedIn:
            Button(L10n.t(.codexOpen), action: onOpen)
                .buttonStyle(ActionButtonStyle(tint: Theme.active))
                .disabled(busy)
                .help(L10n.t(.codexOpenHelp))
        case .signedOut:
            Button(L10n.t(.codexSignIn), action: onSignIn)
                .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
                .disabled(busy)
        }
    }
}

extension CodexRow {
    init(account: CodexAccount, model: CodexModel, alwaysReveal: Bool, compact: Bool = false,
         focused: Bool = false) {
        self.init(account: account, revealed: alwaysReveal || model.revealedEmails.contains(account.id), busy: model.isBusy,
                  onOpen: { model.open(account) }, onSignIn: { model.requestReauth(account) },
                  onToggleEmail: { model.toggleEmail(account.id) }, onRename: { model.requestRename(account) },
                  onCopyCommand: { model.copyCommand(account) }, onReveal: { model.revealInFinder(account) },
                  onRemove: account.kind == .standard ? nil : { model.requestRemove(account) }, compact: compact,
                  alwaysRevealed: alwaysReveal, focused: focused)
    }
}

/// A Codex home found on this Mac that isn't in the list: it can be added or hidden, never opened from here.
struct CodexFoundRow: View {
    let found: CodexAccount
    @ObservedObject var model: CodexModel
    var alwaysRevealed = false

    var body: some View {
        HStack(spacing: Theme.gapRow) {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                Text(alwaysRevealed ? found.label : SwitcherModel.displayName(found.label))
                    .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(found.homePath).font(Theme.mono).foregroundStyle(Theme.inkMuted.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(L10n.t(.codexDismiss)) { model.dismiss(found) }
                .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                .disabled(model.isBusy)
            Button(L10n.t(.codexAdopt)) { model.requestAdopt(found) }
                .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard - 4, style: .continuous)
            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - Header and progress

struct CodexHeader: View {
    let status: CodexStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            Text(L10n.t(.codexHeaderTitle)).font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
            if status.installed {
                Text(L10n.t(.codexRunningCount, status.runningCount))
                    .font(compact ? .system(size: 16, weight: .semibold) : Theme.display)
                    .foregroundStyle(status.runningCount > 0 ? Theme.active : Theme.ink)
                if !compact, let version = status.version {
                    Label("Codex v\(version)", systemImage: "shippingbox").font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
            } else {
                Text(L10n.t(.errCodexNotInstalled)).font(Theme.body).foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodexSignInProgress: View {
    @ObservedObject var model: CodexModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { label; Spacer(minLength: 8); buttons }
            VStack(alignment: .leading, spacing: 8) { label; HStack(spacing: 8) { buttons } }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.alias.opacity(0.09)))
    }

    private var label: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.t(.codexSigningIn)).font(Theme.body).foregroundStyle(Theme.ink)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if model.signInLink != nil {
            Button(L10n.t(.codexOpenLinkAgain)) { model.openSignInLink() }
                .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
        }
        Button(L10n.t(.uiCancel)) { model.cancelSignIn() }
            .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
    }
}

// MARK: - Window and menu content

struct CodexMainContent: View {
    @ObservedObject var model: CodexModel
    @ObservedObject var settings: SwitcherModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scrolls to the account the guide pointed at — only when it still exists in the list.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = model.focusedAccountID,
              model.status?.accounts.contains(where: { $0.id == id }) == true else { return }
        let jump = {
            if reduceMotion { proxy.scrollTo(id, anchor: .center) }
            else { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        jump()
        DispatchQueue.main.async { jump() }
    }

    var body: some View {
        if let status = model.status {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    CodexHeader(status: status)
                    VStack(alignment: .trailing, spacing: 6) {
                        if model.isDemo { Chip(text: L10n.t(.uiDemo), color: Theme.alias, filled: true) }
                        Button { model.refresh() } label: { Label(L10n.t(.uiRefresh), systemImage: "arrow.clockwise") }
                            .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(model.isBusy)
                    }
                }
                .padding(Theme.gapGroup)
                .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.surface))
                .padding([.horizontal, .top], Theme.gapGroup)

                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.gapGroup) {
                        if case .signingIn = model.phase { CodexSignInProgress(model: model) }
                        if let banner = model.banner { BannerView(banner: banner) }
                        if status.registryUnreadable {
                            BannerView(banner: SwitcherModel.Banner(kind: .error, text: L10n.t(.codexRegistryUnreadable)))
                        }
                        VStack(alignment: .leading, spacing: Theme.gapRow) {
                            Text(L10n.t(.uiAccounts)).font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
                            ForEach(status.accounts) { account in
                                CodexRow(account: account, model: model, alwaysReveal: settings.showEmails,
                                         focused: model.focusedAccountID == account.id)
                                    .id(account.id)
                            }
                        }
                        if !status.found.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.gapRow) {
                                Text(L10n.t(.codexFoundTitle)).font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
                                Text(L10n.t(.codexFoundHint)).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                                ForEach(status.found) { found in
                                    CodexFoundRow(found: found, model: model, alwaysRevealed: settings.showEmails)
                                }
                            }
                        }
                    }
                    .padding(Theme.gapGroup)
                }
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: model.focusedAccountID) { _, _ in scrollToFocus(proxy) }
                }

                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button(L10n.t(.codexAdd)) { model.add() }
                            .buttonStyle(ActionButtonStyle(tint: Theme.alias))
                            .disabled(model.isBusy || !status.installed)
                            .help(L10n.t(.codexAddHelp))
                        Spacer()
                    }
                }
                .padding(.horizontal, Theme.gapGroup)
                .padding(.vertical, 12)
                .background(Theme.surface.opacity(0.6))
            }
        } else {
            ProgressView(L10n.t(.uiLoading)).foregroundStyle(Theme.inkMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CodexMenuContent: View {
    @ObservedObject var model: CodexModel
    @ObservedObject var settings: SwitcherModel

    var body: some View {
        if let status = model.status {
            CodexHeader(status: status, compact: true).padding(.bottom, 4)
            ForEach(status.accounts) { account in
                CodexRow(account: account, model: model, alwaysReveal: settings.showEmails, compact: true,
                            focused: model.focusedAccountID == account.id)
                    .id(account.id)
            }
            if case .signingIn = model.phase { CodexSignInProgress(model: model) }
            if let banner = model.banner { BannerView(banner: banner) }
            HStack(spacing: 8) {
                Button(L10n.t(.codexAdd)) { model.add() }
                    .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
                    .disabled(model.isBusy || !status.installed)
                    .help(L10n.t(.codexAddHelp))
                if !status.found.isEmpty {
                    // Adding a found home needs the explanation in the window.
                    Button(L10n.t(.codexFoundCount, status.found.count)) { AppDelegate.shared?.showMainWindow() }
                        .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                }
            }
        } else {
            ProgressView()
        }
    }
}

// MARK: - Dialogs

struct CodexAlertsModifier: ViewModifier {
    @ObservedObject var model: CodexModel

    func body(content: Content) -> some View {
        content
            .alert(
                Privacy.maskEmails(in: model.pending?.title ?? ""),
                isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } }),
                presenting: model.pending
            ) { action in
                switch action.kind {
                case .adopt: Button(L10n.t(.codexAdopt)) { model.confirm(action) }
                case .remove: Button(L10n.t(.codexRemoveButton), role: .destructive) { model.confirm(action) }
                case .hide: Button(L10n.t(.codexHideButton), role: .destructive) { model.confirm(action) }
                case .reauth: Button(L10n.t(.codexReauthButton)) { model.confirm(action) }
                }
                Button(L10n.t(.uiCancel), role: .cancel) { model.pending = nil }
                    .keyboardShortcut(.defaultAction)
            } message: { action in
                Text(Privacy.maskEmails(in: action.detail))
            }
            .alert(
                L10n.t(.uiRenameTitle),
                isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } }),
                presenting: model.renaming
            ) { account in
                TextField(Privacy.maskEmails(in: account.defaultName), text: $model.renameDraft)
                Button(L10n.t(.uiSave)) { model.rename(account, to: model.renameDraft) }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.t(.uiCancel), role: .cancel) { model.renaming = nil }
            } message: { account in
                Text(L10n.t(.uiRenameMessage, Privacy.maskEmails(in: account.defaultName)))
            }
    }
}
