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

    @Test("no token anywhere is noSignIn; 401 and 403 are too")
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
            #expect(usage?.state == .unavailable(.noSignIn))
        }
    }

    @Test("split pools give Auto and API windows for the billing month")
    func splitPools() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorSplit)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.count == 2)
        #expect(usage?.windows.map(\.scope) == ["Auto", "API"])
        #expect(usage?.windows.map(\.usedPercent) == [42.5, 7])
        #expect(usage?.windows.first?.kind == .monthly)
        #expect(usage?.windows.first?.durationMinutes == 43200)
        #expect(usage?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_769_817_600))
        #expect(fake.calls.count == 2)
        #expect(fake.calls[0].absoluteString == "https://api.test/\(usagePath)")
        #expect(fake.calls[1].absoluteString == "https://api.test/\(planPath)")
    }

    @Test("a merged plan reports one window from the total")
    func mergedPlan() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorMergedUsage, planInfo: UsageFixture.cursorMergedPlanInfo)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .ok)
        #expect(usage?.windows.count == 1)
        #expect(usage?.windows.first?.scope == nil)
        #expect(usage?.windows.first?.usedPercent == 61)
    }

    @Test("a reversed billing cycle gives no duration but keeps the reset")
    func reversedCycle() {
        let body = Data(#"{"billingCycleStart":"1769817600000","billingCycleEnd":"1767225600000","planUsage":{"totalPercentUsed":50}}"#.utf8)
        let windows = CursorUsageParser.windows(usage: body, merged: nil)
        #expect(windows?.count == 1)
        #expect(windows?.first?.durationMinutes == nil)
        #expect(windows?.first?.resetsAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("no percentages reported is notReporting")
    func none() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = fakeHTTP(usage: UsageFixture.cursorNoPercentages)
        let usage = collector(home: home, runner: fakeRunner(keychainToken: "tok"), http: fake).collect().first
        #expect(usage?.state == .notReporting)
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
