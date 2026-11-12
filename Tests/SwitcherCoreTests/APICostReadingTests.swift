import Foundation
import Testing
@testable import SwitcherCore

@Suite("Admin cost reads")
struct APICostReadingTests {
    /// 2026-11-13 12:00 UTC — month has 13 reported days so far.
    private let now = Date(timeIntervalSince1970: 1_794_571_200)

    private func reader(http: SpyTransport) -> APICostReader {
        APICostReader(http: http, now: { self.now })
    }

    private func anthropicBucket(day: String, cents: String) -> String {
        #"{"starting_at":"2026-11-\#(day)T00:00:00Z","ending_at":"2026-11-\#(day)T23:59:59Z","# +
        #""results":[{"amount":"\#(cents)","currency":"USD","cost_type":"tokens"}]}"#
    }

    private func openAIBucket(unixStart: Double, usd: Any) -> String {
        let value = (usd as? String).map { "\"\($0)\"" } ?? "\(usd)"
        return #"{"start_time":\#(unixStart),"end_time":\#(unixStart + 86400),"# +
            #""results":[{"amount":{"value":\#(value),"currency":"usd"},"line_item":null}]}"#
    }

    // 2026-11-01T00:00:00Z = 1793491200; day N = 1793491200 + (N-1)*86400
    private func unixDay(_ n: Int) -> Double { 1_793_491_200 + Double(n - 1) * 86400 }

    @Test("Anthropic buckets sum into month-to-date and last-7 totals")
    func anthropicSums() {
        let http = SpyTransport()
        var buckets = ""
        // 13 days in month: days 1-6 = 100c each (outside last-7), days 7-13 = 50c each.
        for day in 1...13 {
            if day > 1 { buckets += "," }
            buckets += anthropicBucket(day: String(format: "%02d", day),
                                       cents: day <= 6 ? "100.00" : "50.00")
        }
        http.queue = [UsageHTTPResponse(status: 200,
            body: Data(#"{"data":[\#(buckets)],"has_more":false,"next_page":null}"#.utf8))]
        let state = reader(http: http).read(vendor: .anthropic, key: "sk-ant-admin-x")
        guard case .ok(let spend) = state else { Issue.record("state: \(state)"); return }
        #expect(spend.monthToDateUSD == 9.5)   // 6×$1.00 + 7×$0.50
        #expect(spend.last7DaysUSD == 3.5)     // days 7-13
        #expect(spend.asOf == now)
        let request = http.requests.first
        #expect(request?.url.host == "api.anthropic.com")
        #expect(request?.url.path == "/v1/organizations/cost_report")
        #expect(request?.headers["Authorization"] == "Bearer sk-ant-admin-x")
        #expect(request?.headers["anthropic-version"] == "2023-06-01")
        #expect(request?.url.query?.contains("bucket_width=1d") == true)
    }

    @Test("OpenAI buckets sum with USD amounts, numeric or string")
    func openAISums() {
        let http = SpyTransport()
        var buckets = ""
        for day in 1...13 {
            if day > 1 { buckets += "," }
            // mix numeric and string values — both must parse
            let amount: Any = day <= 6 ? 2.0 : "1.50"
            buckets += openAIBucket(unixStart: unixDay(day), usd: amount)
        }
        http.queue = [UsageHTTPResponse(status: 200,
            body: Data(#"{"object":"page","data":[\#(buckets)],"has_more":false,"next_page":null}"#.utf8))]
        let state = reader(http: http).read(vendor: .openai, key: "sk-admin-x")
        guard case .ok(let spend) = state else { Issue.record("state: \(state)"); return }
        #expect(spend.monthToDateUSD == 22.5)  // 6×$2.00 + 7×$1.50
        #expect(spend.last7DaysUSD == 10.5)
        let request = http.requests.first
        #expect(request?.url.host == "api.openai.com")
        #expect(request?.url.path == "/v1/organization/costs")
        #expect(request?.url.query?.contains("start_time=1793491200") == true)
    }

    @Test("empty month is a real zero, not a missing figure")
    func emptyMonth() {
        for vendor in [APIVendor.anthropic, .openai] {
            let http = SpyTransport()
            let body = vendor == .anthropic ? #"{"data":[],"has_more":false}"#
                                            : #"{"object":"page","data":[]}"#
            http.queue = [UsageHTTPResponse(status: 200, body: Data(body.utf8))]
            let state = reader(http: http).read(vendor: vendor, key: "k")
            guard case .ok(let spend) = state else { Issue.record("\(vendor): \(state)"); continue }
            #expect(spend.monthToDateUSD == 0)
            #expect(spend.last7DaysUSD == 0)
        }
    }

    @Test("status mapping is identical for both vendors")
    func statusMapping() {
        for vendor in [APIVendor.anthropic, .openai] {
            for (status, expected) in [(401, APICostReadState.keyRejected),
                                       (403, .notEligible), (429, .rateLimited), (500, .network)] {
                let http = SpyTransport()
                http.queue = [UsageHTTPResponse(status: status, body: Data("{}".utf8))]
                #expect(reader(http: http).read(vendor: vendor, key: "k") == expected,
                        "\(vendor) status \(status)")
            }
        }
    }

    @Test("schema deviations fail closed for both vendors")
    func schemaBreaks() {
        let cases: [(APIVendor, String)] = [
            (.anthropic, #"{"data":"nope"}"#),
            (.anthropic, #"{"data":[{"starting_at":"x","results":[{"currency":"USD"}]}]}"#),
            (.anthropic, #"{"data":[{"starting_at":"x","results":[{"amount":"abc"}]}]}"#),
            (.openai, #"{"data":[{"start_time":1,"results":[{"amount":{"value":"oops"}}]}]}"#),
            (.openai, #"{"data":[{"start_time":1,"results":"oops"}]}"#),
        ]
        for (vendor, json) in cases {
            let http = SpyTransport()
            http.queue = [UsageHTTPResponse(status: 200, body: Data(json.utf8))]
            #expect(reader(http: http).read(vendor: vendor, key: "k") == .schemaChanged,
                    "\(vendor) \(json)")
        }
    }

    @Test("google and xai have no billing path and never request anything")
    func unsupportedVendors() {
        let http = SpyTransport()
        #expect(reader(http: http).read(vendor: .google, key: "k") == .schemaChanged)
        #expect(reader(http: http).read(vendor: .xai, key: "k") == .schemaChanged)
        #expect(http.requests.isEmpty)
    }
}
