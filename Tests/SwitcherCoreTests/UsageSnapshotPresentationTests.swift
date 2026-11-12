import Foundation
import Testing
@testable import SwitcherCore

/// Synthetic fixtures only — every identity, email, home path and key below is fake
/// and belongs to no real account.
private let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

private func reading(_ p: UsageProvider, _ ref: String, label: String,
                     windows: [UsageWindow] = [], state: UsageState = .ok,
                     plan: String? = nil, toolVersion: String? = nil,
                     auth: UsageAuthentication = .unknown,
                     identityKey: String? = nil) -> AccountUsage {
    AccountUsage(id: "\(p.rawValue):\(ref)", provider: p, accountRef: ref,
                 label: label, plan: plan, windows: windows, state: state,
                 readAt: fixedNow, toolVersion: toolVersion,
                 authentication: auth, identityKey: identityKey)
}

private func claudeApp(_ id: String, _ label: String, email: String? = nil) -> AccountStatus {
    AccountStatus(id: id, label: label, customName: nil, defaultName: label,
                  email: email, accountUuid: "uuid-\(id)", orgUuid: "org-\(id)",
                  isActive: false, snapshot: .ready, capturedAt: fixedNow,
                  sessionExpiresAt: fixedNow.addingTimeInterval(86_400))
}

private func claudeStatus(_ accounts: [AccountStatus]) -> SwitcherStatus {
    SwitcherStatus(claude: ClaudeStatus(installed: false, running: false, pid: nil,
                                        version: nil, activeAccountUuid: nil,
                                        activeOrgUuid: nil, activeEmail: nil,
                                        codeSessions: 0),
                   accounts: accounts, relaunchers: [], suspendedRelaunchers: [],
                   originalBackup: nil, pendingJournal: false,
                   nativeMultiAccount: false, warnings: [])
}

private func codexAccount(_ id: String, _ label: String,
                          kind: CodexProfile.Kind = .found,
                          identity: CodexIdentity? = nil) -> CodexAccount {
    CodexAccount(id: id, kind: kind, label: label, customName: nil, defaultName: label,
                 home: "/h/\(id)", homePath: "/h/\(id)", identity: identity,
                 state: .signedIn, pids: [])
}

@Suite("Snapshot from presentations")
struct UsageSnapshotPresentationTests {
    @Test("eleven presentation-only rows serialize in order — synthetic fixture, not eleven verified accounts")
    func tenRows() throws {
        let readings = [
            reading(.cursor, "cursor", label: "Cursor"),
            reading(.grok, "current", label: "Grok"),
            reading(.gemini, "current", label: "Gemini"),
            reading(.antigravity, "current", label: "Antigravity"),
            reading(.devin, "current", label: "Devin"),
            reading(.opencode, "current", label: "OpenCode"),
        ]
        // Three registered Claude App accounts; a2/a3 share a name to prove
        // same-name rows never merge. No Claude CLI reading in this fixture.
        let claude = claudeStatus([
            claudeApp("a1", "Work", email: "fake.work@example.com"),
            claudeApp("a2", "Personal", email: "fake.p@example.com"),
            claudeApp("a3", "Personal", email: "fake.s@example.com"),
        ])
        let codex = CodexStatus(installed: true, version: "1",
            accounts: [
                codexAccount("standard", "Side project", kind: .standard,
                             identity: CodexIdentity(mode: .chatgpt,
                                                     email: "fake.codex@example.com")),
                codexAccount("found:.codex-work", "API key",
                             identity: CodexIdentity(mode: .apiKey)),
            ], hiddenCount: 0)
        let rows = UsagePresentations.accounts(readings: readings, installations: [],
                                               claude: claude, codex: codex, now: fixedNow)
        #expect(rows.count == 11)
        let snap = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        #expect(snap.accounts.count == 11)
        for (account, p) in zip(snap.accounts, rows) {
            #expect(account.provider == p.usage.provider.rawValue)
            #expect(account.label == Privacy.maskEmails(in: p.name))
            #expect(account.state == "ok" || account.state == "notReporting")
            #expect(account.windows.count == p.usage.windows.count)
            #expect(account.authentication == p.usage.authentication.rawValue)
        }
        // Provider-ordered ids: claude app rows, codex rows, then the other providers.
        #expect(snap.accounts.map(\.id) == [
            "claude:app#1", "claude:app#2", "claude:app#3",
            "codex#1", "codex#2",
            "cursor:cursor", "grok:current", "gemini:current", "antigravity:current",
            "devin:current", "opencode:current",
        ])
        #expect(snap.accounts.map(\.accountRef) == [
            "app#1", "app#2", "app#3", "codex#1", "codex#2",
            "cursor", "current", "current", "current", "current", "current",
        ])
        #expect(!snap.accounts.map(\.id).joined().contains(".codex-work"))
        let appRows = snap.accounts.filter { $0.id.hasPrefix("claude:app#") }
        #expect(appRows.allSatisfy { $0.windows.isEmpty && $0.state == "notReporting" })
        // Same-label a2/a3 kept as distinct rows; API-key auth carried through.
        let apiRow = try #require(snap.accounts.first { $0.id == "codex#2" })
        #expect(apiRow.authentication == "apiKey")
    }

    @Test("same-email Claude CLI and saved App stay separate; App never copies CLI quota")
    func cliVsApp() {
        let window = UsageWindow(scope: nil, durationMinutes: 300, usedPercent: 42,
                                 resetsAt: fixedNow.addingTimeInterval(3_600))
        let cli = reading(.claude, "cli", label: "fake.a@example.com",
                          windows: [window], auth: .subscription)
        let claude = claudeStatus([claudeApp("a1", "fake.a@example.com",
                                             email: "fake.a@example.com")])
        let rows = UsagePresentations.accounts(readings: [cli], installations: [],
                                               claude: claude, codex: nil, now: fixedNow)
        let snap = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        #expect(snap.accounts.count == 2)
        #expect(snap.accounts[0].id == "claude:cli")
        #expect(snap.accounts[0].windows.count == 1)
        #expect(snap.accounts[0].authentication == "subscription")
        #expect(snap.accounts[1].id == "claude:app#1")
        #expect(snap.accounts[1].accountRef == "app#1")
        #expect(snap.accounts[1].windows.isEmpty)
        #expect(snap.accounts[1].state == "notReporting")
        #expect(snap.accounts.allSatisfy { !$0.label.contains("fake.a@example.com") })
    }

    @Test("saved account UUIDs never appear in encoded snapshots")
    func savedClaudeIDsAreOpaque() throws {
        let accountUuid = "123e4567-e89b-12d3-a456-426614174000"
        let orgUuid = "987e6543-e21b-12d3-a456-426614174001"
        let accountId = "\(accountUuid)__\(orgUuid)"
        let account = AccountStatus(
            id: accountId, label: "Owner \(accountUuid)", customName: nil,
            defaultName: "Owner \(accountUuid)", email: nil, accountUuid: accountUuid,
            orgUuid: orgUuid, isActive: false, snapshot: .ready, capturedAt: fixedNow,
            sessionExpiresAt: fixedNow.addingTimeInterval(86_400))
        let usage = AccountUsage(
            id: "claude:app:\(accountId)", provider: .claude, accountRef: "app:\(accountId)",
            label: "Claude profile", plan: nil, windows: [], state: .ok, readAt: fixedNow,
            toolVersion: nil)
        let rows = UsagePresentations.accounts(readings: [usage], installations: [],
                                               claude: claudeStatus([account]), codex: nil, now: fixedNow)
        let snapshot = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(snapshot.accounts[0].id == "claude:app#1")
        #expect(snapshot.accounts[0].accountRef == "app#1")
        #expect(!encoded.localizedCaseInsensitiveContains(accountUuid))
        #expect(!encoded.localizedCaseInsensitiveContains(orgUuid))
    }

    @Test("loading a legacy snapshot anonymizes saved Claude identifiers")
    func legacyClaudeIDsAreOpaque() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        let accountUuid = "123e4567-e89b-12d3-a456-426614174000"
        let orgUuid = "987e6543-e21b-12d3-a456-426614174001"
        let accountId = "\(accountUuid)__\(orgUuid)"
        let old = """
            {"generatedAt":"2026-11-04T10:00:00Z","accounts":[{"id":"claude:app:\(accountId)",
            "accountRef":"app:\(accountId)","provider":"claude","label":"Owner \(accountUuid)",
            "plan":null,"state":"ok","problem":null,"readAt":"2026-11-04T10:00:00Z",
            "toolVersion":null,"authentication":"unknown","windows":[]}]}
            """
        try old.write(to: sb.env.usageSnapshotFile, atomically: true, encoding: .utf8)

        let snapshot = try #require(UsageSnapshot.load(env: sb.env))
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(snapshot.accounts[0].id == "claude:app#1")
        #expect(snapshot.accounts[0].accountRef == "app#1")
        #expect(!encoded.localizedCaseInsensitiveContains(accountUuid))
        #expect(!encoded.localizedCaseInsensitiveContains(orgUuid))
    }

    @Test("current registry name wins over a stale collected label; same names never merge")
    func registryNames() {
        let stale = reading(.codex, "m-0000000a", label: "stale@example.com")
        let codex = CodexStatus(installed: true, version: "1",
            accounts: [
                codexAccount("m-0000000a", "Renamed",
                             identity: CodexIdentity(mode: .chatgpt)),
                codexAccount("m-0000000b", "Renamed",
                             identity: CodexIdentity(mode: .apiKey)),
            ], hiddenCount: 0)
        let rows = UsagePresentations.accounts(readings: [stale], installations: [],
                                               claude: nil, codex: codex, now: fixedNow)
        #expect(rows.count == 2)
        let snap = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        #expect(snap.accounts.map(\.id) == ["codex#1", "codex#2"])
        #expect(snap.accounts.map(\.label) == ["Renamed", "Renamed"])
        #expect(!snap.accounts[0].label.contains("stale@example.com"))
    }

    @Test("encoded JSON has no email/owner/identityKey fields or raw values; auth/state/windows preserved")
    func maskedFields() throws {
        let session = UsageWindow(scope: nil, durationMinutes: 300, usedPercent: 40,
                                  resetsAt: fixedNow.addingTimeInterval(3_600))
        let weekly = UsageWindow(scope: "API", durationMinutes: 10_080, usedPercent: 12.5,
                                 resetsAt: fixedNow.addingTimeInterval(86_400))
        let cases: [(UsageAuthentication, String)] = [(.subscription, "sub"),
                                                      (.apiKey, "api"),
                                                      (.unknown, "unk")]
        var originals: [AccountUsage] = []
        var rows: [UsageAccountPresentation] = []
        for (auth, tag) in cases {
            let u = AccountUsage(id: "grok:\(tag)", provider: .grok, accountRef: tag,
                                 label: "fake.\(tag)@example.com", plan: "plan-\(tag)",
                                 windows: [session, weekly], state: .failed(.network),
                                 readAt: fixedNow, toolVersion: "1.2.\(tag)",
                                 authentication: auth, identityKey: "opaque-secret-\(tag)")
            originals.append(u)
            rows.append(UsageAccountPresentation(usage: u, name: "fake.\(tag)@example.com",
                                                 email: "fake.\(tag)@example.com",
                                                 environment: .cli, login: .verified,
                                                 badgeActive: false, owner: nil))
        }
        let snap = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(snap), as: UTF8.self)
        // Serialization proof: nothing memory-only or raw-email reaches JSON.
        for tag in ["sub", "api", "unk"] {
            #expect(!json.contains("fake.\(tag)@example.com"))
            #expect(!json.contains("opaque-secret-\(tag)"))
        }
        for key in ["\"email\"", "\"owner\"", "\"identityKey\"", "\"credentials\""] {
            #expect(!json.contains(key))
        }
        #expect(snap.accounts.map(\.authentication) == ["subscription", "apiKey", "unknown"])
        let first = snap.accounts[0]
        #expect(first.state == "failed" && first.problem == "network")
        #expect(first.plan == "plan-sub" && first.toolVersion == "1.2.sub")
        #expect(first.readAt == fixedNow)
        #expect(first.windows.map(\.kind) == ["session", "weekly"])
        #expect(first.windows[0].scope == nil && first.windows[1].scope == "API")
        #expect(first.windows[0].durationMinutes == 300)
        #expect(first.windows[1].durationMinutes == 10_080)
        #expect(first.windows[0].usedPercent == 40 && first.windows[0].leftPercent == 60)
        #expect(first.windows[1].usedPercent == 12.5 && first.windows[1].leftPercent == 87.5)
        #expect(first.windows[0].resetsAt == fixedNow.addingTimeInterval(3_600))
        // The input readings were never mutated by snapshotting.
        #expect(rows.map(\.usage) == originals)
        #expect(snap.masked() == snap) // idempotent
    }

    @Test("every state maps to its persisted name; daily window fields preserved")
    func stateMappings() {
        let daily = UsageWindow(scope: "Auto", durationMinutes: 1_440, usedPercent: 33.5,
                                resetsAt: fixedNow.addingTimeInterval(7_200))
        let cases: [(UsageState, String, String?)] = [
            (.ok, "ok", nil),
            (.notReporting, "notReporting", nil),
            (.unavailable(.connectionRequired), "unavailable", "connectionRequired"),
            (.failed(.network), "failed", "network"),
        ]
        for (index, (state, name, problem)) in cases.enumerated() {
            let u = reading(.grok, "r\(index)", label: "R\(index)", windows: [daily],
                            state: state)
            let p = UsageAccountPresentation(usage: u, name: "R\(index)", email: nil,
                                             environment: nil, login: .unknown,
                                             badgeActive: false, owner: nil)
            let snap = UsageSnapshot(presentations: [p], generatedAt: fixedNow)
            let account = snap.accounts[0]
            #expect(account.state == name && account.problem == problem)
            #expect(account.windows[0].kind == "daily" && account.windows[0].scope == "Auto")
            #expect(account.windows[0].durationMinutes == 1_440)
            #expect(account.windows[0].usedPercent == 33.5)
            #expect(account.windows[0].leftPercent == 66.5)
            #expect(account.windows[0].resetsAt == fixedNow.addingTimeInterval(7_200))
            #expect(p.usage == u) // input untouched
        }
    }

    @Test("legacy JSON without authentication decodes, re-encodes and round-trips on disk")
    func legacyDecode() throws {
        let json = #"{"generatedAt":"2026-01-01T00:00:00Z","accounts":[{"id":"grok:c","provider":"grok","label":"G","plan":null,"state":"ok","problem":null,"readAt":"2026-01-01T00:00:00Z","toolVersion":null,"windows":[]}]}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(UsageSnapshot.self, from: Data(json.utf8))
        #expect(snap.accounts.count == 1 && snap.accounts[0].authentication == nil)
        // Re-encode + decode: optional authentication stays nil, value equality holds.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let recoded = try dec.decode(UsageSnapshot.self, from: try enc.encode(snap))
        #expect(recoded == snap && recoded.accounts[0].authentication == nil)
        // Disk round-trip through SafeFS into an isolated sandbox store.
        let sb = try Sandbox(); defer { sb.remove() }
        try FileManager.default.createDirectory(at: sb.env.storeDir,
                                                withIntermediateDirectories: true)
        try snap.write(env: sb.env, fs: sb.fs)
        let loaded = try #require(UsageSnapshot.load(env: sb.env))
        #expect(loaded == snap.masked())
        #expect(loaded.accounts[0].authentication == nil)
        // A presentation-derived snapshot round-trips the same way, auth included.
        let u = reading(.grok, "current", label: "Grok", auth: .apiKey)
        let p = UsageAccountPresentation(usage: u, name: "Grok", email: nil,
                                         environment: nil, login: .unknown,
                                         badgeActive: false, owner: nil)
        let psnap = UsageSnapshot(presentations: [p], generatedAt: fixedNow)
        try psnap.write(env: sb.env, fs: sb.fs)
        let ploaded = try #require(UsageSnapshot.load(env: sb.env))
        #expect(ploaded == psnap.masked())
        #expect(ploaded.accounts[0].authentication == "apiKey")
    }

    @Test("a retained claude:app row serializes its kept windows, last read and opaque id")
    func retainedClaudeApp() throws {
        let kept = UsageWindow(scope: nil, durationMinutes: 10_080, usedPercent: 76,
                               resetsAt: fixedNow.addingTimeInterval(3 * 86_400))
        let lastRead = fixedNow.addingTimeInterval(-7_200)
        let u = AccountUsage(id: "claude:app:uuid-a__org-a", provider: .claude,
                             accountRef: "app:uuid-a__org-a", label: "person@example.com",
                             plan: nil, windows: [kept],
                             state: .unavailable(.noSignIn), readAt: lastRead,
                             toolVersion: nil)
        let status = claudeStatus([claudeApp("uuid-a__org-a", "person@example.com",
                                             email: "person@example.com")])
        let rows = UsagePresentations.accounts(readings: [u], installations: [],
                                               claude: status, codex: nil, now: fixedNow)
        let snap = UsageSnapshot(presentations: rows, generatedAt: fixedNow)
        let acct = try #require(snap.accounts.first)
        #expect(acct.id == "claude:app#1")
        #expect(acct.state == "unavailable" && acct.problem == "noSignIn")
        #expect(acct.readAt == lastRead)
        #expect(acct.windows.count == 1 && acct.windows[0].usedPercent == 76)
        #expect(!acct.label.contains("person@example.com"))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(snap), as: UTF8.self)
        #expect(!json.contains("uuid-a") && !json.contains("org-a"))
    }

    @Test("phantom standard Codex excluded; registered-but-uncollected included")
    func phantom() {
        let codex = CodexStatus(installed: true, version: "1",
            accounts: [
                CodexAccount(id: "extra", kind: .found, label: "Extra", customName: nil,
                             defaultName: "Extra", home: "/h", homePath: "/h",
                             identity: nil, state: .signedIn, pids: []),
                CodexAccount(id: "standard", kind: .standard, label: "Home", customName: nil,
                             defaultName: "~", home: "/h", homePath: "/h",
                             identity: nil, state: .signedIn, pids: []),
            ], hiddenCount: 0)
        let rows = UsagePresentations.accounts(readings: [], installations: [],
                                               claude: nil, codex: codex, now: Date())
        let snap = UsageSnapshot(presentations: rows, generatedAt: Date())
        #expect(snap.accounts.count == 1 && snap.accounts[0].id == "codex#1")
    }
}
