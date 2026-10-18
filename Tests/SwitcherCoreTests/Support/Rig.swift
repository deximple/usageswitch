import Foundation
@testable import SwitcherCore

/// Standard integration world: live userData signed in as `active`, a keepalive LaunchAgent, Claude running,
/// and saved sign-ins (the account list) for `enrolled` identities.
struct Rig {
    let sandbox: Sandbox
    let world: FakeWorld
    let switcher: Switcher
    var env: SwitcherEnvironment { sandbox.env }

    static let liveNames = [SnapshotItems.config] + SnapshotItems.cookieGroup

    static func make(
        active: FakeIdentity? = .a, running: Bool = true, codeSession: FakeIdentity? = nil,
        enrolled: [FakeIdentity] = [.b], options: SwitcherOptions = SwitcherOptions(), keepalive: Bool = true,
        afterSetup: (Rig) throws -> Void = { _ in }
    ) throws -> Rig {
        let sandbox = try Sandbox()
        // A fixture step that throws must not leak the sandbox (the caller's `defer` never ran).
        var built = false
        defer { if !built { sandbox.remove() } }
        let env = sandbox.env

        try CookieFixture.make(at: env.claudeCookies, identity: active, tag: active.map { String($0.account.prefix(4)) } ?? "none")
        try ConfigFixture.make(at: env.claudeConfigJSON, lastKnown: active?.account)
        try sandbox.write("{\"device\":\"keep\"}", to: env.claudeUserData.appendingPathComponent("Preferences"))
        try sandbox.write("{\"mcpServers\":{}}", to: env.claudeUserData.appendingPathComponent("claude_desktop_config.json"))
        try sandbox.write("FAKE-LEVELDB", to: env.claudeUserData.appendingPathComponent("Local Storage/leveldb/000003.log"))

        let world = FakeWorld(env: env)
        let t = world.now()
        var lines: [(Date, String)] = [
            (t.addingTimeInterval(-3600), "[info] Starting app {"),
            (t.addingTimeInterval(-3599), "  version: '1.0.0'"),
            (t.addingTimeInterval(-3599), "}"),
        ]
        if let active {
            lines += [
                (t.addingTimeInterval(-3590), LogFixture.agentInitLine(.d)),
                (t.addingTimeInterval(-3590), LogFixture.initLine(active)),
                (t.addingTimeInterval(-600), LogFixture.cacheKeyLine(active)),
            ]
        }
        try LogFixture.appendLines(env.mainLog, lines)

        if keepalive {
            let plist = try AgentFixture.makeKeepalive(env: env, scriptsDir: sandbox.root.appendingPathComponent("bin"))
            world.addAgent(label: AgentFixture.keepaliveLabel, plist: plist)
        }
        let unrelated = try AgentFixture.writePlist(env: env, label: "com.example.backup", plist: [
            "Label": "com.example.backup", "ProgramArguments": ["/usr/bin/rsync", "-a", "Claude", "backup"],
        ])
        world.addAgent(label: "com.example.backup", plist: unrelated)
        if running { world.startClaude(codeSession: codeSession) }

        let switcher = Switcher(env: env, table: world, app: world, runner: world, clock: world, options: options,
                                freeDiskGB: { world.read { $0.freeGB } })
        let rig = Rig(sandbox: sandbox, world: world, switcher: switcher)
        for identity in enrolled { try rig.enroll(identity) }
        try afterSetup(rig)
        built = true
        return rig
    }

    /// Stores a snapshot for `identity` as if it had been captured earlier.
    @discardableResult
    func enroll(_ identity: FakeIdentity, cookieIdentity: FakeIdentity? = nil, version: Int = 24, lastCompatible: Int = 24,
                sessionExpires: Date = Date().addingTimeInterval(20 * 86400)) throws -> Snapshot {
        let source = try sandbox.scratch()
        try CookieFixture.make(at: source.appendingPathComponent("Cookies"), identity: cookieIdentity ?? identity,
                               sessionExpires: sessionExpires, version: version, lastCompatible: lastCompatible,
                               tag: String(identity.account.prefix(4)))
        return try switcher.store.capture(from: source, identity: identity.identity, claudeVersion: "1.0.0",
                                          now: world.now().addingTimeInterval(-86400))
    }

    func liveFingerprint() -> [String: Data?] { fingerprint(env.claudeUserData, Self.liveNames) }

    func cleanup() { sandbox.remove() }
}
