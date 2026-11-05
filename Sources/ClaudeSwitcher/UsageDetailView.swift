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
            Text(L10n.t(.usageNotLinked)).font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let reason = UsageText.reason(p.usage.state, provider: p.usage.provider) {
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(p.usage.windows, id: \.self) { w in
            UsageBarRow(usage: p.usage, window: w, settings: model, now: Date(),
                        compact: false,
                        fresh: (0...UsageGuidance.maximumAge).contains(Date().timeIntervalSince(p.usage.readAt)),
                        pace: usage.pace[UsagePriority.key(p.usage, w)])
        }
        if p.usage.windows.isEmpty && !savedApp {
            Text(L10n.t(.usageNoData)).font(.system(size: 11)).foregroundStyle(.secondary)
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
        case .claude: return "Claude CLI /usage"
        case .codex: return "Codex app-server"
        default: return "HTTPS · \(UsageText.providerName(p.usage.provider))"
        }
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
