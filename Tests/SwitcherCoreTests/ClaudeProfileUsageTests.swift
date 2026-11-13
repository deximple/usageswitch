import Darwin
import Foundation
import Testing
@testable import SwitcherCore

private let profileReadAt = Date(timeIntervalSince1970: 1_793_793_600)

private func profileTestDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("us-profile-\(name)",
                                                                                  isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return URL(fileURLWithPath: try #require(ClaudeProfileDirectory.realpathValue(directory.path)),
               isDirectory: true)
}

private func makeClaudeProfile(_ url: URL, account: String = "account-1",
                               org: String = "org-1", startups: Int = 1) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let config = #"{"oauthAccount":{"accountUuid":"\#(account)","organizationUuid":"\#(org)"},"numStartups":\#(startups)}"#
    try Data(config.utf8).write(to: url.appendingPathComponent(".claude.json"))
}

private func makeProfileBinary(home: URL, versioned: Bool = true) throws -> URL {
    let manager = FileManager.default
    let real = versioned
        ? home.appendingPathComponent(".local/share/claude/versions/2.1.317")
        : home.appendingPathComponent(".local/bin/claude")
    try manager.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: real)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
    guard versioned else { return real }
    let link = home.appendingPathComponent(".local/bin/claude")
    try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: link, withDestinationURL: real)
    return link
}

private func makeCaskroomProfileBinary(home: URL) throws -> URL {
    let binary = home.appendingPathComponent(
        "opt/homebrew/Caskroom/claude-code/2.1.317/claude")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return binary
}

private func profileAuthJSON(_ profile: URL, loggedIn: Bool = true,
                             org: String? = "org-1", configDirectory: String? = nil,
                             email: String = "profile@example.invalid") -> String {
    let values: [String: Any] = [
        "loggedIn": loggedIn, "authMethod": "oauth", "apiProvider": "firstParty",
        "analyticsDisabled": false, "projectsDirectory": profile.appendingPathComponent("projects").path,
        "configDirectory": configDirectory ?? profile.path, "email": email,
        "orgId": org.map { $0 as Any } ?? NSNull(), "orgName": "Profile org",
        "subscriptionType": "pro",
    ]
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// `claude auth status --json` without the identity keys — CLI 2.1.323 prints this shape for a
/// signed-out profile, omitting email, orgId, orgName and subscriptionType instead of sending null.
private func authJSONWithoutIdentity(_ profile: URL, loggedIn: Bool) -> String {
    let values: [String: Any] = [
        "loggedIn": loggedIn, "authMethod": loggedIn ? "claude.ai" : "none",
        "apiProvider": "firstParty", "analyticsDisabled": false, "loginExpiresAt": NSNull(),
        "projectsDirectory": profile.appendingPathComponent("projects").path,
        "configDirectory": profile.path,
    ]
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func profileRunner(home: URL, profile: URL, statusJSONs: [String]? = nil,
                           onUsage: (@Sendable () -> Void)? = nil) -> FakeUsageRunner {
    let runner = FakeUsageRunner()
    let authResponses = ProfileAuthResponses(statusJSONs ?? [profileAuthJSON(profile)])
    runner.respond = { request in
        if request.arguments == ["auth", "status", "--json"] {
            return UsageProcessResult(lines: [authResponses.next()], outcome: .exited(0))
        }
        if request.arguments.first == "-p" {
            onUsage?()
            return UsageProcessResult(lines: UsageFixture.claude_2_1_317
                .split(whereSeparator: \.isNewline).map(String.init), outcome: .stopped)
        }
        return UsageProcessResult(lines: [], outcome: .exited(0))
    }
    _ = home
    return runner
}

private final class ProfileAuthResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        if responses.count > 1 { return responses.removeFirst() }
        return responses.first ?? "{}"
    }
}

private func profileCollector(home: URL, profile: URL, binary: URL,
                              runner: FakeUsageRunner,
                              expectedEmail: String? = nil,
                              managed: ClaudeManagedSettings? = nil,
                              workingDirectory: URL = FileManager.default.temporaryDirectory) -> ClaudeProfileUsageCollector {
    let scratch = home.appendingPathComponent("scratch", isDirectory: true)
    return ClaudeProfileUsageCollector(
        binding: ClaudeProfileBinding(accountId: "saved-1", accountUuid: "account-1",
                                      orgUuid: "org-1", profilePath: profile.path),
        runner: runner, expectedEmail: expectedEmail, home: home,
        managed: managed ?? ClaudeManagedSettings(
            folder: scratch.appendingPathComponent("managed"),
            preferences: scratch.appendingPathComponent("preferences")),
        binaryPaths: [binary],
        excludedRoots: [home.appendingPathComponent("store", isDirectory: true)],
        workingDirectory: workingDirectory,
        now: { profileReadAt })
}

@Suite("Claude CLI profile validator")
struct ClaudeProfileDirectoryTests {
    @Test("rejects nonexistent paths and files")
    func missingAndFile() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(ClaudeProfileDirectory.validate(path: home.appendingPathComponent("missing").path,
                                                home: home, excludedRoots: []) == nil)
        #expect(ClaudeProfileDirectory.validate(path: file.path, home: home, excludedRoots: []) == nil)
    }

    @Test("rejects symlink directories and any symlinked path component")
    func symlinks() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("real/child", isDirectory: true)
        try makeClaudeProfile(target)
        let directLink = home.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: target)
        let parentLink = home.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink,
            withDestinationURL: home.appendingPathComponent("real", isDirectory: true))
        #expect(ClaudeProfileDirectory.validate(path: directLink.path, home: home,
                                                excludedRoots: []) == nil)
        #expect(ClaudeProfileDirectory.validate(path: parentLink.appendingPathComponent("child").path,
                                                home: home, excludedRoots: []) == nil)
    }

    @Test("rejects group-writable folders and missing or symlinked identity files")
    func permissionsAndIdentityFile() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let writable = home.appendingPathComponent("writable", isDirectory: true)
        try makeClaudeProfile(writable)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: writable.path)
        #expect(ClaudeProfileDirectory.validate(path: writable.path, home: home,
                                                excludedRoots: []) == nil)

        let missing = home.appendingPathComponent("missing-config", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        #expect(ClaudeProfileDirectory.validate(path: missing.path, home: home,
                                                excludedRoots: []) == nil)

        let targetFile = home.appendingPathComponent("identity-target")
        try Data("{}".utf8).write(to: targetFile)
        let symlinked = home.appendingPathComponent("symlinked-config", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinked.appendingPathComponent(".claude.json"),
                                                   withDestinationURL: targetFile)
        #expect(ClaudeProfileDirectory.validate(path: symlinked.path, home: home,
                                                excludedRoots: []) == nil)
    }

    @Test("rejects profiles equal to, inside, or containing each excluded root")
    func excludedRoots() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = [
            home.appendingPathComponent(".claude", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            home.appendingPathComponent("store", isDirectory: true),
        ]
        for root in roots {
            let equal = root
            try makeClaudeProfile(equal)
            #expect(ClaudeProfileDirectory.validate(path: equal.path, home: home,
                                                    excludedRoots: [roots[2]]) == nil)
            let inside = root.appendingPathComponent("profile", isDirectory: true)
            try makeClaudeProfile(inside)
            #expect(ClaudeProfileDirectory.validate(path: inside.path, home: home,
                                                    excludedRoots: [roots[2]]) == nil)
        }
        let homeIdentity = home.appendingPathComponent(".claude.json")
        try Data("{}".utf8).write(to: homeIdentity)
        #expect(ClaudeProfileDirectory.validate(path: home.path, home: home,
                                                excludedRoots: [roots[2]]) == nil)
    }

    @Test("valid directory returns its canonical URL")
    func valid() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        #expect(ClaudeProfileDirectory.validate(path: profile.path, home: home,
                                                excludedRoots: []) == profile)
    }
}

@Suite("Claude CLI profile usage")
struct ClaudeProfileUsageTests {
    @Test func authStatusAndUsageShareTheInjectedWorkingDirectory() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let workDir = home.appendingPathComponent("cli-workdir", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let runner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile)],
            onUsage: { try? makeClaudeProfile(profile, startups: 2) })
        let result = try #require(profileCollector(home: home, profile: profile, binary: binary, runner: runner,
                                                   workingDirectory: workDir).collect())
        #expect(result.state == .ok)
        #expect(runner.requests.map(\.workingDirectory) == [workDir, workDir, workDir])
        #expect(FileManager.default.fileExists(atPath: workDir.path))

        let missing = home.appendingPathComponent("no-such-dir", isDirectory: true)
        let idle = profileRunner(home: home, profile: profile)
        let refused = try #require(profileCollector(home: home, profile: profile, binary: binary, runner: idle,
                                                    workingDirectory: missing).collect())
        #expect(refused.state == .failed(.refused))
        #expect(idle.requests.isEmpty)
    }

    @Test func aProfileWhoseCLISignInIsAnotherAccountIsRejected() throws {
        // The CLI is signed in as a different account (case-insensitive): accountMismatch.
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let other = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile, email: "other@example.invalid")])
        let result = try #require(profileCollector(home: home, profile: profile, binary: binary,
                                                   runner: other,
                                                   expectedEmail: "profile@example.invalid").collect())
        #expect(result.state == .failed(.accountMismatch))
        // a case-different match is accepted
        let same = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile, email: "PROFILE@EXAMPLE.INVALID"),
                          profileAuthJSON(profile, email: "PROFILE@EXAMPLE.INVALID")],
            onUsage: { try? makeClaudeProfile(profile, startups: 2) })
        let ok = try #require(profileCollector(home: home, profile: profile, binary: binary,
                                                runner: same,
                                                expectedEmail: "profile@example.invalid").collect())
        #expect(ok.state == .ok)
    }

    @Test("happy path performs auth, usage, auth in order with the profile environment")
    func happyPathAndDefaultCollectorEnvironment() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let runner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile)],
            onUsage: { try? makeClaudeProfile(profile, startups: 2) })
        let result = try #require(
            profileCollector(home: home, profile: profile, binary: binary, runner: runner).collect())
        #expect(result.id == "claude:app:saved-1")
        #expect(result.accountRef == "app:saved-1")
        #expect(result.authentication == .unknown && result.identityKey == nil)
        #expect(result.state == .ok && result.windows.count == 2)
        #expect(result.toolVersion == "2.1.317")
        #expect(runner.requests.count == 3)
        #expect(runner.requests.map(\.arguments) == [
            ["auth", "status", "--json"], ClaudeUsageCollector.arguments,
            ["auth", "status", "--json"],
        ])
        #expect(runner.requests.allSatisfy { $0.environment["CLAUDE_CONFIG_DIR"] == profile.path })
        #expect(runner.requests.map(\.timeout) == [20, 60, 20])

        let defaultRunner = profileRunner(home: home, profile: profile)
        _ = ClaudeUsageCollector(runner: defaultRunner, home: home,
            managed: ClaudeManagedSettings(folder: home.appendingPathComponent("managed"),
                                           preferences: home.appendingPathComponent("preferences")),
            binaryPaths: [binary], workingDirectory: FileManager.default.temporaryDirectory,
            now: { profileReadAt }).collect()
        #expect(defaultRunner.requests.first?.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(runner.requests[1].timeout == defaultRunner.requests.first?.timeout)
    }

    @Test("Caskroom versions are accepted; managed profiles and identity mismatch fail closed")
    func preflightFailures() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let caskroom = try makeCaskroomProfileBinary(home: home)
        #expect(ClaudeUsageCollector.toolVersion(of: caskroom) == nil)
        let caskroomRunner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile)])
        let caskroomResult = try #require(profileCollector(
            home: home, profile: profile, binary: caskroom, runner: caskroomRunner).collect())
        #expect(caskroomResult.state == .ok)
        #expect(caskroomResult.toolVersion == nil)
        #expect(caskroomRunner.requests.count == 3)

        let versioned = try makeProfileBinary(home: home)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("remote-settings.json"))
        let managedRunner = profileRunner(home: home, profile: profile)
        #expect(profileCollector(home: home, profile: profile, binary: versioned, runner: managedRunner)
            .collect()?.state == .unavailable(.managed))
        #expect(managedRunner.requests.isEmpty)

        try FileManager.default.removeItem(at: profile.appendingPathComponent("remote-settings.json"))
        try makeClaudeProfile(profile, account: "another-account")
        let mismatchRunner = profileRunner(home: home, profile: profile)
        #expect(profileCollector(home: home, profile: profile, binary: versioned, runner: mismatchRunner)
            .collect()?.state == .failed(.accountMismatch))
        #expect(mismatchRunner.requests.isEmpty)
    }

    @Test("auth state is checked before usage; logout, wrong org, and wrong profile fail closed")
    func authPrecheckFailures() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let cases: [(String, UsageState)] = [
            (profileAuthJSON(profile, loggedIn: false), .unavailable(.noSignIn)),
            (profileAuthJSON(profile, org: "other-org"), .failed(.accountMismatch)),
            (profileAuthJSON(profile, configDirectory: home.appendingPathComponent("other").path),
             .unavailable(.profileInvalid)),
            ("{}", .failed(.schemaChanged)),
        ]
        for (status, expected) in cases {
            let runner = profileRunner(home: home, profile: profile, statusJSONs: [status])
            let result = try #require(
                profileCollector(home: home, profile: profile, binary: binary, runner: runner).collect())
            #expect(result.state == expected)
            #expect(runner.requests.count == 1)
        }
    }

    @Test("a signed-out status that omits the identity keys (CLI 2.1.323) reads as signed out")
    func signedOutStatusWithoutIdentityKeys() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let runner = profileRunner(home: home, profile: profile,
                                   statusJSONs: [authJSONWithoutIdentity(profile, loggedIn: false)])
        let result = try #require(
            profileCollector(home: home, profile: profile, binary: binary, runner: runner).collect())
        #expect(result.state == .unavailable(.noSignIn))
        #expect(runner.requests.count == 1)
    }

    @Test("a signed-in status that omits the identity keys still fails closed as a schema change")
    func signedInStatusWithoutIdentityKeys() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let runner = profileRunner(home: home, profile: profile,
                                   statusJSONs: [authJSONWithoutIdentity(profile, loggedIn: true)])
        let result = try #require(
            profileCollector(home: home, profile: profile, binary: binary, runner: runner).collect())
        #expect(result.state == .failed(.schemaChanged))
        #expect(runner.requests.count == 1)
    }

    @Test("identity rewrites, changed auth, or replaced directory suppress quota")
    func afterReadAttributionChecks() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let changedIdentityRunner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile)],
            onUsage: {
                try? makeClaudeProfile(profile, account: "changed-account")
            })
        let changedIdentityResult = profileCollector(home: home, profile: profile, binary: binary,
                                                     runner: changedIdentityRunner).collect()
        let changedIdentity = try #require(changedIdentityResult)
        #expect(changedIdentity.state == .failed(.accountMismatch))
        #expect(changedIdentity.windows.isEmpty)

        try makeClaudeProfile(profile)
        let changedAuthRunner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile, org: "other-org")])
        let changedAuthResult = profileCollector(home: home, profile: profile, binary: binary,
                                                 runner: changedAuthRunner).collect()
        let changedAuth = try #require(changedAuthResult)
        #expect(changedAuth.state == .failed(.accountMismatch))
        #expect(changedAuth.windows.isEmpty)

        let replacement = home.appendingPathComponent("replacement", isDirectory: true)
        try makeClaudeProfile(replacement)
        let replacedRunner = profileRunner(home: home, profile: profile,
            statusJSONs: [profileAuthJSON(profile), profileAuthJSON(profile)],
            onUsage: {
                try? FileManager.default.removeItem(at: profile)
                try? FileManager.default.moveItem(at: replacement, to: profile)
            })
        let replacedResult = profileCollector(home: home, profile: profile, binary: binary,
                                              runner: replacedRunner).collect()
        let replaced = try #require(replacedResult)
        #expect(replaced.state == .failed(.accountMismatch))
        #expect(replaced.windows.isEmpty)
    }

    @Test("a stopped usage stream has the same refused mapping as the default collector")
    func stoppedUsage() throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let runner = FakeUsageRunner()
        let auth = profileAuthJSON(profile)
        runner.respond = { request in
            if request.arguments == ["auth", "status", "--json"] {
                return UsageProcessResult(lines: [auth], outcome: .exited(0))
            }
            return UsageProcessResult(lines: [
                #"{"type":"system","subtype":"hook_started"}"#,
            ], outcome: .stopped)
        }
        let result = try #require(
            profileCollector(home: home, profile: profile, binary: binary, runner: runner).collect())
        #expect(result.state == .unavailable(.refused))
        #expect(result.windows.isEmpty)
        #expect(runner.requests.count == 3)
    }

    @Test("profile collection returns no row when cancelled between reads")
    func cancellationBetweenReads() async throws {
        let home = try profileTestDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent("profile", isDirectory: true)
        try makeClaudeProfile(profile)
        let binary = try makeProfileBinary(home: home)
        let runner = FakeUsageRunner()
        let auth = profileAuthJSON(profile)
        runner.respond = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return UsageProcessResult(lines: [auth], outcome: .exited(0))
        }
        let collector = profileCollector(home: home, profile: profile, binary: binary, runner: runner)

        let reading = await Task.detached { collector.collect() }.value
        #expect(reading == nil)
        #expect(runner.requests.count == 1)
    }

    @Test("legacy settings decode and profile bindings round-trip")
    func settingsBackwardCompatibility() throws {
        let legacy = try JSONDecoder().decode(SwitcherSettings.self, from: Data(#"{"language":"en"}"#.utf8))
        #expect(legacy.claudeUsageProfiles == nil)
        let binding = ClaudeProfileBinding(accountId: "saved", accountUuid: "account-1",
                                           orgUuid: "org-1", profilePath: "/Users/test/profile")
        var settings = SwitcherSettings()
        settings.claudeUsageProfiles = [binding]
        let roundTrip = try JSONDecoder().decode(SwitcherSettings.self,
                                                  from: JSONEncoder().encode(settings))
        #expect(roundTrip.claudeUsageProfiles == [binding])
    }

    @Test("bound readings replace only their registered saved row and stay separate from CLI")
    func presentationSubstitution() {
        let account = AccountStatus(id: "saved", label: "Current registry name",
            customName: nil, defaultName: "Current registry name", email: "saved@example.invalid",
            accountUuid: "account-1", orgUuid: "org-1", isActive: false, snapshot: .ready,
            capturedAt: nil, sessionExpiresAt: nil)
        let status = SwitcherStatus(claude: ClaudeStatus(installed: true, running: false,
            pid: nil, version: nil, activeAccountUuid: nil, activeOrgUuid: nil,
            activeEmail: nil, codeSessions: 0), accounts: [account], relaunchers: [],
            suspendedRelaunchers: [], originalBackup: nil, pendingJournal: false,
            nativeMultiAccount: false, warnings: [])
        let window = UsageWindow(scope: nil, durationMinutes: 300, usedPercent: 30,
                                 resetsAt: profileReadAt.addingTimeInterval(3600))
        let app = AccountUsage(id: "claude:app:saved", provider: .claude, accountRef: "app:saved",
            label: "stale label", plan: nil, windows: [window], state: .ok,
            readAt: profileReadAt, toolVersion: "2.1.317")
        let unregistered = AccountUsage(id: "claude:app:gone", provider: .claude,
            accountRef: "app:gone", label: "gone", plan: nil, windows: [window], state: .ok,
            readAt: profileReadAt, toolVersion: "2.1.317")
        let cli = AccountUsage(id: "claude:cli", provider: .claude, accountRef: "cli",
            label: "CLI sign-in", plan: nil, windows: [], state: .notReporting,
            readAt: profileReadAt, toolVersion: "2.1.317")
        let rows = UsagePresentations.accounts(readings: [cli, app, unregistered],
            installations: [], claude: status, codex: nil, now: profileReadAt)
        #expect(rows.map(\.id) == ["claude:cli", "claude:app:saved"])
        let saved = rows[1]
        #expect(saved.usage == app)
        #expect(saved.name == "Current registry name" && saved.owner == .claude("saved"))
        #expect(rows[0].usage.id == "claude:cli")
    }

    @Test("bound snapshot contains neither profile path nor memory-only identity")
    func snapshotExcludesProfilePath() throws {
        let profilePath = "/private/profile-directory-not-for-snapshot"
        let binding = ClaudeProfileBinding(accountId: "saved", accountUuid: "account-1",
            orgUuid: "org-1", profilePath: profilePath)
        let usage = AccountUsage(id: "claude:app:saved", provider: .claude,
            accountRef: "app:saved", label: "saved", plan: nil, windows: [], state: .ok,
            readAt: profileReadAt, toolVersion: "2.1.317", identityKey: "memory-only-marker")
        let presentation = UsageAccountPresentation(usage: usage, name: "saved", email: nil,
            environment: .app, login: .saved, badgeActive: false, owner: .claude("saved"))
        let data = try JSONEncoder().encode(UsageSnapshot(presentations: [presentation],
                                                          generatedAt: profileReadAt))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(profilePath))
        #expect(!json.contains("memory-only-marker"))
        #expect(binding.profilePath == profilePath)
    }
}
