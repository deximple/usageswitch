import Foundation
import Testing
@testable import SwitcherCore

@Suite("API budgets, estimates, and vault")
struct APITests {
    private let now = Date(timeIntervalSince1970: 1_742_378_400)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("balance and quota budget types persist distinctly")
    func budgetCodingAndSettings() throws {
        let balance = APIBudget.balance(amountUSD: 100, asOf: now, asOfDaySpentUSD: 12)
        let quota = APIBudget.quota(amountUSD: 75, resetDayOfMonth: 17)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(APIBudget.self, from: encoder.encode(balance)) == balance)
        #expect(try decoder.decode(APIBudget.self, from: encoder.encode(quota)) == quota)
        var oldBalanceJSON = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(balance)) as? [String: Any])
        oldBalanceJSON.removeValue(forKey: "asOfDaySpentUSD")
        let decodedOldBalance = try decoder.decode(
            APIBudget.self, from: JSONSerialization.data(withJSONObject: oldBalanceJSON))
        #expect(decodedOldBalance == .balance(amountUSD: 100, asOf: now))

        let google = APIBudget.balance(amountUSD: 20, asOf: now)
        let xai = APIBudget.quota(amountUSD: 30, resetDayOfMonth: 3)
        let settings = SwitcherSettings(apiBudgetAnthropic: balance, apiBudgetOpenAI: quota,
            apiBudgetGoogle: google, apiBudgetXAI: xai, apiKeyVaultAccessPolicy: .strong)
        let saved = try decoder.decode(SwitcherSettings.self, from: encoder.encode(settings))
        #expect(saved.apiBudget(for: .anthropic) == balance)
        #expect(saved.apiBudget(for: .openai) == quota)
        #expect(saved.apiBudget(for: .google) == google)
        #expect(saved.apiBudget(for: .xai) == xai)
        #expect(saved.effectiveAPIKeyVaultAccessPolicy == .strong)
        #expect(SwitcherSettings().effectiveAPIKeyVaultAccessPolicy == .standard)
    }

    @Test("balance and monthly quota math use separate start dates and clamp reset days")
    func budgetMath() throws {
        let calendar = utc
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 15, hour: 12)))
        let spending = [
            APIDailySpend(day: "2025-03-09", amountUSD: 15),
            APIDailySpend(day: "2025-03-10", amountUSD: 10),
            APIDailySpend(day: "2025-03-14", amountUSD: 20),
            APIDailySpend(day: "2025-03-16", amountUSD: 999),
        ]
        #expect(APIBudgetMath.remaining(.balance(amountUSD: 100,
            asOf: calendar.date(from: DateComponents(year: 2025, month: 3, day: 10))!),
            spending: spending, now: now) == 70)
        #expect(APIBudgetMath.remaining(.quota(amountUSD: 50, resetDayOfMonth: 10),
            spending: spending, now: now) == 20)
        let beforeReset = try #require(calendar.date(
            from: DateComponents(year: 2025, month: 3, day: 9, hour: 12)))
        #expect(APIBudgetMath.monthlyCycleStart(resetDayOfMonth: 10, now: beforeReset)
            == calendar.date(from: DateComponents(year: 2025, month: 2, day: 10)))
        let february = try #require(calendar.date(from: DateComponents(year: 2025, month: 2, day: 28)))
        #expect(APIBudgetMath.monthlyCycleStart(resetDayOfMonth: 31, now: february)
            == calendar.date(from: DateComponents(year: 2025, month: 2, day: 28)))
        #expect(APIBudgetMath.daysLeft(remainingUSD: 25, dailyRateUSD: 5) == 5)
        #expect(APIBudgetMath.daysLeft(remainingUSD: 25, dailyRateUSD: 0) == nil)
        #expect(APIBudgetMath.daysLeft(remainingUSD: 25, dailyRateUSD: nil) == nil)
        #expect(APIBudgetMath.remaining(.balance(amountUSD: 25,
            asOf: now.addingTimeInterval(60)), spending: [], now: now) == nil)

        let asOf = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 10, hour: 12)))
        let savedBalance = APIBudget.balance(amountUSD: 100, asOf: asOf, asOfDaySpentUSD: 10)
        #expect(APIBudgetMath.remaining(savedBalance,
            spending: [APIDailySpend(day: "2025-03-10", amountUSD: 10)], now: asOf) == 100)
        #expect(APIBudgetMath.remaining(savedBalance,
            spending: [APIDailySpend(day: "2025-03-10", amountUSD: 16)],
            now: asOf.addingTimeInterval(60)) == 94)
        #expect(APIBudgetMath.remaining(savedBalance,
            spending: [
                APIDailySpend(day: "2025-03-10", amountUSD: 16),
                APIDailySpend(day: "2025-03-11", amountUSD: 4),
            ], now: asOf.addingTimeInterval(86_400)) == 90)
    }

    @Test("spend estimates include API-key accounts only and hide unknown prices")
    func estimatesUseOnlyPricedAPIKeyUsage() throws {
        let catalog = try SuggestionCatalog.bundled()
        let model = try #require(catalog.models.first {
            $0.model == "claude-fable-5-1"
        })
        func price(_ code: String) throws -> Double {
            try #require(model.values.first { $0.code == code }?.number)
        }
        let key = APIKeyAccountKey(provider: .claude, accountKey: "acct-0123456789abcdef")
        let day = SuggestionRetention.utcDay(now)
        let apiRecord = SuggestionLogUsage(day: day, provider: .claude, accountRef: key.accountKey,
            model: model.model, effort: "high", turns: 1, inputTokens: 1_000_000,
            cachedInputTokens: 100_000, cachedCreationTokens: 200_000,
            outputTokens: 500_000, reasoningTokens: 0,
            toolVersion: nil)
        let subscriptionRecord = SuggestionLogUsage(day: day, provider: .claude,
            accountRef: "acct-subscription", model: model.model, effort: "high", turns: 10,
            inputTokens: 8_000_000, cachedInputTokens: 0, outputTokens: 8_000_000,
            reasoningTokens: 0, toolVersion: nil)
        let inputPrice = try price("inputPricePerMTok")
        let cachedReadPrice = try price("cachedReadPricePerMTok")
        let outputPrice = try price("outputPricePerMTok")
        let inputCost: Double = 1_200_000 * inputPrice / 1_000_000
        let cachedCost: Double = 100_000 * cachedReadPrice / 1_000_000
        let outputCost: Double = 500_000 * outputPrice / 1_000_000
        let expected: Double = inputCost + cachedCost + outputCost
        let markedSubscription = SuggestionLogUsage(day: day, provider: .claude,
            accountRef: key.accountKey, model: model.model, effort: "high", turns: 3,
            inputTokens: 5_000_000, cachedInputTokens: 0, outputTokens: 5_000_000,
            reasoningTokens: 0, toolVersion: nil, subscription: true)
        let estimates = APIUsageEstimator.estimate(
            records: [apiRecord, subscriptionRecord, markedSubscription],
            apiKeyAccounts: [key], catalog: catalog, now: now)
        let anthropic = try #require(estimates[.anthropic])
        #expect(anthropic.hasAPIKeyAccounts)
        #expect(abs(try #require(anthropic.spendLast7DaysUSD) - expected) < 0.000_001)
        #expect(abs(try #require(anthropic.dailyRateUSD) - expected / 7) < 0.000_001)
        #expect(estimates[.openai]?.hasAPIKeyAccounts == false)

        let noPrice = SuggestionLogUsage(day: day, provider: .claude, accountRef: key.accountKey,
            model: "unknown/private-model", effort: nil, turns: 1, inputTokens: 100,
            cachedInputTokens: 0, outputTokens: 100, reasoningTokens: 0, toolVersion: nil)
        let unknownEstimate = APIUsageEstimator.estimate(records: [noPrice],
            apiKeyAccounts: [key], catalog: catalog, now: now)[.anthropic]
        #expect(unknownEstimate?.spendLast7DaysUSD == nil)
        #expect(unknownEstimate?.dailyRateUSD == nil)
        let noAccounts = APIUsageEstimator.estimate(records: [apiRecord], apiKeyAccounts: [],
            catalog: catalog, now: now)[.anthropic]
        #expect(noAccounts?.hasAPIKeyAccounts == false)
        let unloggedProvider = APIUsageEstimator.estimate(records: [],
            apiKeyAccounts: [APIKeyAccountKey(provider: .gemini, accountKey: "acct-google")],
            catalog: catalog, now: now)[.google]
        #expect(unloggedProvider?.hasAPIKeyAccounts == true)
        #expect(unloggedProvider?.spendLast7DaysUSD == nil)
        #expect(unloggedProvider?.spendIsComplete == false)
    }

    @Test("monthly API estimates can read compressed log-usage archives")
    func readsCompressedUsageArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = SwitcherEnvironment(home: root, claudeAppURL: root.appendingPathComponent("Claude.app"),
            claudeUserData: root.appendingPathComponent("Claude"),
            claudeLogsDir: root.appendingPathComponent("Logs"),
            launchAgentsDir: root.appendingPathComponent("Agents"),
            storeDir: root.appendingPathComponent("store"))
        let fs = SafeFS(env: env)
        let directory = env.storeDir.appendingPathComponent("suggestion")
        try fs.createDirectory(directory)
        let occurredAt = now.addingTimeInterval(-31 * 86_400)
        let day = SuggestionRetention.utcDay(occurredAt)
        let record = SuggestionLogUsage(day: day, provider: .claude,
            accountRef: "acct-0123456789abcdef", model: "claude-fable-5-1",
            effort: "high", turns: 1, inputTokens: 100, cachedInputTokens: 10,
            outputTokens: 20, reasoningTokens: 0, toolVersion: nil,
            lastUsedAt: occurredAt)
        try SuggestionStorage.appendLines([record], component: "log-usage", day: day,
            directory: directory, fs: fs)
        SuggestionRetention.prune(directory: directory, fs: fs, now: now)
        let archive = directory.appendingPathComponent("archive")
            .appendingPathComponent("log-usage-\(day).jsonl.zlib")
        #expect(FileManager.default.fileExists(atPath: archive.path))

        let reader = SuggestionLogReader(env: env, fs: fs, catalog: try SuggestionCatalog.bundled())
        #expect(reader.recentRecords(now: now, days: 35) == [record])
    }

    @Test("usage and subscription cross-reference predicates remain conservative")
    func crossReferences() {
        #expect(APIBudgetMath.showUsageListBalance(usedPercent: 95, remainingUSD: 1))
        #expect(!APIBudgetMath.showUsageListBalance(usedPercent: 94.99, remainingUSD: 1))
        #expect(!APIBudgetMath.showUsageListBalance(usedPercent: 99, remainingUSD: 0))
        let windows = [UsageWindow(durationMinutes: 300, usedPercent: 20, resetsAt: nil),
                       UsageWindow(durationMinutes: 10_080, usedPercent: 49, resetsAt: nil)]
        #expect(APIBudgetMath.showSubscriptionRoom(dailyRateUSD: 5,
            medianDailyRateUSD: 4, subscriptionWindows: windows))
        #expect(!APIBudgetMath.showSubscriptionRoom(dailyRateUSD: 4,
            medianDailyRateUSD: 4, subscriptionWindows: windows))
        #expect(!APIBudgetMath.showSubscriptionRoom(dailyRateUSD: 5,
            medianDailyRateUSD: 4, subscriptionWindows: [
                UsageWindow(durationMinutes: 300, usedPercent: 50, resetsAt: nil)]))
    }

    @Test("fake vault authenticates policy-specific reads and other key operations")
    func fakeVaultAuthentication() async throws {
        let standardAuthenticator = CountingAuthenticator()
        let standardVault = FakeAPIKeyVault(policy: .standard, authenticator: standardAuthenticator)
        let entry = try await standardVault.register(
            vendor: .anthropic, nickname: "work", key: "sk-test-1234")
        let listed = try await standardVault.list()
        #expect(listed == [entry])
        #expect(entry.last4 == "1234")
        #expect(!listed.description.contains("sk-test-1234"))
        #expect(try await standardVault.read(id: entry.id) == "sk-test-1234")
        #expect(await standardAuthenticator.callCount == 1)
        #expect(try await standardVault.reveal(id: entry.id) == "sk-test-1234")
        try await standardVault.delete(id: entry.id)
        #expect(try await standardVault.list().isEmpty)
        #expect(await standardAuthenticator.callCount == 3)

        let strongAuthenticator = CountingAuthenticator()
        let strongVault = FakeAPIKeyVault(policy: .strong, authenticator: strongAuthenticator)
        let strongEntry = try await strongVault.register(
            vendor: .openai, nickname: "strong", key: "sk-strong-5678")
        #expect(try await strongVault.read(id: strongEntry.id) == "sk-strong-5678")
        #expect(await strongAuthenticator.callCount == 2)
        await strongAuthenticator.failAuthentication()
        var returnedValue: String?
        do {
            returnedValue = try await strongVault.read(id: strongEntry.id)
        } catch {
            #expect(error as? APIKeyVaultError == .authenticationFailed)
        }
        #expect(returnedValue == nil)
        #expect(await strongAuthenticator.callCount == 3)
    }
}

private actor CountingAuthenticator: APIKeyVaultAuthenticator {
    private(set) var callCount = 0
    private var shouldFail = false

    func evaluatePolicy() async throws {
        callCount += 1
        if shouldFail { throw APIKeyVaultError.authenticationFailed }
    }

    func failAuthentication() {
        shouldFail = true
    }
}

private actor FakeAPIKeyVault: APIKeyVault {
    private struct Item: Sendable {
        let entry: APIKeyEntry
        let key: String
    }

    private let authenticator: APIKeyVaultAuthenticator
    private let policy: APIKeyVaultAccessPolicy
    private var items: [String: Item] = [:]

    init(policy: APIKeyVaultAccessPolicy, authenticator: APIKeyVaultAuthenticator) {
        self.policy = policy
        self.authenticator = authenticator
    }

    func register(vendor: APIVendor, nickname: String, key: String) async throws -> APIKeyEntry {
        try await authenticator.evaluatePolicy()
        let id = "\(vendor.rawValue):\(UUID().uuidString)"
        let entry = APIKeyEntry(id: id, vendor: vendor, nickname: nickname,
                                last4: String(key.suffix(4)), createdAt: Date())
        items[id] = Item(entry: entry, key: key)
        return entry
    }

    func list() async throws -> [APIKeyEntry] {
        items.values.map(\.entry)
    }

    func reveal(id: String) async throws -> String {
        try await authenticator.evaluatePolicy()
        guard let item = items[id] else { throw APIKeyVaultError.keyUnavailable }
        return item.key
    }

    func read(id: String) async throws -> String {
        if policy == .strong {
            try await authenticator.evaluatePolicy()
        }
        guard let item = items[id] else { throw APIKeyVaultError.keyUnavailable }
        return item.key
    }

    func delete(id: String) async throws {
        try await authenticator.evaluatePolicy()
        items.removeValue(forKey: id)
    }
}
