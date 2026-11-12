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

    @Test func theDailyRateUsesTheDaysCovered() throws {
        let catalog = try SuggestionCatalog.bundled()
        let model = try #require(catalog.models.first { $0.model == "claude-fable-5-1" })
        let key = APIKeyAccountKey(provider: .claude, accountKey: "acct-rate")
        func record(daysAgo: Int, usd: Double) -> SuggestionLogUsage {
            let day = SuggestionRetention.utcDay(
                Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: now) ?? now)
            // one token at $1/token keeps the arithmetic exact
            let costPerToken = try? model.values.first { $0.code == "inputPricePerMTok" }?.number
            let tokens = Int64((usd * 1_000_000) / (costPerToken ?? 1))
            return SuggestionLogUsage(day: day, provider: .claude, accountRef: key.accountKey,
                model: model.model, effort: "high", turns: 1, inputTokens: tokens,
                cachedInputTokens: 0, cachedCreationTokens: 0,
                outputTokens: 0, reasoningTokens: 0, toolVersion: nil)
        }
        func day(_ daysAgo: Int) -> String {
            SuggestionRetention.utcDay(Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: now) ?? now)
        }
        // Coverage started today: one covered day.
        var e = APIUsageEstimator.estimate(records: [record(daysAgo: 0, usd: 14)],
            apiKeyAccounts: [key], catalog: catalog, now: now, coverageStartDay: day(0))
        #expect(abs((e[.anthropic]?.dailyRateUSD ?? 0) - 14) < 0.01)
        // Three covered days.
        e = APIUsageEstimator.estimate(records: [record(daysAgo: 0, usd: 7),
            record(daysAgo: 1, usd: 7), record(daysAgo: 2, usd: 7)],
            apiKeyAccounts: [key], catalog: catalog, now: now, coverageStartDay: day(2))
        #expect(abs((e[.anthropic]?.dailyRateUSD ?? 0) - 7) < 0.01)
        // Covered zero-spend days count: $14 today after six covered days without spend.
        e = APIUsageEstimator.estimate(records: [record(daysAgo: 0, usd: 14)],
            apiKeyAccounts: [key], catalog: catalog, now: now, coverageStartDay: day(13))
        #expect(abs((e[.anthropic]?.dailyRateUSD ?? 0) - 2) < 0.01)
        // Unknown coverage keeps the full 7-day window.
        e = APIUsageEstimator.estimate(records: [record(daysAgo: 0, usd: 14),
            record(daysAgo: 6, usd: 14)],
            apiKeyAccounts: [key], catalog: catalog, now: now)
        #expect(abs((e[.anthropic]?.dailyRateUSD ?? 0) - 4) < 0.01)
    }

    @Test func vendorsWithoutALogReaderAreMarkedNotEstimable() throws {
        let catalog = try SuggestionCatalog.bundled()
        let e = APIUsageEstimator.estimate(records: [], apiKeyAccounts: [
            APIKeyAccountKey(provider: .claude, accountKey: "a"),
            APIKeyAccountKey(provider: .gemini, accountKey: "b"),
            APIKeyAccountKey(provider: .grok, accountKey: "c"),
            APIKeyAccountKey(provider: .codex, accountKey: "d")],
            catalog: catalog, now: now)
        #expect(e[.anthropic]?.isEstimable == false)
        #expect(e[.google]?.isEstimable == false)
        #expect(e[.xai]?.isEstimable == false)
        #expect(e[.openai]?.isEstimable == true)
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
        // Coverage unknown here: the full 7-day window.
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

    // MARK: - Completeness (audit A-08)

    private func pricedRecord(_ key: APIKeyAccountKey, catalog: SuggestionCatalog) throws -> SuggestionLogUsage {
        let model = try #require(catalog.models.first { $0.model == "claude-fable-5-1" })
        return SuggestionLogUsage(day: SuggestionRetention.utcDay(now), provider: .claude, accountRef: key.accountKey,
            model: model.model, effort: "high", turns: 1, inputTokens: 1_000_000, cachedInputTokens: 0,
            outputTokens: 0, reasoningTokens: 0, toolVersion: nil)
    }

    @Test func spendIsHiddenWhileAnAPIKeyAccountStillHasUnreadLogs() throws {
        let catalog = try SuggestionCatalog.bundled()
        let key = APIKeyAccountKey(provider: .claude, accountKey: "acct-0123456789abcdef")
        let estimate = try #require(APIUsageEstimator.estimate(
            records: [try pricedRecord(key, catalog: catalog)], apiKeyAccounts: [key], catalog: catalog, now: now,
            incompleteAccounts: [key])[.anthropic])
        #expect(estimate.spendLast7DaysUSD == nil)
        #expect(estimate.dailyRateUSD == nil)
        #expect(estimate.medianDailyRate14DaysUSD == nil)
        #expect(estimate.spendIsComplete == false)
        #expect(estimate.dailySpend.isEmpty)
        #expect(estimate.isReadingLogs)
    }

    @Test func spendIsShownOnceTheBacklogIsGone() throws {
        let catalog = try SuggestionCatalog.bundled()
        let key = APIKeyAccountKey(provider: .claude, accountKey: "acct-0123456789abcdef")
        let records = [try pricedRecord(key, catalog: catalog)]
        let plain = APIUsageEstimator.estimate(records: records, apiKeyAccounts: [key], catalog: catalog, now: now)
        let explicit = APIUsageEstimator.estimate(records: records, apiKeyAccounts: [key], catalog: catalog, now: now,
                                                  incompleteAccounts: [], coverageStartDay: nil)
        #expect(plain == explicit)
        #expect(plain[.anthropic]?.spendLast7DaysUSD != nil)
        #expect(plain[.anthropic]?.isReadingLogs == false)
        // Another vendor's backlog does not hide this one.
        let other = APIUsageEstimator.estimate(records: records, apiKeyAccounts: [key], catalog: catalog, now: now,
            incompleteAccounts: [APIKeyAccountKey(provider: .codex, accountKey: "acct-other")])
        #expect(other[.anthropic]?.spendLast7DaysUSD != nil)
    }

    @Test func aMonthlyQuotaIsIncompleteUntilTheCycleIsCovered() throws {
        let spending = [APIDailySpend(day: SuggestionRetention.utcDay(now), amountUSD: 3)]
        let quota = APIBudget.quota(amountUSD: 10, resetDayOfMonth: 1)
        let cycleStart = SuggestionRetention.utcDay(
            try #require(APIBudgetMath.monthlyCycleStart(resetDayOfMonth: 1, now: now)))
        let dayAfter = SuggestionRetention.utcDay(
            try #require(APIBudgetMath.monthlyCycleStart(resetDayOfMonth: 1, now: now)).addingTimeInterval(86_400))
        #expect(APIBudgetMath.remaining(quota, spending: spending, now: now) == 7)
        #expect(APIBudgetMath.remaining(quota, spending: spending, now: now, coverageStartDay: cycleStart) == 7)
        #expect(APIBudgetMath.remaining(quota, spending: spending, now: now, coverageStartDay: dayAfter) == nil)
        // A prepaid balance entered today needs only today's logs.
        let balance = APIBudget.balance(amountUSD: 10, asOf: now.addingTimeInterval(-60))
        #expect(APIBudgetMath.remaining(balance, spending: spending, now: now,
                                        coverageStartDay: SuggestionRetention.utcDay(now)) != nil)
        #expect(APIBudgetMath.remaining(balance, spending: spending, now: now,
            coverageStartDay: SuggestionRetention.utcDay(now.addingTimeInterval(86_400))) == nil)
    }

    @Test func theLogCoverageStartsThirteenDaysBeforeTheFirstPass() {
        #expect(SuggestionLogPass.coverageStartDay(firstPassDay: "2027-01-20") == "2027-01-07")
        #expect(SuggestionLogPass.coverageStartDay(firstPassDay: nil) == nil)
        #expect(SuggestionLogPass.coverageStartDay(firstPassDay: "garbage") == nil)
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

    @Test func registerRevealAndDeleteAlwaysAuthenticate() async throws {
        // Auth failure must stop all three operations before any Keychain call (audit B-06).
        let store = MemoryKeychainItemStore()
        let authenticator = CountingAuthenticator()
        await authenticator.failAuthentication()
        let vault = KeychainAPIKeyVault(store: store, authenticator: authenticator)
        #expect((try? await vault.register(vendor: .anthropic, nickname: "n", key: "k")) == nil)
        #expect((try? await vault.reveal(id: "anthropic:\(UUID().uuidString)")) == nil)
        do { try await vault.delete(id: "anthropic:\(UUID().uuidString)"); #expect(false) }
        catch { #expect(error as? APIKeyVaultError == .authenticationFailed) }
        #expect(store.callCount == 0)
    }

    @Test func listNeverReturnsKeyMaterial() async throws {
        let store = MemoryKeychainItemStore()
        let vault = KeychainAPIKeyVault(store: store, authenticator: CountingAuthenticator())
        let entry = try await vault.register(
            vendor: .anthropic, nickname: "work", key: "sk-secret-test-1234")
        let listed = try await vault.list()
        #expect(listed.map(\.id) == [entry.id])
        #expect(listed.first?.nickname == "work")
        #expect(listed.first?.last4 == "1234")
        #expect(listed.description.contains("sk-secret-test-1234") == false)
        #expect(store.storedLabel(for: entry.id)?.contains("sk-secret-test-1234") == false)
    }

    @Test func aCorruptLabelIsReportedNotDropped() async throws {
        let store = MemoryKeychainItemStore()
        let vault = KeychainAPIKeyVault(store: store, authenticator: CountingAuthenticator())
        let entry = try await vault.register(
            vendor: .openai, nickname: "mine", key: "sk-x")
        store.corruptLabel(of: entry.id)
        let listed = try await vault.list()
        #expect(listed.count == 1)
        #expect(listed[0].isUnreadable)
        #expect(listed[0].nickname == String(entry.id.suffix(4)))
        try await vault.delete(id: entry.id)
        #expect(try await vault.list().isEmpty)
    }

    @Test func malformedIdsAreRejected() async throws {
        let vault = KeychainAPIKeyVault(store: MemoryKeychainItemStore(),
                                      authenticator: CountingAuthenticator())
        for id in ["", "nope", "anthropic:", ":\(UUID())", "claude:\(UUID().uuidString)"] {
            #expect((try? await vault.reveal(id: id)) == nil)
            do { try await vault.delete(id: id); #expect(false, "id accepted: \(id)") }
            catch { #expect(error as? APIKeyVaultError == .invalidEntry) }
        }
    }

    @Test func nicknameAndKeyBoundsAreEnforced() async throws {
        let vault = KeychainAPIKeyVault(store: MemoryKeychainItemStore(),
                                      authenticator: CountingAuthenticator())
        #expect((try? await vault.register(vendor: .openai, nickname: "   ", key: "k")) == nil)
        #expect((try? await vault.register(vendor: .openai,
                                        nickname: String(repeating: "n", count: 81), key: "k")) == nil)
        #expect((try? await vault.register(vendor: .openai, nickname: "ok", key: "")) == nil)
        #expect((try? await vault.register(vendor: .openai, nickname: "ok",
                                        key: String(repeating: "k", count: 16_385))) == nil)
        let entry = try await vault.register(vendor: .openai, nickname: "ok",
                                             key: String(repeating: "k", count: 16_384))
        #expect(entry.nickname == "ok")
    }

    @Test func adminEntriesRoundTripAndAreFlagged() async throws {
        let store = MemoryKeychainItemStore()
        let vault = KeychainAPIKeyVault(store: store, authenticator: CountingAuthenticator())
        let admin = try await vault.register(vendor: .anthropic, nickname: "billing",
                                             key: "sk-ant-admin-abc", admin: true)
        let regular = try await vault.register(vendor: .anthropic, nickname: "work",
                                               key: "sk-ant-key")
        #expect(admin.isAdmin)
        #expect(!regular.isAdmin)
        #expect(admin.id.hasPrefix("admin:anthropic:"))
        #expect(regular.id.hasPrefix("anthropic:"))
        let listed = try await vault.list()
        #expect(listed.count == 2)
        #expect(listed.first { $0.id == admin.id }?.isAdmin == true)
        #expect(listed.first { $0.id == regular.id }?.isAdmin == false)
        // Unreadable admin labels still surface as admin (they stay deletable).
        store.corruptLabel(of: admin.id)
        #expect(try await vault.list().first { $0.id == admin.id }?.isAdmin == true)
    }

    @Test func revealUnattendedReadsOnlyAdminEntries() async throws {
        let store = MemoryKeychainItemStore()
        let authenticator = CountingAuthenticator()
        let vault = KeychainAPIKeyVault(store: store, authenticator: authenticator)
        let admin = try await vault.register(vendor: .openai, nickname: "billing",
                                             key: "sk-admin-secret", admin: true)
        let regular = try await vault.register(vendor: .openai, nickname: "work",
                                               key: "sk-regular")
        let callsBefore = await authenticator.callCount
        // Admin read: value returned, no extra authentication round.
        #expect(try await vault.revealUnattended(id: admin.id) == "sk-admin-secret")
        #expect(await authenticator.callCount == callsBefore)
        // A regular key can never go through the unattended path.
        do {
            _ = try await vault.revealUnattended(id: regular.id)
            #expect(false)
        } catch {
            #expect(error as? APIKeyVaultError == .invalidEntry)
        }
        // Malformed or foreign ids are equally rejected.
        for id in ["", "nope", "admin:", "admin:openai:", "admin:claude:\(UUID().uuidString)"] {
            do {
                _ = try await vault.revealUnattended(id: id)
                #expect(false, "id accepted: \(id)")
            } catch {
                #expect(error as? APIKeyVaultError == .invalidEntry)
            }
        }
        // Delete still authenticates for both entry kinds.
        await authenticator.failAuthentication()
        do { try await vault.delete(id: admin.id); #expect(false) }
        catch { #expect(error as? APIKeyVaultError == .authenticationFailed) }
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

/// In-memory `KeychainItemStore`: same query shapes, no real Keychain (audit B-06).
private final class MemoryKeychainItemStore: KeychainItemStore, @unchecked Sendable {
    private var items: [String: [String: Any]] = [:]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
        guard let account = query[kSecAttrAccount as String] as? String else { return errSecParam }
        items[account] = query
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
        if query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
           let account = query[kSecAttrAccount as String] as? String {
            guard let item = items[account] else { return (errSecItemNotFound, nil) }
            if query[kSecReturnData as String] as? Bool == true {
                let data = item[kSecValueData as String] as? Data
                return (errSecSuccess, data as CFTypeRef?)
            }
            return (errSecSuccess, item as CFDictionary)
        }
        if items.isEmpty { return (errSecItemNotFound, nil) }
        return (errSecSuccess, Array(items.values) as CFArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
        guard let account = query[kSecAttrAccount as String] as? String else { return errSecParam }
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }

    func corruptLabel(of account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account]?[kSecAttrLabel as String] = "not-json"
    }

    func storedLabel(for account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[account]?[kSecAttrLabel as String] as? String
    }
}
