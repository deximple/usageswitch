import Foundation
import Testing
@testable import SwitcherCore

private func row(_ provider: UsageProvider, _ id: String,
                 state: UsageState = .ok) -> AccountUsage {
    AccountUsage(id: id, provider: provider, accountRef: "r", label: "L",
                 plan: nil, windows: [], state: state, readAt: Date(), toolVersion: nil)
}
private func inst(_ p: UsageProvider) -> UsageInstallation {
    UsageInstallation(provider: p, cli: URL(fileURLWithPath: "/bin/\(p.rawValue)"), app: nil)
}

/// Thread-safe test recorder (no unchecked unlocked mutation).
private actor Rec {
    var calls: [UsageProvider] = []
    var callbacks: [UsageProvider] = []
    var inFlight = 0
    var peak = 0
    func call(_ p: UsageProvider) { calls.append(p) }
    func callback(_ p: UsageProvider) { callbacks.append(p) }
    func enter() { inFlight += 1; peak = max(peak, inFlight) }
    func leave() { inFlight -= 1 }
}

@Suite("Usage collection scheduling")
struct UsageCollectionTests {
    private let all = Set(UsageProvider.allCases)

    @Test("absent providers invoke no collector and no callback")
    func absent() async {
        let rec = Rec()
        let out = await UsageCollection.collect(
            installations: [inst(.claude)], enabledProviders: all,
            collector: { i in await rec.call(i.provider); return [row(i.provider, "x")] },
            didCollect: { p, _ in await rec.callback(p) })
        #expect(out.count == 1)
        let calls = await rec.calls; let cbs = await rec.callbacks
        #expect(calls == [.claude] && cbs == [.claude])
    }

    @Test("exact flattened allCases order, dedup'd, from reversed/duplicate inventory")
    func order() async {
        var reversedDup = UsageProvider.allCases.reversed().map { inst($0) }
        reversedDup += UsageProvider.allCases.map { inst($0) } // duplicates must not double-row
        let out = await UsageCollection.collect(
            installations: reversedDup, enabledProviders: all,
            collector: { i in [row(i.provider, "\(i.provider.rawValue):x")] },
            didCollect: { _, _ in })
        #expect(out.map { $0.provider } == UsageProvider.allCases)
    }

    @Test("unconsented provider emits placeholder via callback without any collector call")
    func placeholder() async {
        let rec = Rec()
        let out = await UsageCollection.collect(
            installations: [inst(.grok)], enabledProviders: [],
            collector: { i in await rec.call(i.provider); return [] },
            didCollect: { p, _ in await rec.callback(p) })
        let callsEmpty = await rec.calls.isEmpty
        #expect(callsEmpty)
        #expect(out.count == 1 && out[0].id == "grok:current" && out[0].accountRef == "current")
        #expect(out[0].state == .unavailable(.connectionRequired))
        let cbs = await rec.callbacks
        #expect(cbs == [.grok]) // placeholder also reports through didCollect
    }

    @Test("placeholder ids match each real collector's row ids, Cursor especially")
    func stableIDs() {
        let c = UsageCollection.connectionRequired(.cursor)
        #expect(c.id == CursorUsageCollector.rowID && c.accountRef == CursorUsageCollector.rowAccountRef)
        for p in [UsageProvider.grok, .gemini, .antigravity, .devin, .opencode] {
            let ph = UsageCollection.connectionRequired(p)
            #expect(ph.id == "\(p.rawValue):current" && ph.accountRef == "current")
        }
    }

    @Test("continuous refill: provider four starts before a stalled first job finishes")
    func refill() async {
        let gate = Gate(); let rec = Rec()
        // claude stalls on a gate that gemini (provider 4) opens — if refill were
        // batch-of-3, gemini could never start and the test would time out.
        let out = await withTimeout(15) {
            await UsageCollection.collect(
                installations: [inst(.claude), inst(.codex), inst(.cursor), inst(.grok)],
                enabledProviders: self.all,
                collector: { i in
                    await rec.call(i.provider)
                    await rec.enter()
                    if i.provider == .claude { await gate.wait() }
                    if i.provider == .grok { await gate.open() }
                    await rec.leave()
                    return [row(i.provider, "x")]
                },
                didCollect: { p, _ in await rec.callback(p) })
        }
        #expect(out != nil)
        let calls = await rec.calls
        let peak = await rec.peak
        #expect(calls.contains(.grok))          // provider 4 ran in a refilled slot
        #expect(peak > 1 && peak <= UsageCollection.maxConcurrent)
    }

    @Test("cancelled task suppresses pending jobs and callbacks")
    func cancelled() async {
        let rec = Rec()
        let gate = Gate()
        let task = Task {
            await gate.wait()
            return await UsageCollection.collect(
                installations: UsageProvider.allCases.map { inst($0) },
                enabledProviders: all,
                collector: { i in await rec.call(i.provider); return [row(i.provider, "x")] },
                didCollect: { p, _ in await rec.callback(p) })
        }
        task.cancel()
        await gate.open()
        _ = await task.value
        #expect(await rec.calls.isEmpty)
        #expect(await rec.callbacks.isEmpty)
    }

    @Test("enabled consent-required provider does call its collector")
    func enabled() async {
        let rec = Rec()
        let out = await UsageCollection.collect(
            installations: [inst(.grok)], enabledProviders: [.grok],
            collector: { i in await rec.call(i.provider); return [row(i.provider, "g")] },
            didCollect: { _, _ in })
        let calls = await rec.calls
        #expect(calls == [.grok] && out.count == 1)
    }

    @Test("Antigravity collection is held until explicit consent")
    func antigravityConsent() async {
        let rec = Rec()
        let installation = inst(.antigravity)
        let blocked = await UsageCollection.collect(
            installations: [installation], enabledProviders: [],
            collector: { i in await rec.call(i.provider); return [row(i.provider, "current")] },
            didCollect: { _, _ in })
        #expect(blocked.first?.state == .unavailable(.connectionRequired))
        #expect(blocked.first?.id == "antigravity:current")
        #expect(await rec.calls.isEmpty)

        let enabled = await UsageCollection.collect(
            installations: [installation], enabledProviders: [.antigravity],
            collector: { i in await rec.call(i.provider); return [row(i.provider, "current")] },
            didCollect: { _, _ in })
        #expect(await rec.calls == [.antigravity])
        #expect(enabled.first?.state == .ok)
    }

    @Test("replacing merges in provider order and keeps retained windows only for same login")
    func replacing() {
        let win = UsageWindow(scope: nil, durationMinutes: 300, usedPercent: 40,
                              resetsAt: Date().addingTimeInterval(3600))
        let old = AccountUsage(id: "grok:current", provider: .grok, accountRef: "r", label: "L",
                               plan: nil, windows: [win], state: .ok, readAt: Date(), toolVersion: nil,
                               authentication: .subscription, identityKey: "login-1")
        // same account, failed refresh -> previous windows retained
        let sameLogin = AccountUsage(id: "grok:current", provider: .grok, accountRef: "r", label: "L",
                                     plan: nil, windows: [], state: .failed(.network), readAt: Date(),
                                     toolVersion: nil, authentication: .subscription,
                                     identityKey: "login-1")
        let merged = UsageCollection.replacing(provider: .grok, readings: [sameLogin],
                                               in: [old, row(.gemini, "gemini:current")])
        #expect(merged.map { $0.provider } == [.grok, .gemini])
        #expect(merged[0].windows == [win])
        // changed login must NOT inherit the old account's windows
        let newLogin = AccountUsage(id: "grok:current", provider: .grok, accountRef: "r", label: "L",
                                    plan: nil, windows: [], state: .failed(.network), readAt: Date(),
                                    toolVersion: nil, authentication: .subscription,
                                    identityKey: "login-2")
        let merged2 = UsageCollection.replacing(provider: .grok, readings: [newLogin], in: [old])
        #expect(merged2[0].windows.isEmpty)
    }
}

/// Timeout helper that avoids deadlocking a RED run forever.
private func withTimeout<T: Sendable>(_ seconds: UInt64,
                                    _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await body() }
        g.addTask { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}

/// A simple async gate for controlled stall tests.
private actor Gate {
    private var isOpen = false
    func `open`() {
        isOpen = true
    }
    func wait() async {
        // poll so a cancelled caller still exits — checked continuations ignore cancellation
        while !isOpen, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@Suite("Consent settings")
struct UsageConsentSettingsTests {
    @Test("missing connections grant nothing; unknown values are ignored")
    func defaults() {
        #expect(SwitcherSettings().enabledUsageProviders.isEmpty)
        var s = SwitcherSettings()
        s.usageConnections = ["grok", "bogus-provider", "claude"]
        #expect(s.enabledUsageProviders == [.grok])
    }

    @Test("legacy cursor flag is the sole Cursor SSOT; stray cursor entry ignored")
    func cursorUnion() {
        var s = SwitcherSettings()
        s.cursorUsageEnabled = true
        #expect(s.enabledUsageProviders.contains(.cursor))
        s.usageConnections = ["cursor"]
        #expect(s.enabledUsageProviders == [.cursor])
        s.cursorUsageEnabled = false
        #expect(s.enabledUsageProviders.isEmpty)
    }

    @Test("requiresConsent is true only for the consent-required providers")
    func flags() {
        #expect(!UsageProvider.claude.requiresConsent && !UsageProvider.codex.requiresConsent)
        for p in [UsageProvider.cursor, .grok, .gemini, .antigravity, .devin, .opencode] {
            #expect(p.requiresConsent)
        }
    }

    @Test("settings JSON: old file with no field loads empty; new grants round-trip")
    func roundTrip() throws {
        let old = try JSONDecoder().decode(SwitcherSettings.self,
                                           from: #"{"language":"en"}"#.data(using: .utf8)!)
        #expect(old.usageConnections == nil && old.enabledUsageProviders.isEmpty)
        var s = SwitcherSettings()
        s.usageConnections = ["grok", "devin"]
        let back = try JSONDecoder().decode(SwitcherSettings.self,
                                            from: try JSONEncoder().encode(s))
        #expect(back.usageConnections == ["grok", "devin"])
        #expect(back.enabledUsageProviders == [.grok, .devin])
    }
}

@Suite("Transport cancellation")
struct TransportCancelTests {
    @Test("send on an already-cancelled task refuses before any network")
    func cancelledSend() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledRequestProtocol.self]
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return SystemUsageHTTPTransport(configuration: configuration).send(UsageHTTPRequest(
                url: URL(string: "https://api2.cursor.sh/x")!, method: .get, timeout: 5))
        }
        #expect(await t.value == nil)
    }
}

private final class CancelledRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Issue.record("A cancelled usage task must not create a URLSession request")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}
