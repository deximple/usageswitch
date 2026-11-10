import Foundation
import Testing
@testable import SwitcherCore

@Suite("Cursor usage")
struct CursorUsageTests {
    let endpoint = URL(string: "https://api.test")!
    let usagePath = "aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    let planPath = "aiserver.v1.DashboardService/GetPlanInfo"

    func tempHome(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("us-tests-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func collector(enabled: Bool = true, home: URL, runner: FakeUsageRunner, http: FakeUsageHTTP) -> CursorUsageCollector {
        CursorUsageCollector(enabled: enabled, runner: runner, http: http, home: home,
                             endpoint: endpoint, now: { Date(timeIntervalSince1970: 1_780_000_000) })
    }

    /// Runner that answers /usr/bin/security with a token (or fails), nothing else.
    func fakeRunner(keychainToken: String?) -> FakeUsageRunner {
        let runner = FakeUsageRunner()
        runner.respond = { _ in
            if let keychainToken {
                return UsageProcessResult(lines: [keychainToken], outcome: .exited(0))
            }
            return UsageProcessResult(lines: [], outcome: .exited(1))
        }
        return runner
    }

    func fakeHTTP(usage: String?, planInfo: String? = nil, status: Int = 200) -> FakeUsageHTTP {
        let fake = FakeUsageHTTP()
        fake.respond = { url in
            if url.path.hasSuffix("GetCurrentPeriodUsage") {
                guard let usage else { return nil }
                return (status: status, body: Data(usage.utf8))
            }
            guard let planInfo else { return nil }
            return (status: 200, body: Data(planInfo.utf8))
        }
        return fake
    }

    @Test("disabled means no Keychain read and no request at all")
    func disabled() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(keychainToken: "tok")
        let fake = fakeHTTP(usage: UsageFixture.cursorSplit)
        #expect(collector(enabled: false, home: home, runner: runner, http: fake).collect() == [])
        #expect(runner.requests.isEmpty)
        #expect(fake.calls.isEmpty)
    }

    @Test("the token comes from /usr/bin/security first")
    func keychainToken() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(keychainToken: "tok-1")
        let fake = fakeHTTP(usage: UsageFixture.cursorSplit)
        let usage = collector(home: home, runner: runner, http: fake).collect().first
        #expect(usage?.state == .ok)
        let security = try #require(runner.requests.first)
        #expect(security.executable.path == "/usr/bin/security")
        #expect(security.arguments == ["find-generic-password", "-a", "cursor-user", "-s", "cursor-access-token", "-w"])
        #expect(security.timeout == 3)
    }

    @Test("falls back to ~/.cursor/auth.json when Keychain has nothing")
    func authFileFallback() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        try Data(#"{"accessToken":"file-tok"}"#.utf8).write(to: cursor.appendingPathComponent("auth.json"))
        let runner = fakeRunner(keychainToken: nil)
        let fake = fakeHTTP(usage: UsageFixture.cursorTotalOnly)
        let usage = collector(home: home, runner: runner, http: fake).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.count == 1)
    }

    @Test("no token is noSignIn; rejected credentials are sign-in rejections")
    func noSignIn() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(keychainToken: nil)
        var fake = fakeHTTP(usage: UsageFixture.cursorSplit)
        var usage = collector(home: home, runner: runner, http: fake).collect().first
        #expect(usage?.state == .unavailable(.noSignIn))
        #expect(fake.calls.isEmpty) // never asked: no token to send
        for code in [401, 403] {
            fake = fakeHTTP(usage: UsageFixture.cursorSplit, status: code)
            usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
            #expect(usage?.state == .failed(.signInRejected))
            #expect(usage?.windows.isEmpty == true)
        }
    }

    @Test("a split response reports the unscoped total and scoped Auto/API windows")
    func splitPools() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // planInfo is supplied on purpose: GetPlanInfo must never be invoked.
        let fake = fakeHTTP(usage: UsageFixture.cursorSplit, planInfo: UsageFixture.cursorMergedPlanInfo)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .ok)
        let windows = try #require(usage?.windows)
        #expect(windows.map(\.scope) == [nil, CursorUsageParser.cursorModelsScope, CursorUsageParser.otherModelsScope])
        #expect(windows.map(\.usedPercent) == [30, 42.5, 7])
        #expect(windows.allSatisfy { $0.kind == .monthly })
        #expect(windows.allSatisfy { $0.durationMinutes == 43200 })
        #expect(windows.allSatisfy { $0.resetsAt == Date(timeIntervalSince1970: 1_769_817_600) })
        #expect(fake.calls.count == 1)
        #expect(fake.calls[0].absoluteString == "https://api.test/\(usagePath)")
    }

    @Test("a missing split omits only its window")
    func missingSplit() {
        let body = Data(#"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{"autoPercentUsed":42,"totalPercentUsed":30}}"#.utf8)
        let windows = CursorUsageParser.windows(usage: body)
        #expect(windows?.map(\.scope) == [nil, CursorUsageParser.cursorModelsScope])
        #expect(windows?.map(\.usedPercent) == [30, 42])
    }

    @Test("the plan total is reported regardless of the merged hint")
    func mergedPlan() throws {
        for merged in [true, false] as [Bool?] + [nil] {
            let body = Data(UsageFixture.cursorMergedUsage.utf8)
            let windows = CursorUsageParser.windows(usage: body, merged: merged)
            #expect(windows?.count == 1)
            #expect(windows?.first?.scope == nil)
            #expect(windows?.first?.usedPercent == 61)
        }
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorMergedUsage, planInfo: UsageFixture.cursorMergedPlanInfo)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.count == 1)
        #expect(usage?.windows.first?.scope == nil)
        #expect(usage?.windows.first?.usedPercent == 61)
        #expect(fake.calls.count == 1)
    }

    @Test("split values without a total yield nothing — no sum, no inferred pool")
    func splitOnlyNoTotal() throws {
        for total in ["", #""totalPercentUsed":null"#] {
            let plan = #"{"autoPercentUsed":42,"apiPercentUsed":7"#
                + (total.isEmpty ? "" : ",\(total)") + "}"
            let body = Data(#"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":\#(plan)}"#.utf8)
            // Structurally valid JSON — the nil below is semantic, not decode failure.
            #expect(try JSONSerialization.jsonObject(with: body) as? [String: Any] != nil)
            #expect(CursorUsageParser.windows(usage: body, merged: nil) == nil)
            #expect(CursorUsageParser.windows(usage: body, merged: true) == nil)
        }
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let splitOnly = #"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{"autoPercentUsed":42,"apiPercentUsed":7}}"#
        let fake = fakeHTTP(usage: splitOnly)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .notReporting)
        #expect(usage?.windows.isEmpty == true)
    }

    @Test("collected Cursor usage snapshots the total and scoped Auto/API windows")
    func snapshotWindows() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorSplit)
        let usage = try #require(collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first)
        let p = UsageAccountPresentation(usage: usage, name: usage.label, email: nil,
                                         environment: .cli, login: .unknown,
                                         badgeActive: false, owner: nil)
        let snap = UsageSnapshot(presentations: [p], generatedAt: usage.readAt)
        let account = snap.accounts[0]
        #expect(account.id == "cursor:cursor" && account.provider == "cursor")
        #expect(account.windows.map(\.scope) == [nil, CursorUsageParser.cursorModelsScope, CursorUsageParser.otherModelsScope])
        #expect(account.windows.map(\.usedPercent) == [30, 42.5, 7])
        #expect(account.windows[0].leftPercent == 70)
    }

    @Test("a reversed billing cycle gives no duration but keeps the reset")
    func reversedCycle() {
        let body = Data(#"{"billingCycleStart":"1769817600000","billingCycleEnd":"1767225600000","planUsage":{"totalPercentUsed":50}}"#.utf8)
        let windows = CursorUsageParser.windows(usage: body, merged: nil)
        #expect(windows?.count == 1)
        #expect(windows?.first?.durationMinutes == nil)
        #expect(windows?.first?.resetsAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("int64-extreme billing cycles reject rather than trap on overflow")
    func billingOverflow() throws {
        func body(_ start: String?, _ end: String?) -> Data {
            var fields = ""
            if let start { fields += #""billingCycleStart":"\#(start)""# }
            if let end { fields += (fields.isEmpty ? "" : ",") + #""billingCycleEnd":"\#(end)""# }
            return Data(#"{\#(fields),"planUsage":{"totalPercentUsed":30}}"#.utf8)
        }
        // Structurally valid JSON with legal int64 strings — arithmetic overflow
        // must reject the whole reading, never crash or invent a duration.
        let extreme = body("-9223372036854775808", "9223372036854775807")
        #expect(try JSONSerialization.jsonObject(with: extreme) as? [String: Any] != nil)
        #expect(CursorUsageParser.windows(usage: extreme, merged: nil) == nil)
        // Reverse extremes overflow identically.
        let reverse = body("9223372036854775807", "-9223372036854775808")
        #expect(try JSONSerialization.jsonObject(with: reverse) as? [String: Any] != nil)
        #expect(CursorUsageParser.windows(usage: reverse, merged: nil) == nil)
        // Missing boundary fields stay non-fatal: no duration, reset only when end exists.
        let noStart = body(nil, "1769817600000")
        #expect(CursorUsageParser.windows(usage: noStart, merged: nil)?.first?.durationMinutes == nil)
        #expect(CursorUsageParser.windows(usage: noStart, merged: nil)?.first?.resetsAt == Date(timeIntervalSince1970: 1_769_817_600))
        let noEnd = body("1767225600000", nil)
        #expect(CursorUsageParser.windows(usage: noEnd, merged: nil)?.first?.durationMinutes == nil)
        #expect(CursorUsageParser.windows(usage: noEnd, merged: nil)?.first?.resetsAt == nil)
        // A normal cycle still reports duration + reset (existing behavior).
        let normal = body("1767225600000", "1769817600000")
        #expect(CursorUsageParser.windows(usage: normal, merged: nil)?.first?.durationMinutes == 43200)
    }

    @Test("no percentages reported is notReporting")
    func none() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorNoPercentages)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .notReporting)
    }

    // MARK: - Nonfinite/malformed percentage rejection

    /// Synthetic payloads only — a planUsage body builder that lets one field hold
    /// any raw JSON value while the other two stay valid.
    private func usageBody(field: String, rawValue: String) -> Data {
        var parts = ["autoPercentUsed": "42", "apiPercentUsed": "7", "totalPercentUsed": "30"]
        parts[field] = rawValue
        let plan = parts.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        return Data(#"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{\#(plan)}}"#.utf8)
    }

    @Test("invalid scoped fields are omitted without hiding the total")
    func malformedPercentages() {
        let bad = [#""NaN""#, #""nan""#, #""Infinity""#, #""-Infinity""#, #""inf""#,
                   #""1e999""#, #""-1e999""#, "true", "false", "{}", "[]"]
        for field in ["autoPercentUsed", "apiPercentUsed", "totalPercentUsed"] {
            for value in bad {
                let body = usageBody(field: field, rawValue: value)
                let windows = CursorUsageParser.windows(usage: body, merged: nil)
                if field == "totalPercentUsed" {
                    #expect(windows == nil, "\(field)=\(value)")
                } else {
                    let expectedScopes: [String?] = field == "autoPercentUsed" ? [nil, CursorUsageParser.otherModelsScope] : [nil, CursorUsageParser.cursorModelsScope]
                    let expectedPercentages = field == "autoPercentUsed" ? [30.0, 7.0] : [30.0, 42.0]
                    #expect(windows?.map(\.scope) == expectedScopes, "\(field)=\(value)")
                    #expect(windows?.map(\.usedPercent) == expectedPercentages, "\(field)=\(value)")
                }
                #expect(CursorUsageParser.windows(usage: body, merged: false) == windows,
                        "\(field)=\(value)")
                #expect(CursorUsageParser.windows(usage: body, merged: true) == windows,
                        "\(field)=\(value)")
            }
        }
    }

    @Test("missing, null and finite percentages still parse; out-of-range clamps")
    func validPercentages() {
        func body(_ plan: String) -> Data {
            Data(#"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{\#(plan)}}"#.utf8)
        }
        // A null split behaves like a missing field while the total still reports.
        let nullSplit = body(#""autoPercentUsed":42,"apiPercentUsed":null,"totalPercentUsed":30"#)
        #expect(CursorUsageParser.windows(usage: nullSplit, merged: nil)?.map(\.scope) == [nil, CursorUsageParser.cursorModelsScope])
        #expect(CursorUsageParser.windows(usage: nullSplit, merged: nil)?.map(\.usedPercent) == [30, 42])
        // Boundaries and numeric strings/fractions pass through unchanged.
        let edges = body(#""autoPercentUsed":0,"apiPercentUsed":"55.5","totalPercentUsed":100"#)
        #expect(CursorUsageParser.windows(usage: edges, merged: nil)?.map(\.usedPercent) == [100, 0, 55.5])
        // Out-of-range percentages are a schema change: nothing is shown (audit B-11).
        let clampedBody = body(#""autoPercentUsed":-5,"apiPercentUsed":7,"totalPercentUsed":105"#)
        #expect(CursorUsageParser.windows(usage: clampedBody, merged: nil) == nil)
        let clampedLow = body(#""totalPercentUsed":-5"#)
        #expect(CursorUsageParser.windows(usage: clampedLow, merged: nil) == nil)
        let mergedClamped = body(#""autoPercentUsed":-5,"apiPercentUsed":7,"totalPercentUsed":"105""#)
        #expect(CursorUsageParser.windows(usage: mergedClamped, merged: true) == nil)
    }

    @Test("an invalid Auto value omits that window but keeps the total and API")
    func malformedCollector() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let badUsage = #"{"billingCycleStart":"1767225600000","billingCycleEnd":"1769817600000","planUsage":{"autoPercentUsed":"NaN","apiPercentUsed":7,"totalPercentUsed":30}}"#
        // Prove the payload is structurally valid JSON — the rejection below is
        // the percentage validation, not a decode failure.
        #expect(try JSONSerialization.jsonObject(with: Data(badUsage.utf8)) as? [String: Any] != nil)
        let fake = fakeHTTP(usage: badUsage)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.map(\.scope) == [nil, CursorUsageParser.otherModelsScope])
        #expect(usage?.windows.map(\.usedPercent) == [30, 7])
    }

    @Test("other HTTP statuses and dead connections are a network failure")
    func network() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var fake = fakeHTTP(usage: UsageFixture.cursorSplit, status: 500)
        var usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .failed(.network))
        fake = fakeHTTP(usage: nil) // no response at all
        usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .failed(.network))
    }
}

@Suite("Cursor pin key migration")
struct CursorPinMigrationTests {
    @Test("legacy Auto/API pins map to dashboard pool names; others untouched; dedupes")
    func mapping() {
        let settings = SwitcherSettings(usagePins: [
            "cursor:cursor/monthly/Auto",
            "cursor:cursor/monthly/API",
            "codex:standard/monthly/API",
            "cursor:cursor/monthly/Cursor Models",
            "cursor:cursor/weekly/Auto",
        ])
        #expect(settings.effectiveUsagePins == [
            "cursor:cursor/monthly/Cursor Models",
            "cursor:cursor/monthly/Other Models",
            "codex:standard/monthly/API",
            "cursor:cursor/weekly/Cursor Models",
        ])
    }
}

extension CursorUsageTests {
    private func jwt(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(b64).s"
    }

    private func collect(_ token: String) throws -> (state: UsageState?, calls: Int) {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = fakeRunner(keychainToken: token)
        let http = fakeHTTP(usage: UsageFixture.cursorSplit)
        let state = collector(home: home, runner: runner, http: http).collect().first?.state
        return (state, http.calls.count)
    }

    @Test("expired JWT reports signInExpired and sends no request")
    func expired() throws {
        let (state, calls) = try collect(jwt(["exp": 1_779_999_000]))
        #expect(state == .unavailable(.signInExpired))
        #expect(calls == 0)
    }

    @Test("JWT expiring within 60s reports signInExpired, no request")
    func nearExpiry() throws {
        let (state, calls) = try collect(jwt(["exp": 1_780_000_030]))
        #expect(state == .unavailable(.signInExpired))
        #expect(calls == 0)
    }

    @Test("JWT expiring in 10 minutes still sends the request")
    func fresh() throws {
        let (state, calls) = try collect(jwt(["exp": 1_780_000_600]))
        #expect(state == .ok)
        #expect(calls == 1)
    }

    @Test("non-JWT, garbage payload, and exp-less payload all send the request")
    func passThrough() throws {
        for token in ["tok", "a.!!!.b", try jwt(["sub": "x"])] {
            let (_, calls) = try collect(token)
            #expect(calls == 1)
        }
    }
}
