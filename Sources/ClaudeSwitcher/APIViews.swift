import SwiftUI
import SwitcherCore

struct APIContent: View {
    @ObservedObject var usage: UsageModel
    @ObservedObject var settings: SwitcherModel
    var compact = false
    @State private var selectedVendor: APIVendor = .anthropic
    @State private var nickname = ""
    @State private var key = ""
    @State private var registerAsAdmin = false
    @State private var entries: [APIKeyEntry] = []
    @State private var revealedKeys: [String: String] = [:]
    @State private var keyMessage: String?
    /// The Keychain list couldn't be read: the empty list below is not "no keys".
    @State private var keyListFailed = false
    @State private var pendingDelete: APIKeyEntry?

    private var vault: KeychainAPIKeyVault { KeychainAPIKeyVault() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapGroup) {
                Text(L10n.t(.apiTitle))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(L10n.t(.apiKeyHelp))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !usage.usages.contains(where: { $0.authentication == .apiKey }) {
                    Text(L10n.t(.apiEmptyState))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.inkMuted.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(APIVendor.allCases) { vendor in
                    vendorSection(vendor)
                    Divider()
                }

                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    Text(L10n.t(.apiVaultTitle))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    HStack {
                        Picker(L10n.t(.apiKeyVendor), selection: $selectedVendor) {
                            ForEach(APIVendor.allCases) { vendor in
                                Text(vendorName(vendor)).tag(vendor)
                            }
                        }
                        .pickerStyle(.menu)
                        TextField(L10n.t(.apiKeyNickname), text: $nickname)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        SecureField(L10n.t(.apiKeyValue), text: $key)
                            .textFieldStyle(.roundedBorder)
                        Button(L10n.t(.apiKeyRegister), action: registerKey)
                            .disabled(key.isEmpty
                                || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || settings.isDemo)
                    }
                    if selectedVendor == .anthropic || selectedVendor == .openai {
                        Toggle(L10n.t(.apiKeyAdminToggle), isOn: $registerAsAdmin)
                            .font(Theme.caption).foregroundStyle(Theme.ink)
                    }
                    if keyListFailed {
                        UsageNote(text: L10n.t(.apiKeyListFailed), tone: .failure)
                    }
                    if let keyMessage {
                        Text(keyMessage).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text((entry.isUnreadable
                                 ? "\(vendorName(entry.vendor)) · \(entry.nickname) · \(L10n.t(.apiKeyUnreadable))"
                                 : "\(vendorName(entry.vendor)) · \(entry.nickname) · ••••\(entry.last4)")
                                 + (entry.isAdmin ? " · \(L10n.t(.apiKeyAdminTag))" : ""))
                                .font(Theme.caption).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let secret = revealedKeys[entry.id] {
                                TextField(L10n.t(.apiKeyValue), text: .constant(secret))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 150)
                                Button(L10n.t(.apiKeyHide)) { revealedKeys.removeValue(forKey: entry.id) }
                                    .accessibilityLabel(APIKeyText.hideLabel(for: entry))
                            } else if !entry.isUnreadable {
                                Button(L10n.t(.apiKeyReveal)) { revealKey(entry) }
                                    .accessibilityLabel(APIKeyText.revealLabel(for: entry))
                            }
                            // Deleting can't be undone: ask first, naming the key, then authenticate.
                            Button(L10n.t(.apiKeyDelete), role: .destructive) { pendingDelete = entry }
                                .accessibilityLabel(APIKeyText.deleteLabel(for: entry))
                        }
                    }
                }
            }
            .padding(compact ? 8 : Theme.gapGroup)
            .frame(maxWidth: 712, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await reloadKeys() }
        // A typed key that was never stored doesn't wait for the next visit either.
        .onDisappear { revealedKeys.removeAll(); key = "" }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.apiKeysShouldHideNotification)) { _ in
            revealedKeys.removeAll()
        }
        .alert(
            pendingDelete.map { APIKeyText.deleteConfirmation(for: $0).title } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button(L10n.t(.apiKeyDelete), role: .destructive) { deleteKey(entry) }
            Button(L10n.t(.uiCancel), role: .cancel) { pendingDelete = nil }
                .keyboardShortcut(.defaultAction)
        } message: { entry in
            Text(APIKeyText.deleteConfirmation(for: entry).detail)
        }
    }

    @ViewBuilder
    private func vendorSection(_ vendor: APIVendor) -> some View {
        let estimate = usage.apiUsageEstimates[vendor]
        let hasAPIKeyAccount = usage.usages.contains {
            $0.authentication == .apiKey && $0.provider == vendor.usageProvider
        }
        let actual = usage.apiActualSpends[vendor]
        let actualOK: Bool = { if case .ok = actual { return true }; return false }()
        let hasAdminEntry = entries.contains { $0.vendor == vendor && $0.isAdmin }
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Text(vendorName(vendor))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            // No spend figure to count a budget against: the row is hidden, a saved value is kept.
            if vendor.budgetBasis != nil {
                APIBudgetRow(vendor: vendor, settings: settings, usage: usage)
            }
            if let budget = settings.apiBudget(for: vendor),
               let remaining = usage.apiBudgetRemaining(for: vendor) {
                switch budget {
                case .balance:
                    Text(L10n.t(.apiBalanceRemaining, usd(remaining)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                case .quota:
                    Text(L10n.t(.apiQuotaRemaining, usd(remaining)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            if vendor.budgetBasis == .actualSpend, case .ok(let spend) = actual,
               let budget = settings.apiBudget(for: vendor) {
                switch APIBudgetMath.actualRemaining(budget, spend: spend, now: Date()) {
                case .remaining(let remaining):
                    Text(L10n.t(.apiQuotaRemaining, usd(remaining)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                case .notCalendarMonth:
                    Text(L10n.t(.apiBudgetCalendarMonthOnly))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
            }
            // A registered admin billing key replaces the log estimate with real figures.
            if case .ok(let spend) = actual {
                Text(L10n.t(.apiAdminMonth, usd(spend.monthToDateUSD)))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Text(L10n.t(.apiAdminActual, usd(spend.last7DaysUSD)))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                Text(L10n.t(.apiAdminAsOf,
                            UsageText.readTime(spend.asOf, now: Date(), language: settings.language)))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            } else if actual == .keyRejected {
                Text(L10n.t(.apiAdminKeyRejected))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            } else if actual == .notEligible {
                Text(L10n.t(.apiAdminNotEligible))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            } else if actual == .rateLimited || actual == .network || actual == .schemaChanged {
                Text(L10n.t(.apiAdminFailed))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            } else if !hasAdminEntry && !keyListFailed && (vendor == .anthropic || vendor == .openai) {
                Text(L10n.t(.apiAdminHint))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
            if !vendor.hasLogReader {
                // Shown whether or not an API-key account exists: only Codex rows can be one.
                Text(L10n.t(.apiNotEstimable))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            } else if hasAPIKeyAccount, !actualOK {
                if let spend = estimate?.spendLast7DaysUSD,
                   let dailyRate = estimate?.dailyRateUSD {
                    Text(L10n.t(.apiEstimate, usd(spend)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    Text(L10n.t(.apiDailyRate, usd(dailyRate)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    if let remaining = usage.apiBudgetRemaining(for: vendor),
                       let days = APIBudgetMath.daysLeft(remainingUSD: remaining, dailyRateUSD: dailyRate) {
                        Text(days == 1 ? L10n.t(.apiDayLeft, 1) : L10n.t(.apiDaysLeft, days))
                            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                } else {
                    Text(L10n.t(estimate?.isReadingLogs == true ? .apiEstimatesReadingLogs : .apiNoPrice))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
                // Prices come from the catalog built into this version: say how old it is.
                if let date = ModelCatalogDate.text(language: settings.language) {
                    Text(L10n.t(.usageCatalogAsOf, date))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if usage.hasSubscriptionRoom(for: vendor) {
                Text(L10n.t(.apiSubscriptionRoom))
                    .font(Theme.caption).foregroundStyle(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func vendorName(_ vendor: APIVendor) -> String {
        switch vendor {
        case .anthropic: L10n.t(.apiVendorAnthropic)
        case .openai: L10n.t(.apiVendorOpenAI)
        case .google: L10n.t(.apiVendorGoogle)
        case .xai: L10n.t(.apiVendorXAI)
        }
    }

    private func registerKey() {
        let savedVendor = selectedVendor
        let savedNickname = nickname
        let savedKey = key
        let savedAdmin = registerAsAdmin
            && (savedVendor == .anthropic || savedVendor == .openai)
        Task {
            keyMessage = nil
            do {
                _ = try await vault.register(vendor: savedVendor, nickname: savedNickname,
                                             key: savedKey, admin: savedAdmin)
                key = ""
                nickname = ""
                keyMessage = L10n.t(.apiKeyStored)
                await reloadKeys()
            } catch APIKeyVaultError.invalidEntry {
                keyMessage = L10n.t(.apiKeyInvalidEntry)
            } catch APIKeyVaultError.keychainFailure {
                keyMessage = L10n.t(.apiKeyFailure)
            } catch {
                keyMessage = L10n.t(.apiKeyAccessFailure)
            }
        }
    }

    private func reloadKeys() async {
        guard !settings.isDemo else {
            entries = []
            revealedKeys = [:]
            return
        }
        do {
            entries = try await vault.list()
            keyListFailed = false
            usage.adminKeysDidChange(adminVendors: Set(entries.filter(\.isAdmin).map(\.vendor)))
        } catch {
            keyListFailed = true
        }
    }

    private func revealKey(_ entry: APIKeyEntry) {
        Task {
            keyMessage = nil
            do {
                revealedKeys[entry.id] = try await vault.reveal(id: entry.id)
                // A revealed secret must not stay on screen (audit B-06).
                try? await Task.sleep(for: .seconds(60))
                revealedKeys.removeValue(forKey: entry.id)
            } catch { keyMessage = L10n.t(.apiKeyAccessFailure) }
        }
    }

    private func deleteKey(_ entry: APIKeyEntry) {
        Task {
            keyMessage = nil
            do {
                try await vault.delete(id: entry.id)
                revealedKeys.removeValue(forKey: entry.id)
                await reloadKeys()
            } catch {
                keyMessage = L10n.t(.apiKeyAccessFailure)
            }
        }
    }

    private func usd(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}

private struct APIBudgetRow: View {
    let vendor: APIVendor
    @ObservedObject var settings: SwitcherModel
    @ObservedObject var usage: UsageModel
    @State private var amount = ""
    @State private var kind: APIBudgetKind
    @State private var resetDay = "1"

    /// Wide enough for the amount placeholder in every language ("Importe (USD)").
    static let amountWidth: CGFloat = 112
    static let resetDayWidth: CGFloat = 52

    init(vendor: APIVendor, settings: SwitcherModel, usage: UsageModel) {
        self.vendor = vendor
        self.settings = settings
        self.usage = usage
        _kind = State(initialValue: APIBudgetInput.defaultKind(for: vendor))
        switch settings.apiBudget(for: vendor) {
        case .balance(let amount, _, _):
            _amount = State(initialValue: APIBudgetInput.text(amount))
            _kind = State(initialValue: .balance)
        case .quota(let amount, let day):
            _amount = State(initialValue: APIBudgetInput.text(amount))
            _kind = State(initialValue: .quota)
            _resetDay = State(initialValue: String(day))
        case nil:
            break
        }
    }

    private var parsedAmount: Double? { APIBudgetInput.amount(amount) }
    private var parsedDay: Int? { APIBudgetInput.resetDay(resetDay) }
    private var canSave: Bool {
        !settings.isDemo && parsedAmount != nil
            && (kind == .balance ? balanceBaseline != nil : parsedDay != nil)
    }

    /// Today's spend so far, which a balance entered now already paid; nil until the logs are read.
    private var balanceBaseline: Double? {
        APIBudgetMath.balanceBaseline(usage.apiUsageEstimates[vendor], at: Date())
    }

    /// Why a balance can't be saved yet, unless the vendor section already says it: with no week
    /// figure it shows "still reading" or "no price"; with one, only this row can explain.
    private var balanceNote: L10nKey? {
        guard balanceBaseline == nil else { return nil }
        guard let estimate = usage.apiUsageEstimates[vendor] else { return .apiEstimatesLoading }
        return estimate.spendLast7DaysUSD != nil ? .apiNoPrice : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            // One line in the window; in the menu the controls wrap so every placeholder shows whole.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { kindPicker; fields; buttons }
                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    kindPicker
                    HStack(spacing: 6) { fields; buttons }
                }
                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    kindPicker
                    HStack(spacing: 6) { fields }
                    HStack(spacing: 6) { buttons }
                }
            }
            // A value that can't be saved says why, instead of a Save that does nothing.
            if !amount.trimmingCharacters(in: .whitespaces).isEmpty, parsedAmount == nil {
                UsageNote(text: L10n.t(.apiBudgetInvalidAmount), tone: .warning)
            } else if kind == .quota, !resetDay.trimmingCharacters(in: .whitespaces).isEmpty, parsedDay == nil {
                UsageNote(text: L10n.t(.apiBudgetInvalidDay), tone: .warning)
            }
            if kind == .balance, let note = balanceNote {
                Text(L10n.t(note))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var kindPicker: some View {
        Picker(L10n.t(.apiBudgetTitle), selection: $kind) {
            Text(L10n.t(.apiBudgetBalance)).tag(APIBudgetKind.balance)
            Text(L10n.t(.apiBudgetQuota)).tag(APIBudgetKind.quota)
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    @ViewBuilder private var fields: some View {
        TextField(L10n.t(.apiBudgetAmount), text: $amount)
            .textFieldStyle(.roundedBorder)
            .frame(width: Self.amountWidth)
            .onSubmit(save)
        if kind == .quota {
            Text(L10n.t(.apiBudgetResetDay)).font(Theme.caption).foregroundStyle(Theme.ink)
                .fixedSize()
            TextField("1–31", text: $resetDay)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.resetDayWidth)
                .accessibilityLabel(L10n.t(.apiBudgetResetDay))
                .onSubmit(save)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(L10n.t(.apiBudgetSave), action: save)
            .disabled(!canSave)
        if settings.apiBudget(for: vendor) != nil {
            Button(L10n.t(.apiBudgetClear)) { settings.setAPIBudget(nil, for: vendor) }
                .disabled(settings.isDemo)
        }
    }

    private func save() {
        guard canSave, let value = parsedAmount else { return }
        switch kind {
        case .balance:
            let asOf = Date()
            guard let asOfDaySpentUSD = APIBudgetMath.balanceBaseline(usage.apiUsageEstimates[vendor],
                                                                     at: asOf) else { return }
            settings.setAPIBudget(.balance(amountUSD: value, asOf: asOf,
                                            asOfDaySpentUSD: asOfDaySpentUSD), for: vendor)
        case .quota:
            guard let day = parsedDay else { return }
            settings.setAPIBudget(.quota(amountUSD: value, resetDayOfMonth: day), for: vendor)
        }
        amount = APIBudgetInput.text(value)
    }
}
