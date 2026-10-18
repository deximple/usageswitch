import Foundation
import Testing
@testable import SwitcherCore

/// A throwaway directory tree that mirrors the real layout. Every URL of `env` lives inside `root`;
/// nothing under the real home directory is ever read or written.
final class Sandbox: @unchecked Sendable {
    let root: URL
    let env: SwitcherEnvironment

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory
            .appendingPathComponent("cdsw-tests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        env = SwitcherEnvironment(
            home: home,
            claudeAppURL: root.appendingPathComponent("Applications/Claude.app", isDirectory: true),
            claudeUserData: appSupport.appendingPathComponent("Claude", isDirectory: true),
            claudeLogsDir: home.appendingPathComponent("Library/Logs/Claude", isDirectory: true),
            launchAgentsDir: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            storeDir: appSupport.appendingPathComponent("com.jaysong.usageswitch", isDirectory: true)
        )
        precondition(root.path.hasPrefix(fm.temporaryDirectory.path))
        do {
            for dir in [env.claudeUserData, env.claudeLogsDir, env.launchAgentsDir,
                        env.claudeMainExecutable.deletingLastPathComponent(),
                        home.appendingPathComponent(".claude", isDirectory: true)] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data("#!/bin/sh\n".utf8).write(to: env.claudeMainExecutable)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var fs: SafeFS { SafeFS(env: env) }

    /// A scratch directory outside every allowlisted location.
    func scratch(_ name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent("scratch/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

// MARK: - Identities (fake values only)

struct FakeIdentity: Sendable {
    let account: String
    let org: String
    let email: String
    let name: String

    var identity: AccountIdentity { AccountIdentity(accountUuid: account, orgUuid: org, email: email, displayName: name) }
    /// The account id the switcher uses for this identity.
    var key: String { identity.key }
    var fixtureValue: String { "\(account)|\(org)" }

    static let a = FakeIdentity(
        account: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", org: "aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa",
        email: "fake.20@example.com", name: "Fake Twenty")
    static let b = FakeIdentity(
        account: "bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb", org: "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb",
        email: "fake.21@example.com", name: "Fake TwentyOne")
    static let c = FakeIdentity(
        account: "cccccccc-1111-4111-8111-cccccccccccc", org: "cccccccc-2222-4222-8222-cccccccccccc",
        email: "fake.c@example.com", name: "Fake C")
    static let d = FakeIdentity(
        account: "dddddddd-1111-4111-8111-dddddddddddd", org: "dddddddd-2222-4222-8222-dddddddddddd",
        email: "fake.d@example.com", name: "Fake D")
    static let clientUuid = "eeeeeeee-3333-4333-8333-eeeeeeeeeeee"
}

// MARK: - Helpers

/// Runs `body` and returns the SwitcherError it threw (nil when it did not throw).
func switcherError(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) -> SwitcherError? {
    do {
        try body()
        return nil
    } catch let e as SwitcherError {
        return e
    } catch {
        Issue.record("unexpected non-SwitcherError: \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

func fileData(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func posixPermissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

func jsonObject(_ url: URL) throws -> [String: Any] {
    let data = try #require(fileData(url))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Byte-for-byte picture of the given items, keyed by name (nil = absent).
func fingerprint(_ dir: URL, _ names: [String]) -> [String: Data?] {
    var out: [String: Data?] = [:]
    for n in names { out[n] = fileData(dir.appendingPathComponent(n)) }
    return out
}

/// A controllable stand-in for "is any Claude process running?" (SwapEngine's `isClaudeRunning`).
/// `startAfter(n)` makes Claude appear on the n-th check from now; `stop()` makes it go away.
final class ClaudeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var remaining: Int?
    private(set) var checks = 0

    func check() -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        if let r = remaining {
            if r <= 1 { running = true; remaining = nil } else { remaining = r - 1 }
        }
        return running
    }

    func startAfter(_ n: Int) { lock.lock(); remaining = n; lock.unlock() }
    func start() { lock.lock(); running = true; remaining = nil; lock.unlock() }
    func stop() { lock.lock(); running = false; remaining = nil; lock.unlock() }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}
