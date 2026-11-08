import SwiftUI
import SwitcherCore

struct APIContent: View {
    @ObservedObject var usage: UsageModel
    @ObservedObject var settings: SwitcherModel
    var compact = false
    @State private var selectedVendor: APIVendor = .anthropic
    @State private var nickname = ""
    @State private var key = ""
    @State private var entries: [APIKeyEntry] = []
    @State private var revealedKeys: [String: String] = [:]
    @State private var keyMessage: String?

    private var vault: KeychainAPIKeyVault {
        KeychainAPIKeyVault(policy: settings.apiKeyVaultAccessPolicy)
    }

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
                    Divider().overlay(Theme.hairline)
                }

                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    Text(L10n.t(.apiVaultTitle))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Picker(L10n.t(.apiPolicy), selection: Binding(
                        get: { settings.apiKeyVaultAccessPolicy },
                        set: { settings.setAPIKeyVaultAccessPolicy($0) })) {
                        Text(L10n.t(.apiPolicyStandard)).tag(APIKeyVaultAccessPolicy.standard)
                        Text(L10n.t(.apiPolicyStrong)).tag(APIKeyVaultAccessPolicy.strong)
                    }
                    .pickerStyle(.menu)

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
                            .disabled(key.isEmpty || settings.isDemo)
                    }
                    if let keyMessage {
                        Text(keyMessage).font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Text("\(vendorName(entry.vendor)) · \(entry.nickname) · ••••\(entry.last4)")
                                .font(Theme.caption).foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let secret = revealedKeys[entry.id] {
                                TextField(L10n.t(.apiKeyValue), text: .constant(secret))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 150)
                                Button(L10n.t(.apiKeyHide)) { revealedKeys.removeValue(forKey: entry.id) }
                            } else {
                                Button(L10n.t(.apiKeyReveal)) { revealKey(entry) }
                            }
                            Button(L10n.t(.apiKeyDelete), role: .destructive) { deleteKey(entry) }
                        }
                    }
                }
            }
            .padding(compact ? 8 : Theme.gapGroup)
            .frame(maxWidth: 712, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task { await reloadKeys() }
        .onChange(of: settings.apiKeyVaultAccessPolicy) { _, _ in
            revealedKeys.removeAll()
            Task { await reloadKeys() }
        }
    }

    @ViewBuilder
    private func vendorSection(_ vendor: APIVendor) -> some View {
        let estimate = usage.apiUsageEstimates[vendor]
        let hasAPIKeyAccount = usage.usages.contains {
            $0.authentication == .apiKey && $0.provider == vendor.usageProvider
        }
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Text(vendorName(vendor))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            APIBudgetRow(vendor: vendor, settings: settings)
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
            if hasAPIKeyAccount {
                if let spend = estimate?.spendLast7DaysUSD,
                   let dailyRate = estimate?.dailyRateUSD {
                    Text(L10n.t(.apiEstimate, usd(spend)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    Text(L10n.t(.apiDailyRate, usd(dailyRate)))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    if let remaining = usage.apiBudgetRemaining(for: vendor),
                       let days = APIBudgetMath.daysLeft(remainingUSD: remaining, dailyRateUSD: dailyRate) {
                        Text(L10n.t(.apiDaysLeft, days))
                            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                } else {
                    Text(L10n.t(.apiNoPrice))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            if usage.hasSubscriptionRoom(for: vendor) {
                Text(L10n.t(.apiSubscriptionRoom))
                    .font(Theme.caption).foregroundStyle(Theme.active)
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
        Task {
            do {
                _ = try await vault.register(vendor: savedVendor, nickname: savedNickname, key: savedKey)
                key = ""
                nickname = ""
                keyMessage = L10n.t(.apiKeyStored)
                await reloadKeys()
            } catch {
                keyMessage = L10n.t(.apiKeyFailure)
            }
        }
    }

    private func reloadKeys() async {
        guard !settings.isDemo else {
            entries = []
            revealedKeys = [:]
            return
        }
        do { entries = try await vault.list() }
        catch { entries = [] }
    }

    private func revealKey(_ entry: APIKeyEntry) {
        Task {
            do { revealedKeys[entry.id] = try await vault.reveal(id: entry.id) }
            catch { keyMessage = L10n.t(.apiKeyAccessFailure) }
        }
    }

    private func deleteKey(_ entry: APIKeyEntry) {
        Task {
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
    @State private var amount = ""
    @State private var kind: Kind = .balance
    @State private var resetDay = "1"

    private enum Kind: String, CaseIterable, Identifiable {
        case balance, quota
        var id: String { rawValue }
    }

    init(vendor: APIVendor, settings: SwitcherModel) {
        self.vendor = vendor
        self.settings = settings
        switch settings.apiBudget(for: vendor) {
        case .balance(let amount, _):
            _amount = State(initialValue: String(amount))
            _kind = State(initialValue: .balance)
        case .quota(let amount, let day):
            _amount = State(initialValue: String(amount))
            _kind = State(initialValue: .quota)
            _resetDay = State(initialValue: String(day))
        case nil:
            break
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(L10n.t(.apiBudgetTitle), selection: $kind) {
                Text(L10n.t(.apiBudgetBalance)).tag(Kind.balance)
                Text(L10n.t(.apiBudgetQuota)).tag(Kind.quota)
            }
            .pickerStyle(.menu)
            TextField(L10n.t(.apiBudgetAmount), text: $amount)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
            if kind == .quota {
                TextField(L10n.t(.apiBudgetResetDay), text: $resetDay)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 54)
            }
            Button(L10n.t(.apiBudgetSave), action: save)
                .disabled(settings.isDemo)
            if settings.apiBudget(for: vendor) != nil {
                Button(L10n.t(.apiBudgetClear)) { settings.setAPIBudget(nil, for: vendor) }
                    .disabled(settings.isDemo)
            }
        }
    }

    private func save() {
        guard let value = Double(amount), value.isFinite, value >= 0 else { return }
        switch kind {
        case .balance:
            settings.setAPIBudget(.balance(amountUSD: value, asOf: Date()), for: vendor)
        case .quota:
            guard let day = Int(resetDay), (1...31).contains(day) else { return }
            settings.setAPIBudget(.quota(amountUSD: value, resetDayOfMonth: day), for: vendor)
        }
    }
}
