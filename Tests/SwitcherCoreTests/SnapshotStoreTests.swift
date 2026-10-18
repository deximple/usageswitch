import Foundation
import Testing
@testable import SwitcherCore

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    func store(_ sb: Sandbox) -> SnapshotStore { SnapshotStore(env: sb.env, fs: sb.fs) }

    @Test func captureCopiesCookieGroupWithManifest() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        // Whole-second expiry: the manifest stores ISO-8601 dates.
        try CookieFixture.make(at: env.claudeCookies, identity: .a, sessionExpires: Date(timeIntervalSince1970: 1_900_000_000))
        try sb.write("FAKE-JOURNAL", to: env.claudeUserData.appendingPathComponent("Cookies-journal"))
        try ConfigFixture.make(at: env.claudeConfigJSON, lastKnown: FakeIdentity.a.account)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = try store(sb).capture(from: env.claudeUserData, identity: FakeIdentity.a.identity,
                                         claudeVersion: "1.0.0", now: now)
        #expect(snap.dir.lastPathComponent == "gen-1")
        #expect(snap.manifest.files.map(\.name) == ["Cookies", "Cookies-journal"])
        #expect(snap.manifest.cookieMeta == CookieJar.Meta(version: 24, lastCompatibleVersion: 24))
        #expect(snap.manifest.session?.httpOnly == true)
        #expect(snap.manifest.capturedAt == now)
        #expect(snap.manifest.identity == FakeIdentity.a.identity)
        #expect(fileData(snap.dir.appendingPathComponent("Cookies")) == fileData(env.claudeCookies))
        // Token caches (config.json) are never stored in a snapshot.
        #expect(!exists(snap.dir.appendingPathComponent("config.json")))
        let manifestText = String(decoding: fileData(snap.dir.appendingPathComponent("manifest.json")) ?? Data(), as: UTF8.self)
        #expect(!manifestText.contains("FAKE-SESSION"))
        #expect(!manifestText.contains("FAKE-TOKEN"))
        try store(sb).verify(snap)
        #expect(store(sb).latest(for: FakeIdentity.a.identity) == snap)
        #expect(store(sb).latest(for: FakeIdentity.b.identity) == nil)
    }

    @Test func permissionsAreOwnerOnly() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        try CookieFixture.make(at: env.claudeCookies, identity: .a)
        _ = chmod(env.claudeCookies.path, 0o644)
        let snap = try store(sb).capture(from: env.claudeUserData, identity: FakeIdentity.a.identity, claudeVersion: nil)
        for dir in [env.storeDir, env.snapshotsDir, snap.dir.deletingLastPathComponent(), snap.dir] {
            #expect(posixPermissions(dir) == 0o700, "\(dir.lastPathComponent)")
        }
        for file in ["Cookies", "manifest.json"] {
            #expect(posixPermissions(snap.dir.appendingPathComponent(file)) == 0o600, "\(file)")
        }
        // The live file keeps its own mode; only our copy is restricted.
        #expect(posixPermissions(env.claudeCookies) == 0o644)
    }

    @Test func tamperedOrMissingFilesAreCorrupt() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        try CookieFixture.make(at: env.claudeCookies, identity: .a)
        let snap = try store(sb).capture(from: env.claudeUserData, identity: FakeIdentity.a.identity, claudeVersion: nil)
        let cookies = snap.dir.appendingPathComponent("Cookies")
        var bytes = try #require(fileData(cookies))
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: cookies)
        guard case .snapshotCorrupt = switcherError({ try store(sb).verify(snap) }) else { Issue.record("tamper"); return }
        try FileManager.default.removeItem(at: cookies)
        guard case .snapshotCorrupt = switcherError({ try store(sb).verify(snap) }) else { Issue.record("missing"); return }
        let noCookies = Snapshot(dir: snap.dir, manifest: SnapshotManifest(
            identity: snap.manifest.identity, generation: 1, capturedAt: Date(), claudeVersion: nil,
            cookieMeta: snap.manifest.cookieMeta, session: nil, files: []))
        guard case .snapshotCorrupt = switcherError({ try store(sb).verify(noCookies) }) else { Issue.record("empty"); return }
    }

    @Test func keepsTwoGenerations() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        let s = store(sb)
        for i in 1...4 {
            try CookieFixture.make(at: env.claudeCookies, identity: .a, tag: "000\(i)")
            let snap = try s.capture(from: env.claudeUserData, identity: FakeIdentity.a.identity, claudeVersion: nil,
                                     now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
            #expect(snap.manifest.generation == i)
        }
        let gens = s.generations(for: FakeIdentity.a.identity)
        #expect(gens.map(\.manifest.generation) == [4, 3])
        let names = try FileManager.default.contentsOfDirectory(atPath: s.identityDir(FakeIdentity.a.identity).path).sorted()
        #expect(names == ["gen-3", "gen-4"])
        #expect(fileData(gens[0].dir.appendingPathComponent("Cookies")) == fileData(env.claudeCookies))
        // Unrelated or unreadable entries are ignored.
        try sb.write("junk", to: s.identityDir(FakeIdentity.a.identity).appendingPathComponent("gen-x/manifest.json"))
        try sb.write("junk", to: s.identityDir(FakeIdentity.a.identity).appendingPathComponent("gen-9/manifest.json"))
        #expect(s.generations(for: FakeIdentity.a.identity).map(\.manifest.generation) == [4, 3])
    }

    @Test func captureWithoutCookiesFailsAndLeavesNoPartial() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let s = store(sb)
        guard case .io = switcherError({
            _ = try s.capture(from: sb.env.claudeUserData, identity: FakeIdentity.a.identity, claudeVersion: nil)
        }) else { Issue.record("expected io"); return }
        let dir = s.identityDir(FakeIdentity.a.identity)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        #expect(s.latest(for: FakeIdentity.a.identity) == nil)
    }

    @Test func originalBackupIsMadeOnceAndNeverOverwritten() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        try CookieFixture.make(at: env.claudeCookies, identity: .a)
        try ConfigFixture.make(at: env.claudeConfigJSON, lastKnown: FakeIdentity.a.account)
        try sb.write("{\"mcpServers\":{}}", to: env.claudeUserData.appendingPathComponent("claude_desktop_config.json"))
        try sb.write("{}", to: env.claudeUserData.appendingPathComponent("bridge-state.json"))
        try sb.write("FAKE-LEVELDB", to: env.claudeUserData.appendingPathComponent("Local Storage/leveldb/000003.log"))
        try sb.write("{}", to: env.claudeUserData.appendingPathComponent("Preferences"))
        let s = store(sb)
        #expect(s.originalBackup() == nil)
        let first = try s.makeOriginalBackupIfNeeded(from: env.claudeUserData, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first.lastPathComponent.hasPrefix("original-"))
        #expect(!first.lastPathComponent.contains(":"))
        let copied = try FileManager.default.contentsOfDirectory(atPath: first.path).sorted()
        #expect(copied == ["Cookies", "Local Storage", "bridge-state.json", "claude_desktop_config.json", "config.json"])
        // The backup's config.json is the live one minus the encrypted token caches (never kept in the store).
        let liveConfig = try jsonObject(env.claudeConfigJSON)
        var expected = liveConfig
        for key in SnapshotItems.tokenCacheKeys { expected.removeValue(forKey: key) }
        #expect(NSDictionary(dictionary: try jsonObject(first.appendingPathComponent("config.json"))).isEqual(to: expected))
        #expect(liveConfig["oauth:tokenCache"] != nil) // the live file itself is untouched
        #expect(posixPermissions(first) == 0o700)
        #expect(posixPermissions(first.appendingPathComponent("Local Storage/leveldb/000003.log")) == 0o600)
        let originalConfig = fileData(first.appendingPathComponent("config.json"))

        try ConfigFixture.make(at: env.claudeConfigJSON, lastKnown: FakeIdentity.b.account)
        let second = try s.makeOriginalBackupIfNeeded(from: env.claudeUserData, now: Date(timeIntervalSince1970: 1_900_000_000))
        #expect(second == first)
        #expect(fileData(first.appendingPathComponent("config.json")) == originalConfig)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.backupsDir.path) == [first.lastPathComponent])
        #expect(s.originalBackup() == first)
    }

    @Test func sanitizeStripsTokenCachesFromAnOlderOriginalBackup() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        let s = store(sb)
        s.sanitizeOriginalBackup() // no backup yet: nothing to do, nothing created
        #expect(!exists(env.backupsDir))
        // A backup written by an earlier version still holds the token caches.
        let backup = env.backupsDir.appendingPathComponent("original-20260101T000000Z", isDirectory: true)
        try sb.fs.createDirectory(env.storeDir)
        try sb.fs.createDirectory(env.backupsDir)
        try sb.fs.createDirectory(backup)
        let config = backup.appendingPathComponent("config.json")
        try ConfigFixture.make(at: config, lastKnown: FakeIdentity.a.account)
        try sb.write("FAKE-COOKIES", to: backup.appendingPathComponent("Cookies"))
        let cookies = fileData(backup.appendingPathComponent("Cookies"))
        s.sanitizeOriginalBackup()
        let dict = try jsonObject(config)
        for key in SnapshotItems.tokenCacheKeys { #expect(dict[key] == nil, "\(key)") }
        #expect(dict["lastKnownAccountUuid"] as? String == FakeIdentity.a.account)
        #expect(dict["coworkTrustedDeviceToken:\(FakeIdentity.clientUuid)"] as? String == "FAKE-DEVICE-TOKEN-0001")
        #expect(fileData(backup.appendingPathComponent("Cookies")) == cookies)
        #expect(posixPermissions(config) == 0o600)
        // Already clean or not JSON: left byte-identical.
        let clean = fileData(config)
        s.sanitizeOriginalBackup()
        #expect(fileData(config) == clean)
        try Data("not json".utf8).write(to: config)
        s.stripTokenCaches(inConfigAt: config)
        #expect(fileData(config) == Data("not json".utf8))
        s.stripTokenCaches(inConfigAt: backup.appendingPathComponent("absent.json"))
        #expect(!exists(backup.appendingPathComponent("absent.json")))
    }

    @Test func reloginMarkerAndUsableSnapshotRules() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let env = sb.env
        let s = store(sb)
        let now = Date()
        let a = FakeIdentity.a.identity
        #expect(!s.hasUsableSnapshot(for: a, now: now)) // none
        s.markNeedsRelogin(a) // nothing to mark: no-op, nothing created
        #expect(!exists(env.snapshotsDir))

        try CookieFixture.make(at: env.claudeCookies, identity: .a, sessionExpires: now.addingTimeInterval(86400))
        let gen1 = try s.capture(from: env.claudeUserData, identity: a, claudeVersion: nil, now: now)
        #expect(s.hasUsableSnapshot(for: a, now: now))
        #expect(!s.hasUsableSnapshot(for: a, now: now.addingTimeInterval(2 * 86400))) // sessionKey expired by then
        #expect(!s.needsRelogin(gen1))

        // Only the newest generation is marked; the marker does not make the snapshot corrupt.
        let gen2 = try s.capture(from: env.claudeUserData, identity: a, claudeVersion: nil, now: now)
        s.markNeedsRelogin(a)
        #expect(s.needsRelogin(gen2) && !s.needsRelogin(gen1))
        #expect(exists(gen2.dir.appendingPathComponent("relogin-required")))
        try s.verify(gen2)
        #expect(!s.hasUsableSnapshot(for: a, now: now))

        // A newer capture is usable again; a tampered one is not.
        let gen3 = try s.capture(from: env.claudeUserData, identity: a, claudeVersion: nil, now: now)
        #expect(s.hasUsableSnapshot(for: a, now: now))
        try Data("tampered".utf8).write(to: gen3.dir.appendingPathComponent("Cookies"))
        #expect(!s.hasUsableSnapshot(for: a, now: now))

        // A jar without a sessionKey row is never usable.
        let b = FakeIdentity.b.identity
        try CookieFixture.make(at: env.claudeCookies, identity: .b, includeSession: false)
        let noSession = try s.capture(from: env.claudeUserData, identity: b, claudeVersion: nil, now: now)
        #expect(noSession.manifest.session == nil)
        #expect(!s.hasUsableSnapshot(for: b, now: now))
    }

    @Test func nonUUIDIdentitiesMapToAnIsolatedDirectory() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let s = store(sb)
        let invalid = sb.env.snapshotsDir.appendingPathComponent("invalid-identity", isDirectory: true)
        let bad: [AccountIdentity] = [
            AccountIdentity(accountUuid: "../../../Claude", orgUuid: FakeIdentity.a.org, email: nil, displayName: nil),
            AccountIdentity(accountUuid: FakeIdentity.a.account, orgUuid: "../x", email: nil, displayName: nil),
            AccountIdentity(accountUuid: "zzzzzzzz-1111-4111-8111-zzzzzzzzzzzz", orgUuid: FakeIdentity.a.org,
                            email: nil, displayName: nil),
            AccountIdentity(accountUuid: "", orgUuid: "", email: nil, displayName: nil),
        ]
        for identity in bad {
            #expect(s.identityDir(identity) == invalid, "\(identity.accountUuid)")
            #expect(s.latest(for: identity) == nil)
        }
        #expect(s.identityDir(FakeIdentity.a.identity)
            == sb.env.snapshotsDir.appendingPathComponent(FakeIdentity.a.identity.key, isDirectory: true))
    }
}
