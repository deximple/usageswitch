import AppKit
import SwiftUI
import SwitcherCore

/// Read-only usage detail for one presentation id: full quota bars/resets,
/// honest state/source/version, API billing note, name editing for claude/codex
/// owners. Resolves the CURRENT presentation on every render — a removed account
/// shows unavailable, never a dangling editable row.
struct UsageDetailView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var usage: UsageModel
    @ObservedObject var codex: CodexModel
    let id: String
    let onClose: () -> Void
    @State private var draft: UsageNameDraft?
    @State private var editing = false
    @State private var saveError: String?
    @State private var busy = false
    @State private var copiedHint = false

    private var presentation: UsageAccountPresentation? {
        usage.presentations(claude: model.status, codex: codex.status, now: Date())
            .first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = presentation { content(for: p) }
                    else {
                        Text(L10n.t(.usageUnavailable)).font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                if editing, let d = draft, let owner = presentation?.owner {
                    Button(L10n.t(.usageDefaultName)) { draft?.restoreDefault() }
                        .disabled(busy || !d.canRestore)
                    Spacer()
                    Button(L10n.t(.uiCancel)) {
                        editing = false; draft = nil; saveError = nil
                    }.disabled(busy).keyboardShortcut(.cancelAction)
                    Button(L10n.t(.uiSave)) { save(owner, d) }
                        .disabled(busy || model.isBusy || codex.isBusy || !d.canSave)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button(L10n.t(.uiClose)) { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    @ViewBuilder private func content(for p: UsageAccountPresentation) -> some View {
        Text(displayedName(p)).font(.system(size: 15, weight: .semibold))
        if let email = p.email {
            Text(model.showEmails ? email : Privacy.maskEmails(in: email))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        let savedApp = p.usage.provider == .claude && p.usage.accountRef.hasPrefix("app:")
        if savedApp {
            if !model.isDemo, let accountID = savedClaudeAccountID(p),
               let account = model.status?.accounts.first(where: { $0.id == accountID }) {
                if let binding = model.claudeUsageProfiles.first(where: { $0.accountId == account.id }) {
                    Text(L10n.t(.uiClaudeProfilePath,
                                NSString(string: binding.profilePath).abbreviatingWithTildeInPath))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L10n.t(.uiClaudeProfileDisconnect)) { disconnectProfile(account.id) }
                        .font(.system(size: 12)).foregroundStyle(Theme.active)
                    if p.usage.state == .unavailable(.noSignIn) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t(.usageProfileSignInTitle))
                                .font(.system(size: 12, weight: .medium))
                            Text(L10n.t(.usageProfileSignInBody))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(ClaudeProfileSignInHint.command(profilePath: binding.profilePath))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button(copiedHint ? L10n.t(.usageProfileSignInCopied)
                                              : L10n.t(.usageProfileSignInCopy)) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    ClaudeProfileSignInHint.command(profilePath: binding.profilePath),
                                    forType: .string)
                                copiedHint = true
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.active)
                            .accessibilityLabel(Text("\(displayedName(p)), \(L10n.t(.usageProfileSignInCopy))"))
                        }
                    }
                } else {
                    Button(L10n.t(.uiClaudeProfileConnect)) { connectProfile(for: account) }
                        .font(.system(size: 12)).foregroundStyle(Theme.active)
                        .accessibilityLabel(Text("\(displayedName(p)), \(L10n.t(.uiClaudeProfileConnect))"))
                }
            } else {
                Text(L10n.t(.usageNotLinked)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let reason = UsageText.reason(for: p.usage) {
                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if UsageCollection.canConnect(p.usage, enabledProviders: model.enabledUsageProviders) {
            Text(L10n.t(.usageConnectionHelp)).font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(L10n.t(.uiConnectUsage)) {
                SettingsMenu.enableUsageConnection(p.usage.provider, model: model, usage: usage)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.active)
            .accessibilityLabel(Text("\(UsageText.providerName(p.usage.provider)), \(displayedName(p)), \(L10n.t(.uiConnectUsage))"))
        } else if let reason = UsageText.reason(for: p.usage) {
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(p.usage.windows, id: \.self) { w in
            UsageBarRow(usage: p.usage, window: w, settings: model, now: Date(),
                        compact: false,
                        pace: usage.pace[UsagePriority.key(p.usage, w)])
        }
        if p.usage.windows.isEmpty && !savedApp
            && !UsageCollection.canConnect(p.usage, enabledProviders: model.enabledUsageProviders) {
            Text(L10n.t(.usageNoData)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let resets = UsageText.resetCredits(p.usage.resetCredits, now: Date()) {
            Label(resets, systemImage: "ticket").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if p.usage.provider == .cursor,
           let destination = URL(string: "https://cursor.com/dashboard/spending") {
            Text(L10n.t(.usageCursorDashboardNote)).font(.system(size: 11))
                .foregroundStyle(.secondary)
            Link(L10n.t(.uiCursorDashboard), destination: destination)
                .font(.system(size: 12))
                .accessibilityLabel(Text("\(UsageText.providerName(p.usage.provider)), \(displayedName(p)), \(L10n.t(.uiCursorDashboard))"))
        }
        if p.usage.authentication == .apiKey {
            Text(L10n.t(.usageApiBillingNote)).font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if let v = p.usage.toolVersion {
            Text(v).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        LabeledContent(L10n.t(.usageSourceLabel)) {
            Text(sourceDescription(p)).foregroundStyle(.secondary)
        }.font(.system(size: 11))
        editor(for: p)
    }

    private func sourceDescription(_ p: UsageAccountPresentation) -> String {
        if !usage.usages.contains(where: { $0.id == p.id }) {
            return L10n.t(.usageSavedSource, UsageText.providerName(p.usage.provider))
        }
        switch p.usage.provider {
        case .claude:
            return p.usage.accountRef.hasPrefix("app:")
                ? L10n.t(.usageClaudeProfileSource) : "Claude CLI /usage"
        case .codex: return "Codex app-server"
        default: return "HTTPS · \(UsageText.providerName(p.usage.provider))"
        }
    }

    private func savedClaudeAccountID(_ p: UsageAccountPresentation) -> String? {
        guard p.usage.accountRef.hasPrefix("app:") else { return nil }
        return String(p.usage.accountRef.dropFirst("app:".count))
    }

    private func connectProfile(for account: AccountStatus) {
        guard !model.isDemo else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let suggested = SwitcherEnvironment.live().home
            .appendingPathComponent(".claude-instances", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: suggested.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            panel.directoryURL = suggested
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        let environment = SwitcherEnvironment.live()
        guard let profile = ClaudeProfileDirectory.validate(path: selected.path, home: environment.home,
            excludedRoots: [environment.claudeUserData, environment.storeDir]),
              ClaudeProfileDirectory.matchesIdentity(at: profile, accountUuid: account.accountUuid,
                                                     orgUuid: account.orgUuid)
        else {
            showProfileAlert(title: L10n.t(.uiClaudeProfileInvalidTitle),
                             message: L10n.t(.uiClaudeProfileInvalidBody))
            return
        }
        guard !model.claudeUsageProfiles.contains(where: {
            $0.accountId != account.id && $0.profilePath == profile.path
        }) else {
            showProfileAlert(title: L10n.t(.uiClaudeProfileInvalidTitle),
                             message: L10n.t(.uiClaudeProfileConflict))
            return
        }

        let consent = NSAlert()
        consent.messageText = L10n.t(.uiClaudeProfileConsentTitle)
        consent.informativeText = L10n.t(.uiClaudeProfileConsentBody)
        consent.addButton(withTitle: L10n.t(.uiConnectUsageEnable))
        consent.addButton(withTitle: L10n.t(.uiCancel))
        NSApp.activate()
        guard consent.runModal() == .alertFirstButtonReturn else { return }

        let binding = ClaudeProfileBinding(accountId: account.id, accountUuid: account.accountUuid,
                                           orgUuid: account.orgUuid, profilePath: profile.path)
        let bindings = model.claudeUsageProfiles.filter { $0.accountId != account.id } + [binding]
        if model.setClaudeUsageProfiles(bindings) {
            usage.applyClaudeProfiles(model.claudeUsageProfiles)
        }
    }

    private func disconnectProfile(_ accountID: String) {
        let bindings = model.claudeUsageProfiles.filter { $0.accountId != accountID }
        if model.setClaudeUsageProfiles(bindings) {
            usage.applyClaudeProfiles(model.claudeUsageProfiles)
        }
    }

    private func showProfileAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t(.uiClose))
        NSApp.activate()
        alert.runModal()
    }

    /// The name as displayed: masked when it is an email shape and hiding is on.
    private func displayedName(_ p: UsageAccountPresentation) -> String {
        !model.showEmails && p.name.contains("@") ? Privacy.maskEmails(in: p.name) : p.name
    }

    private func customName(of p: UsageAccountPresentation) -> String? {
        switch p.owner {
        case .claude(let id): model.status?.accounts.first { $0.id == id }?.customName
        case .codex(let id): codex.status?.accounts.first { $0.id == id }?.customName
        case nil: nil
        }
    }

    private func defaultName(of p: UsageAccountPresentation) -> String {
        switch p.owner {
        case .claude(let id): model.status?.accounts.first { $0.id == id }?.defaultName ?? p.name
        case .codex(let id): codex.status?.accounts.first { $0.id == id }?.defaultName ?? p.name
        case nil: p.name
        }
    }

    @ViewBuilder private func editor(for p: UsageAccountPresentation) -> some View {
        if p.owner != nil {
            Divider()
            if !editing {
                Button(L10n.t(.usageRename)) {
                    draft = UsageNameDraft(currentName: p.name,
                                           customName: customName(of: p),
                                           defaultName: defaultName(of: p),
                                           showEmails: model.showEmails)
                    saveError = nil
                    editing = true
                }.font(.system(size: 12)).disabled(model.isBusy || codex.isBusy)
            } else if let d = draft {
                TextField(d.placeholder ?? L10n.t(.usageNameField), text: Binding(
                    get: { draft?.text ?? "" }, set: { draft?.edit($0) }))
                    .textFieldStyle(.roundedBorder).disabled(busy)
                    .accessibilityLabel(L10n.t(.usageNameField))
                if let saveError {
                    Text(saveError).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        } else {
            Text(L10n.t(.usageUnregisteredName)).font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func save(_ owner: UsageAccountPresentation.Owner, _ d: UsageNameDraft) {
        busy = true; saveError = nil
        Task {
            do {
                let value = try d.saveValue()
                switch owner {
                case .claude(let id): try await model.renameDisplayName(id, to: value)
                case .codex(let id): try await codex.renameDisplayName(id, to: value)
                }
                await MainActor.run { busy = false; editing = false; draft = nil }
            } catch {
                await MainActor.run {
                    busy = false
                    saveError = (error as? SwitcherError)?.description ?? error.localizedDescription
                }
            }
        }
    }
}
