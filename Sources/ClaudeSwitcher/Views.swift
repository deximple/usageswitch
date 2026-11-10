import SwiftUI
import SwitcherCore

struct AccountRow: View {
    let account: AccountStatus
    let revealed: Bool
    let busy: Bool
    let onSwitch: () -> Void
    let onEnroll: () -> Void
    let onToggleEmail: () -> Void
    var onRename: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var compact = false
    /// "Always show emails" is on: nothing to toggle.
    var alwaysRevealed = false
    @State private var hovering = false

    private var stateColor: Color { Theme.color(for: account.snapshot, active: account.isActive) }

    /// Named only by an id prefix: the rename button stays visible until it gets a name.
    private var needsName: Bool { SwitcherModel.needsName(account) }

    /// The name hides an email address: clicking it shows or hides it (like the email line).
    private var titleIsMasked: Bool { SwitcherModel.displayLabel(account) != account.label }

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

    /// Accounts without a custom name are named by their email, so the title follows the email's masking.
    private var title: String { revealed ? account.label : SwitcherModel.displayLabel(account) }

    private var chips: some View {
        HStack(spacing: 6) {
            Chip(text: Theme.label(for: account.snapshot, active: account.isActive), color: stateColor, filled: account.isActive)
            Text(L10n.t(.usageEnvApp)).font(.system(size: 10)).foregroundStyle(Theme.inkMuted).fixedSize()
        }
    }

    /// The account UUID lives behind Info so the row stays a single title line; the popover
    /// keeps it selectable and never reveals a masked email.
    private var infoButton: some View {
        Button { showInfo.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t(.uiAccountDetails))
        .popover(isPresented: $showInfo, arrowEdge: .top) {
            Text(alwaysRevealed ? account.accountUuid : Privacy.maskEmails(in: account.accountUuid))
                .font(Theme.mono).foregroundStyle(Theme.inkMuted)
                .textSelection(.enabled).padding(10)
        }
    }
    @State private var showInfo = false

    /// Shown on hover next to the name, so renaming is discoverable without the context menu.
    @ViewBuilder
    private var renameButton: some View {
        if let onRename {
            Button(action: onRename) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(hovering || needsName ? 1 : 0)
            .help(L10n.t(.uiRename))
            .accessibilityLabel(L10n.t(.uiRename))
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
                        renameButton
                        chips
                        infoButton
                    }
                }
                if let email = account.email {
                    if alwaysRevealed {
                        Text(email).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    } else {
                        Button(action: onToggleEmail) {
                            Text(revealed ? email : Privacy.maskEmail(email))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .help(revealed ? L10n.t(.uiEmailHide) : L10n.t(.uiEmailShow))
                        .accessibilityLabel(revealed ? L10n.t(.uiEmailAxRevealed, email) : L10n.t(.uiEmailAxMasked))
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
                .fill(account.isActive ? Theme.active.opacity(0.10) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            if let onRename {
                Button(L10n.t(.uiRename), action: onRename).disabled(busy)
            }
            if !account.isActive {
                Button(L10n.t(.uiReloginMenu), action: onEnroll).disabled(busy)
            }
            if let onRemove, !account.isActive {
                Divider()
                Button(L10n.t(.uiRemoveSaved), role: .destructive, action: onRemove).disabled(busy)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailing: some View {
        if account.isActive {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.active)
                .accessibilityLabel(L10n.t(.uiCurrentInUseAx))
        } else {
            switch account.snapshot {
            case .ready:
                Button(L10n.t(.uiSwitch), action: onSwitch)
                    .buttonStyle(ActionButtonStyle(tint: Theme.active))
                    .disabled(busy)
                    .accessibilityLabel(L10n.t(.uiSwitchAx, SwitcherModel.displayLabel(account)))
                    .help(L10n.t(.uiSwitchHelp))
            case .expired, .corrupt:
                Button(L10n.t(.uiRelogin), action: onEnroll)
                    .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
                    .disabled(busy)
                    .accessibilityLabel(L10n.t(.uiEnrollAx, SwitcherModel.displayLabel(account)))
                    .help(L10n.t(.uiEnrollHelp))
            }
        }
    }
}

struct ActiveHeader: View {
    let status: SwitcherStatus
    var revealed = false
    var onToggleEmail: () -> Void = {}
    var compact = false
    var alwaysRevealed = false

    @ViewBuilder
    private func email(_ email: String) -> some View {
        if alwaysRevealed {
            Text(email)
        } else {
            Button(action: onToggleEmail) {
                Text(revealed ? email : Privacy.maskEmail(email))
            }
            .buttonStyle(.plain)
            .help(revealed ? L10n.t(.uiEmailHide) : L10n.t(.uiEmailShow))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            Text(L10n.t(.uiHeaderTitle))
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.inkMuted)
            if let active = status.activeAccount {
                Text(status.accounts.filter(\.isActive)
                    .map { revealed ? $0.label : SwitcherModel.displayLabel($0) }.joined(separator: " · "))
                    .font(compact ? .system(size: 16, weight: .semibold) : Theme.display)
                    .foregroundStyle(Theme.active)
                    .lineLimit(1).truncationMode(.middle)
                if let address = active.email {
                    email(address)
                        .font(Theme.body)
                        .foregroundStyle(Theme.ink)
                }
            } else if let address = status.claude.activeEmail {
                email(address)
                    .font(compact ? .system(size: 16, weight: .semibold) : Theme.display)
                    .foregroundStyle(Theme.ink)
            } else if status.claude.activeAccountUuid != nil {
                Text(L10n.t(.uiHeaderNotInList))
                    .font(compact ? .system(size: 16, weight: .semibold) : Theme.display)
                    .foregroundStyle(Theme.ink)
            } else {
                Text(status.claude.running ? L10n.t(.uiHeaderSignedOut) : L10n.t(.uiHeaderClaudeOff))
                    .font(compact ? .system(size: 16, weight: .semibold) : Theme.display)
                    .foregroundStyle(Theme.inkMuted)
            }
            if !compact {
                HStack(spacing: 14) {
                    Label(status.claude.running ? L10n.t(.uiRunning) : L10n.t(.uiOff), systemImage: status.claude.running ? "circle.fill" : "circle")
                        .foregroundStyle(status.claude.running ? Theme.ready : Theme.missing)
                    Label(L10n.t(.uiCodeSessions, status.claude.codeSessions), systemImage: "terminal")
                    if let v = status.claude.version { Label("v\(v)", systemImage: "shippingbox") }
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StepsView: View {
    let steps: [SwitchStep]
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let isLast = index == steps.count - 1
                HStack(spacing: 8) {
                    if isLast && working {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: step == .rollingBack ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(step == .rollingBack ? Theme.relogin : Theme.ready)
                            .frame(width: 14)
                    }
                    Text(step.title)
                        .font(Theme.caption)
                        .foregroundStyle(isLast && working ? Theme.ink : Theme.inkMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t(.uiStepsAx, steps.map(\.title).joined(separator: ", ")))
    }
}

struct BannerView: View {
    let banner: SwitcherModel.Banner

    var body: some View {
        let color: Color = banner.kind == .error ? Theme.danger : banner.kind == .success ? Theme.ready : Theme.alias
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : banner.kind == .success ? "checkmark.seal.fill" : "info.circle.fill")
                .foregroundStyle(color)
            Text(Privacy.maskEmails(in: banner.text))
                .font(Theme.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

struct ConfirmationModifier: ViewModifier {
    @ObservedObject var model: SwitcherModel

    func body(content: Content) -> some View {
        content.alert(
            Privacy.maskEmails(in: model.pendingConfirmation?.title ?? ""),
            isPresented: Binding(get: { model.pendingConfirmation != nil }, set: { if !$0 { model.pendingConfirmation = nil } }),
            presenting: model.pendingConfirmation
        ) { action in
            if action.fromURL {
                // Requested from a link: Return/Escape cancel; only an explicit click proceeds.
                Button(L10n.t(.uiContinue)) { model.confirm(action) }
                Button(L10n.t(.uiCancel), role: .cancel) { model.pendingConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } else if case .remove = action.kind {
                Button(L10n.t(.uiRemoveSaved), role: .destructive) { model.confirm(action) }
                Button(L10n.t(.uiCancel), role: .cancel) { model.pendingConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(action.kind == .enroll ? L10n.t(.uiOpenLogin) : L10n.t(.uiContinue)) { model.confirm(action) }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.t(.uiCancel), role: .cancel) { model.pendingConfirmation = nil }
            }
        } message: { action in
            Text(confirmationText(action))
        }
    }

    private func confirmationText(_ action: SwitcherModel.PendingAction) -> String {
        if case .remove = action.kind { return Privacy.maskEmails(in: action.detail) }
        var parts = action.fromURL ? [L10n.t(.uiConfirmFromURL), L10n.t(.uiConfirmRestart)] : [L10n.t(.uiConfirmRestart)]
        if action.codeSessions > 0 { parts.append(L10n.t(.uiConfirmSessions, action.codeSessions)) }
        if action.kind == .enroll { parts.append(L10n.t(.uiConfirmEnroll)) }
        return parts.joined(separator: "\n\n")
    }
}

struct MainView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var tabs: TabSelection

    private var providers: Set<UsageProvider> {
        if usage.isDemo { return Set(usage.installations.map { $0.provider }) }
        return TabSelection.providers(installations: usage.installations,
                                      claudeAccounts: model.status?.accounts.count ?? 0,
                                      codexAccounts: codex.status?.accounts ?? [])
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                TabSwitcher(selection: tabs, visibleProviders: providers)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { SettingsMenu(model: model, codex: codex, usage: usage).padding(.trailing, Theme.gapGroup) }
                    .padding(.top, 14)
                    .modifier(NavChrome())
                switch tabs.effectiveTab(providers) {
                case .usage:
                    VStack(spacing: 0) {
                        UsageListHeader(model: usage, settings: model)
                            .frame(maxWidth: 712)
                            .frame(maxWidth: .infinity)
                            .padding([.horizontal, .top], Theme.gapGroup)
                        ScrollView {
                            UsageContent(model: usage, settings: model, codex: codex, tabs: tabs)
                                .frame(maxWidth: 712, alignment: .top)
                                .frame(maxWidth: .infinity)
                                .padding([.horizontal, .bottom], Theme.gapGroup)
                        }
                        UsageFooter(model: usage)
                            .padding(.horizontal, Theme.gapGroup)
                            .padding(.bottom, 12)
                    }
                case .api:
                    APIContent(usage: usage, settings: model)
                case .claude:
                    if let status = model.status {
                        content(status)
                    } else {
                        ProgressView(L10n.t(.uiLoading)).foregroundStyle(Theme.inkMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .codex:
                    CodexMainContent(model: codex, settings: model)
                }
            }
        }
        .frame(minWidth: 660, idealWidth: 700, minHeight: 640, idealHeight: 760)
        .modifier(ConfirmationModifier(model: model))
        .modifier(RenameModifier(model: model))
        .modifier(CodexAlertsModifier(model: codex))
    }

    @ViewBuilder
    private func content(_ status: SwitcherStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                ActiveHeader(status: status, revealed: model.isRevealed(SwitcherModel.headerEmailID),
                             onToggleEmail: { model.toggleEmail(SwitcherModel.headerEmailID) }, alwaysRevealed: model.showEmails)
                VStack(alignment: .trailing, spacing: 6) {
                    if model.isDemo { Chip(text: L10n.t(.uiDemo), color: Theme.alias, filled: true) }
                    Button { model.refresh() } label: { Label(L10n.t(.uiRefresh), systemImage: "arrow.clockwise") }
                        .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(model.isBusy)
                }
            }
            .padding(Theme.gapGroup)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.surface)
                .shadow(color: .black.opacity(0.06), radius: 14, y: 6))
            .padding([.horizontal, .top], Theme.gapGroup)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gapGroup) {
                    // Results and progress first: with many accounts they would scroll out of view below the list.
                    if !model.steps.isEmpty || model.banner != nil || !status.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.gapRow) {
                            if let banner = model.banner { BannerView(banner: banner) }
                            ForEach(status.warnings, id: \.self) { BannerView(banner: .init(kind: .info, text: $0)) }
                            if status.journalUnreadable {
                                Button(L10n.t(.uiSetAsideJournal)) {
                                    let alert = NSAlert()
                                    alert.messageText = L10n.t(.uiSetAsideJournalTitle)
                                    alert.informativeText = L10n.t(.uiSetAsideJournalBody)
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: L10n.t(.uiCancel)) // first = default (Cancel)
                                    alert.addButton(withTitle: L10n.t(.uiSetAsideJournal))
                                    if alert.runModal() == .alertSecondButtonReturn {
                                        model.setAsidePendingJournal()
                                    }
                                }
                                .font(Theme.caption)
                            }
                            if !model.steps.isEmpty { StepsView(steps: model.steps, working: model.isBusy) }
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.gapRow) {
                        Text(L10n.t(.uiAccounts))
                            .font(Theme.eyebrow)
                            .foregroundStyle(Theme.inkMuted)
                        if status.accounts.isEmpty {
                            Text(L10n.t(.uiNoAccounts))
                                .font(Theme.body)
                                .foregroundStyle(Theme.inkMuted)
                                .padding(.vertical, 8)
                        }
                        ForEach(status.accounts) { account in
                            AccountRow(account: account, revealed: model.isRevealed(account.id), busy: model.isBusy,
                                       onSwitch: { model.requestSwitch(account) }, onEnroll: { model.requestEnroll() },
                                       onToggleEmail: { model.toggleEmail(account.id) },
                                       onRename: { model.requestRename(account) },
                                       onRemove: { model.requestRemove(account) }, alwaysRevealed: model.showEmails)
                        }
                    }
                }
                .padding(Theme.gapGroup)
            }

            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(L10n.t(.uiCapture)) { model.requestCapture() }
                        .buttonStyle(ActionButtonStyle(tint: Theme.ready, prominent: model.phase == .awaitingLogin))
                        .disabled(model.isBusy || !status.claude.running)
                        .help(L10n.t(.uiCaptureHelp))
                    Button(L10n.t(.uiNewLogin)) { model.requestEnroll() }
                        .buttonStyle(ActionButtonStyle(tint: Theme.alias, prominent: false))
                        .disabled(model.isBusy)
                        .help(L10n.t(.uiNewLoginHelp))
                    Spacer()
                    if let backup = status.originalBackup {
                        Text(L10n.t(.uiBackupOK)).font(Theme.caption).foregroundStyle(Theme.inkMuted).help(backup)
                    }
                    if !status.relaunchers.isEmpty {
                        Text(L10n.t(.uiRelaunchers, status.relaunchers.joined(separator: ", ")))
                            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.middle)
                            .help(L10n.t(.uiRelaunchersHelp))
                    }
                }
            }
            .padding(.horizontal, Theme.gapGroup)
            .padding(.vertical, 12)
            .background(Theme.surface.opacity(0.6))
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var tabs: TabSelection
    /// Measured heights: the scrolling body shares one 600-pt panel budget with the fixed
    /// top (navigation + segment picker) and bottom (usage footer + controls) chrome, so the
    /// complete menu can never push controls off the screen under the pointer.
    @State private var bodyHeight: CGFloat = 120
    @State private var chromeTop: CGFloat = 60
    @State private var chromeHeight: CGFloat = 140
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The menu panel counts as a visible surface for the status-poll cadence (audit P3).
    private func notePanelVisible(_ visible: Bool) { AppModel.noteSurface(open: visible) }

    private var panelCap: CGFloat {
        let mouse = NSEvent.mouseLocation
        // `--snapshot-height` lifts the panel budget so README renders can show
        // the full list; the menu keeps its own chrome-aware fitting.
        if let height = LaunchOptions.snapshotHeight { return height }
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return min(600, (screen?.visibleFrame.height ?? 600) - 80)
    }

    private var providers: Set<UsageProvider> {
        if usage.isDemo { return Set(usage.installations.map { $0.provider }) }
        return TabSelection.providers(installations: usage.installations,
                                      claudeAccounts: model.status?.accounts.count ?? 0,
                                      codexAccounts: codex.status?.accounts ?? [])
    }

    /// Scroll to the account the guide pointed at, once its tab has actually laid out —
    /// the id may not exist in the ScrollView until after the tab switch renders.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = codex.focusedAccountID, tabs.effectiveTab(providers) == .codex,
              codex.status?.accounts.contains(where: { $0.id == id }) == true else { return }
        let jump = {
            if reduceMotion { proxy.scrollTo(id, anchor: .center) }
            else { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        jump()
        DispatchQueue.main.async { jump() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapRow) {
            VStack(alignment: .leading, spacing: Theme.gapRow) {
                TabSwitcher(selection: tabs, visibleProviders: providers).frame(maxWidth: .infinity)
                if tabs.effectiveTab(providers) == .usage {
                    UsageListHeader(model: usage, settings: model)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chromeTop = $0 }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.gapRow) {
                        switch tabs.effectiveTab(providers) {
                        case .usage: UsageContent(model: usage, settings: model, codex: codex, tabs: tabs, compact: true)
                        case .api: APIContent(usage: usage, settings: model, compact: true)
                        case .claude: claudeContent
                        case .codex: CodexMenuContent(model: codex, settings: model)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
                }
                // -48: outer .padding(14) and the two inter-section spacings aren't measured.
                .frame(height: max(0, min(bodyHeight, panelCap - chromeTop - chromeHeight - 48)))
                .scrollIndicators(.automatic)
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: codex.focusedAccountID) { _, _ in scrollToFocus(proxy) }
                .onChange(of: tabs.tab) { _, _ in scrollToFocus(proxy) }
            }
            VStack(alignment: .leading, spacing: Theme.gapRow) {
                if tabs.effectiveTab(providers) == .usage { UsageFooter(model: usage) }
                Divider().overlay(Theme.hairline)
                HStack {
                    Button(L10n.t(.uiOpenWindow)) { AppDelegate.shared?.showMainWindow() }
                        .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                    Spacer()
                    SettingsMenu(model: model, codex: codex, usage: usage)
                    Button(L10n.t(.uiQuit)) { NSApp.terminate(nil) }
                        .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
                        .keyboardShortcut("q")
                        .disabled(model.isBusy)
                        .help(model.isBusy ? L10n.t(.uiQuitHelpBusy) : L10n.t(.uiQuitHelp, ProductInfo.name))
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chromeHeight = $0 }
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.canvas)
        .modifier(ConfirmationModifier(model: model))
        .modifier(RenameModifier(model: model))
        .modifier(CodexAlertsModifier(model: codex))
        .onAppear { notePanelVisible(true) }
        .onDisappear { notePanelVisible(false) }
    }

    @ViewBuilder
    private var claudeContent: some View {
            if let status = model.status {
                ActiveHeader(status: status, revealed: model.isRevealed(SwitcherModel.headerEmailID),
                             onToggleEmail: { model.toggleEmail(SwitcherModel.headerEmailID) }, compact: true,
                             alwaysRevealed: model.showEmails)
                    .padding(.bottom, 4)
                if status.accounts.isEmpty {
                    Text(L10n.t(.uiNoAccounts)).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
                ForEach(status.accounts) { account in
                    AccountRow(account: account, revealed: model.isRevealed(account.id), busy: model.isBusy,
                               onSwitch: { model.requestSwitch(account) }, onEnroll: { model.requestEnroll() },
                               onToggleEmail: { model.toggleEmail(account.id) },
                               onRename: { model.requestRename(account) },
                               onRemove: { model.requestRemove(account) }, compact: true, alwaysRevealed: model.showEmails)
                }
                if !model.steps.isEmpty && model.isBusy, let last = model.steps.last {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(last.title).font(Theme.caption).foregroundStyle(Theme.ink)
                    }
                }
                if let banner = model.banner { BannerView(banner: banner) }
            } else {
                ProgressView()
            }
    }
}

/// Name editor: empty means "use the default name" (shown in the message and as the field's placeholder).
struct RenameModifier: ViewModifier {
    @ObservedObject var model: SwitcherModel

    func body(content: Content) -> some View {
        content
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


/// Restrained chrome for the main navigation strip only: native glass on macOS 26+ unless the
/// user asked for reduced transparency, a material rounded rect everywhere else. Rows, bars and
/// cards deliberately stay un-glassed.
private struct NavChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.canvas))
        } else if #available(macOS 26.0, *) {
            content
                .padding(6)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            content
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial))
        }
    }
}
