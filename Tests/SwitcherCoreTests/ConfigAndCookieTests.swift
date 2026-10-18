import Foundation
import Testing
@testable import SwitcherCore

@Suite("ClaudeConfig")
struct ClaudeConfigTests {
    @Test func readsMarkersWithoutTouchingOtherKeys() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try ConfigFixture.make(at: sb.env.claudeConfigJSON, lastKnown: FakeIdentity.a.account, stagedVersion: "1.2.3")
        let config = try ClaudeConfig.load(sb.env.claudeConfigJSON)
        #expect(config.lastKnownAccountUuid == FakeIdentity.a.account)
        #expect(config.stagedUpdateVersion == "1.2.3")
        #expect(config.runningInstancePID == 4242)
        #expect(config.hasTokenCache)
    }

    @Test func missingOrMalformedConfigIsIOError() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        guard case .io = switcherError({ _ = try ClaudeConfig.load(sb.env.claudeConfigJSON) }) else {
            Issue.record("missing file"); return
        }
        try sb.write("[1,2]", to: sb.env.claudeConfigJSON)
        guard case .io = switcherError({ _ = try ClaudeConfig.load(sb.env.claudeConfigJSON) }) else {
            Issue.record("array root"); return
        }
        guard case .io = switcherError({ _ = try ClaudeConfig.mutated(Data("not json".utf8), .clearForLogin) }) else {
            Issue.record("garbage"); return
        }
    }

    @Test func restorePreservesUnrelatedKeysAndDropsTokenCaches() throws {
        let original = ConfigFixture.dictionary(lastKnown: FakeIdentity.a.account)
        let data = try JSONSerialization.data(withJSONObject: original)
        let out = try ClaudeConfig.mutated(data, .restore(accountUuid: FakeIdentity.b.account))
        let dict = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        #expect(dict["lastKnownAccountUuid"] as? String == FakeIdentity.b.account)
        for key in SnapshotItems.tokenCacheKeys { #expect(dict[key] == nil, "\(key)") }
        var expected = original
        for key in SnapshotItems.tokenCacheKeys + [SnapshotItems.lastKnownAccountKey] { expected.removeValue(forKey: key) }
        var actual = dict
        actual.removeValue(forKey: SnapshotItems.lastKnownAccountKey)
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
        #expect(dict["coworkTrustedDeviceToken:\(FakeIdentity.clientUuid)"] as? String == "FAKE-DEVICE-TOKEN-0001")
        #expect(dict["dxt:allowlistEnabled:\(FakeIdentity.a.org)"] as? Bool == true)
        #expect(!(try ClaudeConfig(data: out)).hasTokenCache)
        // Slashes are not escaped, so unrelated URL values stay byte-recognisable.
        #expect(String(decoding: out, as: UTF8.self).contains("https://claude.ai/x"))
    }

    @Test func strippingTokenCachesKeepsEverythingElse() throws {
        let original = ConfigFixture.dictionary(lastKnown: FakeIdentity.a.account)
        let out = try ClaudeConfig.strippingTokenCaches(try JSONSerialization.data(withJSONObject: original))
        let dict = try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        var expected = original
        for key in SnapshotItems.tokenCacheKeys { expected.removeValue(forKey: key) }
        #expect(NSDictionary(dictionary: dict).isEqual(to: expected))
        #expect(dict["lastKnownAccountUuid"] as? String == FakeIdentity.a.account) // the marker is not a token cache
        #expect(!(try ClaudeConfig(data: out)).hasTokenCache)
        #expect(String(decoding: out, as: UTF8.self).contains("https://claude.ai/x"))
        guard case .io = switcherError({ _ = try ClaudeConfig.strippingTokenCaches(Data("not json".utf8)) }) else {
            Issue.record("garbage must be an io error"); return
        }
    }

    @Test func clearForLoginRemovesMarkerAndCaches() throws {
        let data = try JSONSerialization.data(withJSONObject: ConfigFixture.dictionary(lastKnown: FakeIdentity.a.account))
        let out = try ClaudeConfig.mutated(data, .clearForLogin)
        let config = try ClaudeConfig(data: out)
        #expect(config.lastKnownAccountUuid == nil)
        #expect(!config.hasTokenCache)
        #expect(config.runningInstancePID == 4242)
        #expect(config.stagedUpdateVersion == "1.0.0")
        // Already-clear input stays clear (idempotent).
        let again = try ClaudeConfig(data: try ClaudeConfig.mutated(out, .clearForLogin))
        #expect(again.lastKnownAccountUuid == nil && !again.hasTokenCache)
    }
}

@Suite("CookieJar metadata")
struct CookieJarTests {
    @Test func metaAndSessionInfo() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let expires = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 10 * 86400)
        let url = try CookieFixture.make(at: sb.env.claudeCookies, identity: .a, sessionExpires: expires)
        let before = fileData(url)
        #expect(try CookieJar.meta(of: url) == CookieJar.Meta(version: 24, lastCompatibleVersion: 24))
        let info = try #require(try CookieJar.sessionInfo(of: url))
        #expect(abs(info.expiresAt.timeIntervalSince(expires)) < 0.001)
        #expect(info.httpOnly && info.secure)
        #expect(info.isValid(at: Date()))
        #expect(!info.isValid(at: expires.addingTimeInterval(1)))
        #expect(!CookieJar.SessionInfo(expiresAt: expires, httpOnly: false, secure: true).isValid(at: Date()))
        #expect(!CookieJar.SessionInfo(expiresAt: expires, httpOnly: true, secure: false).isValid(at: Date()))
        // Read-only access leaves the jar byte-identical and creates no sidecars.
        #expect(fileData(url) == before)
        #expect(!exists(URL(fileURLWithPath: url.path + "-journal")))
    }

    @Test func noSessionRowAndMissingMeta() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let url = try CookieFixture.make(at: sb.env.claudeCookies, identity: .a, includeSession: false, lastCompatible: nil)
        #expect(try CookieJar.sessionInfo(of: url) == nil)
        #expect(try CookieJar.meta(of: url) == CookieJar.Meta(version: 24, lastCompatibleVersion: 24))
        let db = try TestDB(url, create: false)
        try db.exec("DELETE FROM meta WHERE key = 'version'")
        db.close()
        guard case .sqlite = switcherError({ _ = try CookieJar.meta(of: url) }) else { Issue.record("no version"); return }
        guard case .sqlite = switcherError({ _ = try CookieJar.meta(of: sb.root.appendingPathComponent("nope")) }) else {
            Issue.record("missing db"); return
        }
    }

    @Test func removeAuthRowsKeepsDeviceTrustAndCloudflare() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        try fs.createDirectory(sb.env.stagingDir)
        let staged = try CookieFixture.make(
            at: sb.env.stagingDir.appendingPathComponent("Cookies"), identity: .a,
            extraRows: [CookieFixture.Row(host: "claude.ai", name: "sessionKey", value: "FAKE-SESSION-HOSTONLY",
                                          expires: Date().addingTimeInterval(86400)),
                        CookieFixture.Row(host: ".claude.ai", name: "routing_hint_like", value: "FAKE-KEEP",
                                          expires: Date().addingTimeInterval(86400))])
        let removed = try CookieJar.removeAuthRows(fromStagedCopy: staged, stagingDir: sb.env.stagingDir, fs: fs)
        #expect(removed == 6)
        let names = try CookieFixture.names(staged)
        #expect(names == [
            ".claude.ai cf_clearance", ".claude.ai fixture_identity", ".claude.ai routing_hint_like",
            ".example.com sessionKey", "claude.ai __Host-ant_trusted_device",
        ])
        #expect(try CookieJar.sessionInfo(of: staged) == nil)
        #expect(try CookieJar.meta(of: staged).version == 24)
    }

    @Test func removeAuthRowsRefusesPathsOutsideSafeFS() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        // The live jar itself is an allowed swap target but enrollment only edits staged copies;
        // anything outside the allowlist must be refused before SQLite even opens it.
        let outside = try CookieFixture.make(at: try sb.scratch().appendingPathComponent("Cookies"), identity: .a)
        let before = fileData(outside)
        #expect(switcherError { try CookieJar.removeAuthRows(fromStagedCopy: outside, stagingDir: outside.deletingLastPathComponent(), fs: sb.fs) }
            == .forbiddenWrite(outside.path))
        #expect(fileData(outside) == before)
        let otherApp = try CookieFixture.make(
            at: OutsideFixture.otherAppDir(sb.env).appendingPathComponent("Cookies"), identity: .a)
        #expect(switcherError { try CookieJar.removeAuthRows(fromStagedCopy: otherApp, stagingDir: sb.env.stagingDir, fs: sb.fs) }
            == .forbiddenWrite(otherApp.path))
    }

    @Test func removeAuthRowsRefusesTheLiveJarAndAnythingNotDirectlyInStaging() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        // The live jar is an allowed SafeFS target (it is swapped), but must never be edited in place.
        let live = try CookieFixture.make(at: sb.env.claudeCookies, identity: .a)
        let liveBefore = fileData(live)
        #expect(fs.isAllowed(live))
        #expect(switcherError { try CookieJar.removeAuthRows(fromStagedCopy: live, stagingDir: sb.env.stagingDir, fs: fs) }
            == .forbiddenWrite(live.path))
        #expect(fileData(live) == liveBefore)
        #expect(try CookieJar.sessionInfo(of: live) != nil)
        // Inside the store but nested below staging (or elsewhere in the store) is refused too.
        try fs.createDirectory(sb.env.stagingDir.appendingPathComponent("nested"))
        let nested = try CookieFixture.make(at: sb.env.stagingDir.appendingPathComponent("nested/Cookies"), identity: .a)
        #expect(switcherError { try CookieJar.removeAuthRows(fromStagedCopy: nested, stagingDir: sb.env.stagingDir, fs: fs) }
            == .forbiddenWrite(nested.path))
        let inStore = try CookieFixture.make(at: sb.env.previousDir.appendingPathComponent("Cookies"), identity: .a)
        #expect(switcherError { try CookieJar.removeAuthRows(fromStagedCopy: inStore, stagingDir: sb.env.stagingDir, fs: fs) }
            == .forbiddenWrite(inStore.path))
        #expect(try CookieJar.sessionInfo(of: nested) != nil && CookieJar.sessionInfo(of: inStore) != nil)
    }

    @Test(arguments: [
        (24, 24, 24, true), (20, 20, 24, true), (25, 24, 24, true), (25, 25, 24, false), (30, 26, 24, false),
        (24, 24, 23, false), (24, 23, 23, true),
    ])
    func compatibility(snapVersion: Int, snapLastCompatible: Int, liveVersion: Int, expected: Bool) {
        let snap = CookieJar.Meta(version: snapVersion, lastCompatibleVersion: snapLastCompatible)
        let live = CookieJar.Meta(version: liveVersion, lastCompatibleVersion: liveVersion)
        #expect(CookieJar.isCompatible(snapshot: snap, live: live) == expected)
    }

    @Test func compatibleWhenLiveJarIsMissing() {
        #expect(CookieJar.isCompatible(snapshot: .init(version: 99, lastCompatibleVersion: 99), live: nil))
    }

    @Test func chromiumEpochConversion() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CookieJar.date(fromChromium: Chromium.microseconds(date)) == date)
        #expect(CookieJar.date(fromChromium: 0) == Date(timeIntervalSince1970: -11_644_473_600))
    }
}
