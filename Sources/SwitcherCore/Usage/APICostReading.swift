import Foundation

/// An organization-level actual spend read, produced only by an admin billing key —
/// never by a request-capable API key. Amounts are USD as reported by the vendor's
/// billing endpoint, summed over complete daily buckets.
public struct APIActualSpend: Equatable, Sendable {
    /// Sum of this calendar month's daily cost buckets (UTC), partial month included.
    public let monthToDateUSD: Double
    /// Sum of the last 7 daily buckets (UTC), today included when the vendor has reported it.
    public let last7DaysUSD: Double
    /// When this read was taken — displayed so a cached figure never looks live.
    public let asOf: Date

    public init(monthToDateUSD: Double, last7DaysUSD: Double, asOf: Date) {
        self.monthToDateUSD = monthToDateUSD
        self.last7DaysUSD = last7DaysUSD
        self.asOf = asOf
    }
}

/// Terminal states for a billing read: mapped, never fabricated.
public enum APICostReadState: Equatable, Sendable {
    case ok(APIActualSpend)
    /// 401 — the stored admin key was rejected; the user must rotate or remove it.
    case keyRejected
    /// 403 — the key works but isn't an org admin key, or the org disallows billing reads.
    case notEligible
    case rateLimited
    case network
    case schemaChanged
}

/// Read-only billing queries for Anthropic and OpenAI admin keys. Both calls are free
/// metadata reads — they never create paid requests. Google/xAI stay estimators only:
/// no simple balance endpoint exists for them.
public struct APICostReader: Sendable {
    private let http: any UsageHTTPTransport
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(http: any UsageHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http; self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        self.calendar = calendar
    }

    public func read(vendor: APIVendor, key: String) -> APICostReadState {
        switch vendor {
        case .anthropic: return readAnthropic(key: key)
        case .openai: return readOpenAI(key: key)
        // No supported billing endpoint — never fabricate one.
        case .google, .xai: return .schemaChanged
        }
    }

    private func monthBounds() -> (start: Date, sevenDaysAgo: Date) {
        let current = now()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: current))!
        let startOfToday = calendar.startOfDay(for: current)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        return (startOfMonth, sevenDaysAgo)
    }

    private func send(_ request: UsageHTTPRequest) -> UsageHTTPResponse? { http.send(request) }

    private static func statusMap(_ status: Int) -> APICostReadState? {
        switch status {
        case 200: return nil
        case 401: return .keyRejected
        case 403: return .notEligible
        case 429: return .rateLimited
        default: return .network
        }
    }

    // MARK: - Anthropic

    /// GET /v1/organizations/cost_report — daily buckets, `amount` in cents as a decimal string.
    private func readAnthropic(key: String) -> APICostReadState {
        let (monthStart, sevenDaysAgo) = monthBounds()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var components = URLComponents(url: URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: monthStart)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        let request = UsageHTTPRequest(url: components.url!, method: .get,
            headers: ["Authorization": "Bearer \(key)",
                      "anthropic-version": "2023-06-01",
                      "Content-Type": "application/json"],
            timeout: 10)
        guard let r = send(request) else { return .network }
        if let failure = Self.statusMap(r.status) { return failure }
        guard let root = UsageJSON.object(r.body),
              let buckets = root["data"] as? [[String: Any]] else { return .schemaChanged }

        var monthTotal = 0.0
        var weekTotal = 0.0
        for bucket in buckets {
            guard let rawResults = bucket["results"] as? [[String: Any]] else { return .schemaChanged }
            var dayTotal = 0.0
            for item in rawResults {
                // `amount` is a decimal string in cents (lowest units of `currency` USD).
                guard let amountString = UsageJSON.string(item["amount"]),
                      let cents = Double(amountString),
                      cents.isFinite, cents >= 0 else { return .schemaChanged }
                dayTotal += cents / 100
            }
            monthTotal += dayTotal
            // Buckets are RFC 3339 day starts; only the last-7 window counts toward the week.
            if let rawStart = bucket["starting_at"],
               let start = UsageJSON.resetDateISO(rawStart), start >= sevenDaysAgo {
                weekTotal += dayTotal
            }
        }
        return .ok(APIActualSpend(monthToDateUSD: monthTotal, last7DaysUSD: weekTotal, asOf: now()))
    }

    // MARK: - OpenAI

    /// GET /v1/organization/costs — daily buckets, `amount.value` already in USD.
    private func readOpenAI(key: String) -> APICostReadState {
        let (monthStart, sevenDaysAgo) = monthBounds()
        var components = URLComponents(url: URL(string: "https://api.openai.com/v1/organization/costs")!,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(monthStart.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        let request = UsageHTTPRequest(url: components.url!, method: .get,
            headers: ["Authorization": "Bearer \(key)"],
            timeout: 10)
        guard let r = send(request) else { return .network }
        if let failure = Self.statusMap(r.status) { return failure }
        guard let root = UsageJSON.object(r.body),
              let buckets = root["data"] as? [[String: Any]] else { return .schemaChanged }

        var monthTotal = 0.0
        var weekTotal = 0.0
        for bucket in buckets {
            guard let rawResults = bucket["results"] as? [[String: Any]] else { return .schemaChanged }
            var dayTotal = 0.0
            for item in rawResults {
                guard let amount = item["amount"] as? [String: Any],
                      let value = (amount["value"] as? Double)
                        ?? (amount["value"] as? Int).map(Double.init)
                        ?? UsageJSON.string(amount["value"]).flatMap(Double.init),
                      value.isFinite, value >= 0 else { return .schemaChanged }
                dayTotal += value
            }
            monthTotal += dayTotal
            if let startTime = bucket["start_time"] as? Double,
               Date(timeIntervalSince1970: startTime) >= sevenDaysAgo {
                weekTotal += dayTotal
            }
        }
        return .ok(APIActualSpend(monthToDateUSD: monthTotal, last7DaysUSD: weekTotal, asOf: now()))
    }
}
