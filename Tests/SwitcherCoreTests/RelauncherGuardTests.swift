import Foundation
import Testing
@testable import SwitcherCore

@Suite("RelauncherGuard")
struct RelauncherGuardTests {
    struct Setup {
        let sb: Sandbox
        let world: FakeWorld
        let guardian: RelauncherGuard
        let keepalivePlist: URL
    }

    func setup() throws -> Setup {
        let sb = try Sandbox()
        var built = false
        defer { if !built { sb.remove() } }
        let env = sb.env
        let bin = sb.root.appendingPathComponent("bin")
        let keepalive = try AgentFixture.makeKeepalive(env: env, scriptsDir: bin)
        // Program key + direct `open …Claude.app`.
        try AgentFixture.writePlist(env: env, label: "com.user.claude-opener", plist: [
            "Label": "com.user.claude-opener", "Program": "/usr/bin/open",
            "ProgramArguments": ["open", env.claudeAppURL.path],
        ])
        // Unrelated agents: a Safari opener script, a non-open command, a plist without Label, junk files.
        let safari = bin.appendingPathComponent("safari.sh")
        try Data("#!/bin/sh\nopen -a Safari https://example.com\n".utf8).write(to: safari)
        try AgentFixture.writePlist(env: env, label: "com.example.safari", plist: [
            "Label": "com.example.safari", "ProgramArguments": ["/bin/sh", safari.path],
        ])
        try AgentFixture.writePlist(env: env, label: "com.example.backup", plist: [
            "Label": "com.example.backup", "ProgramArguments": ["/usr/bin/rsync", "-a", "Claude", "backup"],
        ])
        // This app's own launcher must never be mistaken for a Claude relauncher.
        let switcherScript = bin.appendingPathComponent("switcher.sh")
        try Data("#!/bin/sh\nopen -a \"Claude Switcher\"\nopen '/Applications/Claude Switcher.app'\n".utf8).write(to: switcherScript)
        try AgentFixture.writePlist(env: env, label: "com.jaysong.claude-switcher.opener", plist: [
            "Label": "com.jaysong.claude-switcher.opener", "ProgramArguments": ["/bin/sh", switcherScript.path],
        ])
        try AgentFixture.writePlist(env: env, label: "com.example.nolabel", plist: [
            "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
        ])
        try Data("not a plist".utf8).write(to: env.launchAgentsDir.appendingPathComponent("broken.plist"))
        try Data("open -a Claude".utf8).write(to: env.launchAgentsDir.appendingPathComponent("notes.txt"))
        let world = FakeWorld(env: env)
        world.addAgent(label: AgentFixture.keepaliveLabel, plist: keepalive)
        world.addAgent(label: "com.user.claude-opener",
                       plist: env.launchAgentsDir.appendingPathComponent("com.user.claude-opener.plist"), loaded: false)
        built = true
        return Setup(sb: sb, world: world, guardian: RelauncherGuard(env: env, fs: sb.fs, runner: world),
                     keepalivePlist: keepalive)
    }

    @Test func discoversOnlyClaudeRelaunchers() throws {
        let s = try setup(); defer { s.sb.remove() }
        #expect(s.guardian.discover().map(\.label) == ["com.user.claude-keepalive", "com.user.claude-opener"])
        #expect(s.guardian.discover().first?.plistPath == s.keepalivePlist.path)
    }

    @Test func discoverWithoutLaunchAgentsDirIsEmpty() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try FileManager.default.removeItem(at: sb.env.launchAgentsDir)
        #expect(RelauncherGuard(env: sb.env, fs: sb.fs, runner: FakeWorld(env: sb.env)).discover().isEmpty)
    }

    @Test func timedOutScriptReadStopsSuspendBeforeBootout() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let label = "com.user.claude-stalled"
        let scriptsDir = sb.root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let script = scriptsDir.appendingPathComponent("\(label).sh")
        try Data("open -a Claude\n".utf8).write(to: script)
        let plist = try AgentFixture.writePlist(env: sb.env, label: label, plist: [
            "Label": label, "ProgramArguments": ["/bin/sh", script.path],
        ])
        let world = FakeWorld(env: sb.env)
        world.addAgent(label: label, plist: plist, loaded: true)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = BoundedReader(timeout: 0.2) { path in
            if path == script.path {
                release.wait()
                return Data("open -a Claude\n".utf8)
            }
            return BoundedReader.readSmallText(path)
        }
        let guardian = RelauncherGuard(env: sb.env, fs: sb.fs, runner: world, reader: reader)

        let error = switcherError { _ = try guardian.suspendAll() }
        guard case let .io(message)? = error else {
            Issue.record("expected an unverified relauncher error")
            return
        }
        #expect(message == L10n.t(.reasonRelauncherUnverified, "\(label).plist"))
        #expect(world.read { state in
            state.commands.filter { $0.count > 1 && $0[1] == "bootout" }.isEmpty
        })
        #expect(guardian.discover().isEmpty)
    }

    @Test(arguments: [
        ("pgrep -x Claude || open -g -a Claude", true),
        ("open -g -a \"Claude\"", true),
        ("open -a 'Claude'\nsleep 1", true),
        ("/usr/bin/open /Applications/Claude.app", true),
        ("open -a Safari", false),
        ("open -a ClaudeHelper", false),
        ("echo Claude; open -a Notes", false),
        ("rsync Claude.app backup", false),
        ("open -a Claude.app", true),
        ("open -a \"/Applications/Claude.app\"", true),
        ("open -g -a Claude; sleep 30", true),
        ("x=1\nopen -a Claude", true),
        // This switcher (and anything else merely named "Claude …") is not a Claude relauncher.
        ("open -a \"Claude Switcher\"", false),
        ("open -a 'Claude Switcher'", false),
        ("open \"/Applications/Claude Switcher.app\"", false),
        ("open -a /Applications/Claude\\ Switcher.app", false),
        ("open -b com.jaysong.claude-switcher # Claude", false),
        ("open -a ClaudeSwitcher.app", false),
    ])
    func relaunchPattern(text: String, expected: Bool) {
        #expect(RelauncherGuard.relaunchesClaude(text) == expected)
    }

    @Test func suspendWritesJournalBeforeBootoutAndOnlyTouchesLoadedAgents() throws {
        let s = try setup(); defer { s.sb.remove() }
        let suspended = try s.guardian.suspendAll()
        #expect(suspended.map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(!s.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(s.world.read { $0.journalHadLabelAtBootout } == [AgentFixture.keepaliveLabel: true])
        #expect(s.guardian.journal().map(\.label) == [AgentFixture.keepaliveLabel])
        let uid = s.sb.env.uid
        let commands = s.world.read { $0.commands }
        #expect(commands.contains(["/bin/launchctl", "bootout", "gui/\(uid)/\(AgentFixture.keepaliveLabel)"]))
        #expect(!commands.contains(["/bin/launchctl", "bootout", "gui/\(uid)/com.user.claude-opener"]))
        // Plists are never edited.
        #expect(try PropertyListSerialization.propertyList(from: fileData(s.keepalivePlist)!, format: nil) is [String: Any])
        // Suspending again with nothing loaded keeps the journal intact.
        #expect(try s.guardian.suspendAll().isEmpty)
        #expect(s.guardian.journal().map(\.label) == [AgentFixture.keepaliveLabel])
    }

    @Test func plistAndScriptBytesAreUnchangedBySuspendAndRestore() throws {
        let s = try setup(); defer { s.sb.remove() }
        let agents = try FileManager.default.contentsOfDirectory(atPath: s.sb.env.launchAgentsDir.path).sorted()
        let plists = fingerprint(s.sb.env.launchAgentsDir, agents)
        let script = s.sb.root.appendingPathComponent("bin/\(AgentFixture.keepaliveLabel).sh")
        let scriptBytes = try #require(fileData(script))
        _ = try s.guardian.suspendAll()
        #expect(fingerprint(s.sb.env.launchAgentsDir, agents) == plists)
        #expect(s.guardian.restoreAll().map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(fingerprint(s.sb.env.launchAgentsDir, agents) == plists)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.sb.env.launchAgentsDir.path).sorted() == agents)
        #expect(fileData(script) == scriptBytes)
    }

    @Test func binaryProgramsAndHugeLinesAreNotScanned() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let bin = try sb.scratch("bin")
        let binary = bin.appendingPathComponent("tool")
        try (Data([0x7F, 0x45, 0x4C, 0x46, 0]) + Data("open -a Claude".utf8)).write(to: binary)
        try AgentFixture.writePlist(env: sb.env, label: "com.example.binary", plist: [
            "Label": "com.example.binary", "ProgramArguments": [binary.path],
        ])
        #expect(RelauncherGuard(env: sb.env, fs: sb.fs, runner: FakeWorld(env: sb.env)).discover().isEmpty)
        #expect(!RelauncherGuard.relaunchesClaude(String(repeating: "x", count: 5000) + " open -a Claude"))
    }

    @Test func restoreAllBootstrapsAndClearsJournal() throws {
        let s = try setup(); defer { s.sb.remove() }
        _ = try s.guardian.suspendAll()
        let restored = s.guardian.restoreAll()
        #expect(restored.map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(s.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(s.world.read { $0.commands }.contains(
            ["/bin/launchctl", "bootstrap", "gui/\(s.sb.env.uid)", s.keepalivePlist.path]))
        #expect(s.guardian.journal().isEmpty)
        #expect(!exists(s.sb.env.relauncherJournalFile))
        #expect(s.guardian.restoreAll().isEmpty) // idempotent
    }

    @Test func failedBootstrapStaysJournaled() throws {
        let s = try setup(); defer { s.sb.remove() }
        _ = try s.guardian.suspendAll()
        s.world.update { $0.bootstrapFails = [AgentFixture.keepaliveLabel] }
        #expect(s.guardian.restoreAll().isEmpty)
        #expect(s.guardian.journal().map(\.label) == [AgentFixture.keepaliveLabel])
        s.world.update { $0.bootstrapFails = [] }
        #expect(s.guardian.restoreAll().map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(s.guardian.journal().isEmpty)
    }

    @Test func failedBootoutThrows() throws {
        let s = try setup(); defer { s.sb.remove() }
        s.world.update { $0.bootoutFails = [AgentFixture.keepaliveLabel] }
        guard case .io = switcherError({ _ = try s.guardian.suspendAll() }) else { Issue.record("expected io"); return }
        #expect(s.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    @Test func corruptJournalReadsAsEmptyAndIsNeverActedOnOrDeleted() throws {
        let s = try setup(); defer { s.sb.remove() }
        #expect(!s.guardian.journalIsUnreadable()) // no journal at all
        _ = try s.guardian.suspendAll()
        #expect(!s.guardian.journalIsUnreadable()) // a valid journal
        try s.sb.fs.write(Data("{".utf8), to: s.sb.env.relauncherJournalFile)
        #expect(s.guardian.journal().isEmpty)
        #expect(s.guardian.journalIsUnreadable())
        let commandsBefore = s.world.read { $0.commands.count }
        #expect(s.guardian.restoreAll().isEmpty)
        // Kept byte-identical for inspection; launchctl was not even asked.
        #expect(fileData(s.sb.env.relauncherJournalFile) == Data("{".utf8))
        #expect(s.world.read { $0.commands.count } == commandsBefore)
        #expect(!s.world.isAgentLoaded(AgentFixture.keepaliveLabel))
    }

    /// The journal lives in the switcher's store; an entry pointing anywhere else (or at a plist whose label
    /// changed) must never be bootstrapped from it.
    @Test func restoreAllIgnoresEntriesOutsideLaunchAgentsOrWithAnotherLabel() throws {
        let s = try setup(); defer { s.sb.remove() }
        let env = s.sb.env
        _ = try s.guardian.suspendAll()
        // A plist in a subdirectory of LaunchAgents, one outside it, and one in place whose Label differs.
        let nestedDir = env.launchAgentsDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nested = nestedDir.appendingPathComponent("com.evil.nested.plist")
        let outside = try s.sb.scratch("agents").appendingPathComponent("com.evil.outside.plist")
        for (url, label) in [(nested, "com.evil.nested"), (outside, "com.evil.outside")] {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "Label": label, "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
            ], format: .xml, options: 0)
            try data.write(to: url)
            s.world.addAgent(label: label, plist: url, loaded: false)
        }
        let renamed = try AgentFixture.writePlist(env: env, label: "com.evil.renamed", plist: [
            "Label": "com.evil.actual", "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
        ])
        s.world.addAgent(label: "com.evil.renamed", plist: renamed, loaded: false)
        let missing = env.launchAgentsDir.appendingPathComponent("com.evil.gone.plist")
        let planted = s.guardian.journal() + [
            Relauncher(label: "com.evil.nested", plistPath: nested.path),
            Relauncher(label: "com.evil.outside", plistPath: outside.path),
            Relauncher(label: "com.evil.renamed", plistPath: renamed.path),
            Relauncher(label: "com.evil.gone", plistPath: missing.path),
        ]
        try s.sb.fs.write(try JSONEncoder().encode(planted), to: env.relauncherJournalFile)

        #expect(s.guardian.restoreAll().map(\.label) == [AgentFixture.keepaliveLabel])
        #expect(s.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        let bootstraps = s.world.read { $0.commands }.filter { $0.count > 1 && $0[1] == "bootstrap" }
        #expect(bootstraps == [["/bin/launchctl", "bootstrap", "gui/\(env.uid)", s.keepalivePlist.path]])
        for label in ["com.evil.nested", "com.evil.outside", "com.evil.renamed"] {
            #expect(!s.world.isAgentLoaded(label), "\(label)")
        }
        // Untrusted entries are never bootstrapped, but stay recorded so status() can report them.
        #expect(Set(s.guardian.journal().map(\.label)) == ["com.evil.nested", "com.evil.outside", "com.evil.renamed", "com.evil.gone"])
        #expect(Set(s.guardian.untrustedEntries().map(\.label)) == Set(s.guardian.journal().map(\.label)))
    }

    // MARK: - Bounded plist reads and the status scan cache (audit A-02)

    @Test func aPlistLargerThanOneMebibyteIsSkipped() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let label = "com.user.claude-huge"
        let plist = try AgentFixture.writePlist(env: sb.env, label: label, plist: [
            "Label": label, "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
            "Padding": String(repeating: "x", count: 1_100_000),
        ])
        #expect(((try? FileManager.default.attributesOfItem(atPath: plist.path)[.size]) as? Int ?? 0) > 1_048_576)
        #expect(RelauncherGuard(env: sb.env, fs: sb.fs, runner: FakeWorld(env: sb.env)).discover().isEmpty)
    }

    @Test func aPlistThatIsASymlinkToDevZeroDoesNotStallTheScan() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: sb.env.launchAgentsDir.appendingPathComponent("zero.plist").path, withDestinationPath: "/dev/zero")
        let guardian = RelauncherGuard(env: sb.env, fs: sb.fs, runner: FakeWorld(env: sb.env))
        let started = Date()
        let result = guardian.scan()
        #expect(result.relaunchers.isEmpty)
        #expect(result.unverified.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    struct CountingSetup {
        let sb: Sandbox
        let guardian: RelauncherGuard
        let script: URL
        let plist: URL
        let reads: ReadCounter
    }

    func countingSetup() throws -> CountingSetup {
        let sb = try Sandbox()
        let label = "com.user.claude-counted"
        let scriptsDir = sb.root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let script = scriptsDir.appendingPathComponent("\(label).sh")
        try Data("open -a Claude\n".utf8).write(to: script)
        let plist = try AgentFixture.writePlist(env: sb.env, label: label, plist: [
            "Label": label, "ProgramArguments": [script.path],
        ])
        let world = FakeWorld(env: sb.env)
        world.addAgent(label: label, plist: plist, loaded: true)
        let reads = ReadCounter()
        let reader = BoundedReader { path in
            reads.record(path)
            return BoundedReader.readSmallText(path)
        }
        return CountingSetup(sb: sb, guardian: RelauncherGuard(env: sb.env, fs: sb.fs, runner: world, reader: reader),
                             script: script, plist: plist, reads: reads)
    }

    @Test func discoverReusesAScanWhileNothingChanged() throws {
        let s = try countingSetup(); defer { s.sb.remove() }
        #expect(s.guardian.discover().map(\.label) == ["com.user.claude-counted"])
        #expect(s.guardian.discover().map(\.label) == ["com.user.claude-counted"])
        #expect(s.reads.count(s.script.path) == 1)
    }

    @Test func aSmallBinaryArgumentStillLetsTheScanBeCached() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let label = "com.user.claude-binary"
        let binary = sb.root.appendingPathComponent("helper.bin")
        var payload = Data("helper\u{0}bytes".utf8)
        payload.append(Data(count: 1024 - payload.count))
        try payload.write(to: binary)
        try AgentFixture.writePlist(env: sb.env, label: label, plist: [
            "Label": label, "ProgramArguments": [binary.path],
        ])
        let world = FakeWorld(env: sb.env)
        world.addAgent(label: label, plist: binary, loaded: true)
        let reads = ReadCounter()
        let reader = BoundedReader { path in
            reads.record(path)
            return BoundedReader.readBounded(path, limit: 65_536, allowBinary: true)
        }
        let guardian = RelauncherGuard(env: sb.env, fs: sb.fs, runner: world, reader: reader)
        // A binary arg is read as data, skipped on content, and is not a Claude relauncher —
        // so the scan succeeds and is cached like any clean scan.
        #expect(guardian.discover().isEmpty)
        #expect(guardian.discover().isEmpty)
        #expect(reads.count(binary.path) == 1)
    }

    @Test func discoverRescansWhenAPlistChanges() throws {
        let s = try countingSetup(); defer { s.sb.remove() }
        _ = s.guardian.discover()
        try AgentFixture.writePlist(env: s.sb.env, label: "com.user.claude-counted", plist: [
            "Label": "com.user.claude-counted", "ProgramArguments": ["/bin/echo", "nothing to see"],
        ])
        #expect(s.guardian.discover().isEmpty)
    }

    @Test func discoverRescansWhenAPlistIsAdded() throws {
        let s = try countingSetup(); defer { s.sb.remove() }
        _ = s.guardian.discover()
        try AgentFixture.writePlist(env: s.sb.env, label: "com.user.claude-second", plist: [
            "Label": "com.user.claude-second", "ProgramArguments": ["/usr/bin/open", "-a", "Claude"],
        ])
        #expect(s.guardian.discover().map(\.label) == ["com.user.claude-counted", "com.user.claude-second"])
    }

    @Test func discoverRescansWhenAReferencedScriptChanges() throws {
        let s = try countingSetup(); defer { s.sb.remove() }
        _ = s.guardian.discover()
        try Data("open -a Safari\n".utf8).write(to: s.script)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: s.script.path)
        #expect(s.guardian.discover().isEmpty)
        #expect(s.reads.count(s.script.path) == 2)
    }

    @Test func aScanWithAFailedReadIsNotRemembered() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let label = "com.user.claude-flaky"
        let script = sb.root.appendingPathComponent("flaky.sh")
        try Data("open -a Claude\n".utf8).write(to: script)
        try AgentFixture.writePlist(env: sb.env, label: label, plist: ["Label": label, "ProgramArguments": [script.path]])
        let reads = ReadCounter()
        // The first read of the script fails although the file is small and readable.
        let reader = BoundedReader { path in
            reads.record(path)
            return path == script.path && reads.count(path) == 1 ? nil : BoundedReader.readSmallText(path)
        }
        let guardian = RelauncherGuard(env: sb.env, fs: sb.fs, runner: FakeWorld(env: sb.env), reader: reader)
        #expect(guardian.discover().isEmpty)
        #expect(guardian.discover().map(\.label) == [label])
    }

    @Test func suspendAllAlwaysScansFresh() throws {
        let s = try countingSetup(); defer { s.sb.remove() }
        _ = s.guardian.discover()
        _ = s.guardian.discover()
        #expect(try s.guardian.suspendAll().map(\.label) == ["com.user.claude-counted"])
        #expect(s.reads.count(s.script.path) == 2)
    }

    @Test func uniquedKeepsFirstOccurrenceOrder() {
        #expect([3, 1, 3, 2, 1].uniqued() == [3, 1, 2])
    }
}

final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]

    func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        paths[path, default: 0] += 1
    }

    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return paths[path] ?? 0
    }
}
