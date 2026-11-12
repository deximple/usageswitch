import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage snapshot masking")
struct UsageSnapshotMaskTests {
    private func usage(_ label: String, state: UsageState = .ok) -> AccountUsage {
        AccountUsage(id: "codex:a", provider: .codex, accountRef: "a", label: label,
                     plan: "prolite",
                     windows: [UsageWindow(durationMinutes: 10080, usedPercent: 31,
                                           resetsAt: Date(timeIntervalSince1970: 1_794_301_834))],
                     state: state, readAt: Date(timeIntervalSince1970: 1_000_000),
                     toolVersion: "26.1", authentication: .subscription, identityKey: "x")
    }

    @Test("labels are masked on write even when showEmails is on")
    func initMasks() {
        let snap = UsageSnapshot(usages: [usage("alex.kim@example.com")], generatedAt: epoch, showEmails: true)
        #expect(!snap.accounts[0].label.contains("alex.kim@example.com"))
        #expect(snap.accounts[0].label.contains("•••"))
    }

    @Test("load re-masks snapshots written before masking-on-write")
    func loadMasks() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        let old = """
            {"generatedAt":"2026-11-04T10:00:00Z","accounts":[{"id":"codex:a","provider":"codex",
            "label":"alex.kim@example.com","plan":"prolite","state":"ok","problem":null,
            "readAt":"1970-01-12T13:46:40Z","toolVersion":"26.1",
            "windows":[{"kind":"weekly","scope":null,"durationMinutes":10080,"usedPercent":31,
            "leftPercent":69,"resetsAt":"2026-11-10T23:10:34Z"}]}]}
            """
        try old.write(to: sb.env.usageSnapshotFile, atomically: true, encoding: .utf8)
        let snap = try #require(UsageSnapshot.load(env: sb.env))
        #expect(!snap.accounts[0].label.contains("alex.kim@example.com"))
        #expect(snap.accounts[0].label.contains("•••"))
        #expect(snap.accounts[0].accountRef == "codex#1")
        // Numeric/state fields pass through untouched.
        #expect(snap.accounts[0].windows[0].usedPercent == 31)
        #expect(snap.accounts[0].windows[0].leftPercent == 69)
        #expect(snap.accounts[0].state == "ok")
        #expect(snap.accounts[0].plan == "prolite")
        // Loading is idempotent — masking again changes nothing.
        #expect(snap.masked() == snap)
    }

    @Test("missing or corrupt file loads nil")
    func loadNil() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        #expect(UsageSnapshot.load(env: sb.env) == nil)
        try sb.fs.createDirectory(sb.env.storeDir)
        try "not json".write(to: sb.env.usageSnapshotFile, atomically: true, encoding: .utf8)
        #expect(UsageSnapshot.load(env: sb.env) == nil)
    }

    private let epoch = Date(timeIntervalSince1970: 1_000_000)
}

@Suite("Codex usage identity")
struct CodexIdentityTests {
    private func collector(_ accounts: [CodexAccount], runner: FakeUsageRunner) -> CodexUsageCollector {
        CodexUsageCollector(status: { CodexStatus(installed: true, version: "1.0",
                                                accounts: accounts, found: [], hiddenCount: 0) },
                            runner: runner, codexCLI: URL(fileURLWithPath: "/usr/bin/true"),
                            workingDirectory: FileManager.default.temporaryDirectory)
    }

    private func account(_ id: String, _ mode: CodexIdentity.Mode,
                         email: String? = nil, accountId: String? = nil) -> CodexAccount {
        CodexAccount(id: id, kind: .standard, label: "L", customName: nil, defaultName: "d",
                     home: "/tmp", homePath: "/tmp",
                     identity: CodexIdentity(mode: mode, email: email, accountId: accountId),
                     state: .signedIn, pids: [])
    }

    @Test("chatgpt with accountId+email gets subscription auth and an opaque login key")
    func chatgpt() throws {
        let runner = FakeUsageRunner()
        let out = collector([account("a", .chatgpt, email: "A@B.com", accountId: "acc-1")],
                            runner: runner).collect()
        #expect(out[0].authentication == .subscription)
        let key = try #require(out[0].identityKey)
        #expect(key.count == 64)
        // Same inputs → same key; different accountId or email → different key.
        let runner2 = FakeUsageRunner()
        let same = collector([account("a", .chatgpt, email: "a@b.com", accountId: "acc-1")],
                             runner: runner2).collect()
        #expect(same[0].identityKey == key)
        let diff = collector([account("a", .chatgpt, email: "a@b.com", accountId: "acc-2")],
                             runner: FakeUsageRunner()).collect()
        #expect(diff[0].identityKey != key)
        let diffEmail = collector([account("a", .chatgpt, email: "c@d.com", accountId: "acc-1")],
                                  runner: FakeUsageRunner()).collect()
        #expect(diffEmail[0].identityKey != key)
        // The fingerprint never leaves memory: it is not in the snapshot JSON.
        let snap = UsageSnapshot(usages: out, generatedAt: Date(), showEmails: false)
        let encoded = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        #expect(!encoded.contains(key))
    }

    @Test("apiKey and unknown modes map their auth and get no key")
    func otherModes() {
        let out = collector([account("a", .apiKey), account("b", .unknown)],
                            runner: FakeUsageRunner()).collect()
        #expect(out[0].authentication == .apiKey)
        #expect(out[0].identityKey == nil)
        #expect(out[1].authentication == .unknown)
        #expect(out[1].identityKey == nil)
    }

    @Test("chatgpt missing either side of the fingerprint gets no key")
    func incomplete() {
        let out = collector([account("a", .chatgpt, email: nil, accountId: "acc-1"),
                             account("b", .chatgpt, email: "a@b.com", accountId: nil)],
                            runner: FakeUsageRunner()).collect()
        #expect(out[0].identityKey == nil)
        #expect(out[1].identityKey == nil)
    }
}

@Suite("Retained windows after a failed re-read")
struct RetainingWindowsTests {
    private let reset = Date().addingTimeInterval(86400)
    private func usage(_ state: UsageState, id: String = "codex:a",
                       auth: UsageAuthentication = .subscription, key: String? = "k1",
                       windows: [UsageWindow] = [], plan: String? = nil,
                       readAgo: TimeInterval = 0) -> AccountUsage {
        AccountUsage(id: id, provider: .codex, accountRef: "a", label: "L", plan: plan,
                     windows: windows, state: state, readAt: Date().addingTimeInterval(-readAgo),
                     toolVersion: "1", authentication: auth, identityKey: key)
    }
    private var wins: [UsageWindow] { [UsageWindow(durationMinutes: 300, usedPercent: 50, resetsAt: reset)] }

    @Test("same subscription identity keeps windows + readAt, marked failed")
    func retained() {
        let prev = usage(.ok, windows: wins, plan: "team", readAgo: 300)
        let fresh = usage(.failed(.timeout), plan: nil)
        let out = fresh.retainingWindows(from: prev, now: Date())
        #expect(out.windows.count == 1 && out.readAt == prev.readAt && out.state == .failed(.timeout))
        #expect(out.plan == "team")
    }

    @Test("changed identity or auth mode never keeps previous windows")
    func changed() {
        let prev = usage(.ok, windows: wins)
        #expect(usage(.failed(.timeout), key: "k2").retainingWindows(from: prev, now: Date()).windows.isEmpty)
        #expect(usage(.failed(.timeout), auth: .apiKey).retainingWindows(from: prev, now: Date()).windows.isEmpty)
        #expect(usage(.failed(.timeout)).retainingWindows(from: prev, now: Date()).plan == nil)
    }

    @Test("unknown identity, notReporting, ok and missing previous never retain")
    func noRetain() {
        let prev = usage(.ok, windows: wins)
        #expect(usage(.unavailable(.cliMissing), auth: .unknown, key: nil).retainingWindows(from: prev, now: Date()).windows.isEmpty)
        #expect(usage(.notReporting, key: "k1").retainingWindows(from: prev, now: Date()).windows.isEmpty)
        #expect(usage(.ok, windows: []).retainingWindows(from: prev, now: Date()).windows.isEmpty)
        #expect(usage(.failed(.timeout)).retainingWindows(from: nil, now: Date()).windows.isEmpty)
        #expect(usage(.failed(.timeout)).retainingWindows(from: usage(.ok, key: "k1"), now: Date()).windows.isEmpty)
    }
}

@Suite("Percent left")
struct PercentLeftTests {
    @Test("non-finite, negative and over-100 inputs never crash or lie")
    func edges() {
        #expect(UsageText.percentLeft(.nan) == nil)
        #expect(UsageText.percentLeft(.infinity) == nil)
        #expect(UsageText.percentLeft(-.infinity) == nil)
        #expect(UsageText.percentLeft(-1) == nil)
        #expect(UsageText.percentLeft(104) == 0)
        #expect(UsageText.percentLeft(.greatestFiniteMagnitude) == 0)
        #expect(UsageText.percentLeft(75.4) == 25)
        #expect(UsageText.percentLeft(0) == 100)
        #expect(UsageText.percentLeft(100) == 0)
    }
}
