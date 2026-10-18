import Foundation
import Testing
@testable import SwitcherCore

@Suite("SafeFS write gateway")
struct SafeFSTests {
    @Test func allowsStoreAndExactUserDataItems() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let env = sb.env
        #expect(fs.isAllowed(env.storeDir))
        #expect(fs.isAllowed(env.snapshotsDir.appendingPathComponent("x/gen-1/Cookies")))
        #expect(fs.isAllowed(env.journalFile))
        for name in SnapshotItems.cookieGroup + [SnapshotItems.config] {
            #expect(fs.isAllowed(env.claudeUserData.appendingPathComponent(name)), "\(name)")
        }
        // UI group only when explicitly enabled.
        #expect(!fs.isAllowed(env.claudeUserData.appendingPathComponent("Local Storage")))
        let uiFS = SafeFS(env: env, allowUIGroup: true)
        for name in SnapshotItems.uiGroup { #expect(uiFS.isAllowed(env.claudeUserData.appendingPathComponent(name))) }
    }

    @Test func rejectsClaudeCLIAndOtherAppsData() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let env = sb.env
        let forbidden: [URL] = [
            env.home.appendingPathComponent(".claude/settings.json"),
            env.home.appendingPathComponent(".claude"),
            env.home.appendingPathComponent(".claude.json"),
            env.home.appendingPathComponent(".claude.json.backup"),
            OutsideFixture.otherAppDir(env).appendingPathComponent("a/b/LocalStorage/localstorage.sqlite3"),
            OutsideFixture.otherAppDir(env).appendingPathComponent("accounts/.claude.json"),
            env.claudeUserData,
            env.claudeUserData.appendingPathComponent("Preferences"),
            env.claudeUserData.appendingPathComponent("claude_desktop_config.json"),
            env.claudeUserData.appendingPathComponent("claude-code-sessions/x.json"),
            env.claudeUserData.appendingPathComponent("Local Storage/leveldb/000003.log"),
            env.claudeUserData.appendingPathComponent("Cookies/../Preferences"),
            env.storeDir.appendingPathComponent("../../../.claude.json"),
            env.storeDir.appendingPathComponent("snapshots/../../Claude/Preferences"),
            URL(fileURLWithPath: env.storeDir.path + "-evil/file"),
            env.launchAgentsDir.appendingPathComponent("com.user.claude-keepalive.plist"),
            URL(fileURLWithPath: "/etc/hosts"),
        ]
        for url in forbidden {
            #expect(!fs.isAllowed(url), "\(url.path)")
            #expect(switcherError { try fs.check(url) } == .forbiddenWrite(url.path))
        }
    }

    @Test func rejectsSymlinkEscapes() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let env = sb.env
        let fm = FileManager.default
        try fm.createDirectory(at: env.storeDir, withIntermediateDirectories: true)
        let claudeDir = env.home.appendingPathComponent(".claude", isDirectory: true)
        // Directory symlink inside the store pointing at ~/.claude.
        let link = env.storeDir.appendingPathComponent("evil")
        try fm.createSymbolicLink(at: link, withDestinationURL: claudeDir)
        #expect(!fs.isAllowed(link.appendingPathComponent("settings.json")))
        #expect(switcherError { try fs.write(Data("x".utf8), to: link.appendingPathComponent("settings.json")) }
            == .forbiddenWrite(link.appendingPathComponent("settings.json").path))
        #expect(!exists(claudeDir.appendingPathComponent("settings.json")))
        // Allowed userData name that is really a symlink to ~/.claude.json.
        let cliConfig = env.home.appendingPathComponent(".claude.json")
        try OutsideFixture.writeCLIConfig(cliConfig, identity: .a)
        let before = fileData(cliConfig)
        let cfg = env.claudeUserData.appendingPathComponent("config.json")
        try fm.createSymbolicLink(at: cfg, withDestinationURL: cliConfig)
        #expect(!fs.isAllowed(cfg))
        #expect(switcherError { try fs.remove(cfg) } != nil)
        #expect(fileData(cliConfig) == before)
        // Symlinked userData parent: same verdicts after resolution.
        let alias = sb.root.appendingPathComponent("alias-userdata")
        try fm.createSymbolicLink(at: alias, withDestinationURL: env.claudeUserData)
        #expect(fs.isAllowed(alias.appendingPathComponent("Cookies")))
        #expect(!fs.isAllowed(alias.appendingPathComponent("Preferences")))
    }

    @Test func danglingSymlinkInStoreCannotWriteOutside() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let fm = FileManager.default
        try fs.createDirectory(sb.env.storeDir)
        let outside = try sb.scratch("outside")
        let target = outside.appendingPathComponent("planted")
        let link = sb.env.storeDir.appendingPathComponent("dangling")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let src = outside.appendingPathComponent("src")
        try Data("payload".utf8).write(to: src)
        _ = switcherError { try fs.write(Data("x".utf8), to: link) }
        #expect(!exists(target))
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        _ = switcherError { try fs.copy(src, to: link) }
        #expect(!exists(target))
    }

    @Test func writeIsAtomicOwnerOnly() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        try fs.createDirectory(sb.env.storeDir)
        #expect(posixPermissions(sb.env.storeDir) == 0o700)
        let file = sb.env.storeDir.appendingPathComponent("a.json")
        try fs.write(Data("one".utf8), to: file)
        try fs.write(Data("two".utf8), to: file)
        #expect(fileData(file) == Data("two".utf8))
        #expect(posixPermissions(file) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sb.env.storeDir.path)
        #expect(leftovers == ["a.json"])
        // Explicit permissions are honoured; a missing parent is an io error, not a crash.
        try fs.write(Data("x".utf8), to: sb.env.storeDir.appendingPathComponent("b"), permissions: 0o644)
        #expect(posixPermissions(sb.env.storeDir.appendingPathComponent("b")) == 0o644)
        let err = switcherError { try fs.write(Data("x".utf8), to: sb.env.storeDir.appendingPathComponent("no/such/c")) }
        guard case .io = err else { Issue.record("expected io, got \(String(describing: err))"); return }
    }

    @Test func copyMoveSwapRemove() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let env = sb.env
        try fs.createDirectory(env.storeDir)
        let srcDir = try sb.scratch("tree")
        try sb.write("leaf", to: srcDir.appendingPathComponent("sub/leaf.txt"))
        let dstDir = env.storeDir.appendingPathComponent("tree")
        try fs.copy(srcDir, to: dstDir)
        try fs.copy(srcDir, to: dstDir) // replaces existing
        #expect(posixPermissions(dstDir) == 0o700)
        #expect(posixPermissions(dstDir.appendingPathComponent("sub")) == 0o700)
        #expect(posixPermissions(dstDir.appendingPathComponent("sub/leaf.txt")) == 0o600)
        #expect(fileData(srcDir.appendingPathComponent("sub/leaf.txt")) == Data("leaf".utf8))

        let a = env.storeDir.appendingPathComponent("a")
        let b = env.storeDir.appendingPathComponent("b")
        try fs.write(Data("A".utf8), to: a)
        try fs.write(Data("B".utf8), to: b)
        try fs.swap(a, b)
        #expect(fileData(a) == Data("B".utf8))
        #expect(fileData(b) == Data("A".utf8))
        let missing = env.storeDir.appendingPathComponent("missing")
        guard case .io = switcherError({ try fs.swap(a, missing) }) else { Issue.record("swap missing"); return }
        guard case .io = switcherError({ try fs.move(missing, to: a) }) else { Issue.record("move missing"); return }
        let c = env.storeDir.appendingPathComponent("c")
        try fs.move(a, to: c)
        #expect(!exists(a) && exists(c))
        try fs.remove(c)
        try fs.remove(c) // absent is fine
        #expect(!exists(c))
        try fs.restrictPermissions(missing) // absent is fine

        // Source outside is only read; destination outside is refused.
        let outside = try sb.scratch("out").appendingPathComponent("copy")
        #expect(switcherError { try fs.copy(b, to: outside) } == .forbiddenWrite(outside.path))
        #expect(switcherError { try fs.move(b, to: outside) } == .forbiddenWrite(outside.path))
        #expect(switcherError { try fs.createDirectory(env.home.appendingPathComponent(".claude/x")) } != nil)
        guard case .io = switcherError({ try fs.copy(env.storeDir.appendingPathComponent("nope"), to: c) }) else {
            Issue.record("copy of missing source"); return
        }
        #expect(!exists(outside))
    }

    @Test func restrictingACopiedTreeNeverFollowsSymlinksOutOfTheStore() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        let fm = FileManager.default
        try fs.createDirectory(sb.env.storeDir)
        let outside = try sb.scratch("outside")
        let outsideFile = outside.appendingPathComponent("target.txt")
        try Data("outside".utf8).write(to: outsideFile)
        let outsideDir = outside.appendingPathComponent("dir", isDirectory: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        _ = chmod(outsideFile.path, 0o644)
        _ = chmod(outsideDir.path, 0o755)
        // A source tree (e.g. Claude's userData item) holding links that point out of the store.
        let src = try sb.scratch("tree")
        try sb.write("leaf", to: src.appendingPathComponent("sub/leaf.txt"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("sub/file-link"), withDestinationURL: outsideFile)
        try fm.createSymbolicLink(at: src.appendingPathComponent("dir-link"), withDestinationURL: outsideDir)
        let dst = sb.env.storeDir.appendingPathComponent("tree")
        try fs.copy(src, to: dst)
        // The copy keeps the links as links, restricts the real entries, and leaves the link targets alone.
        let copiedLink = dst.appendingPathComponent("sub/file-link")
        #expect(try fm.destinationOfSymbolicLink(atPath: copiedLink.path) == outsideFile.path)
        #expect(posixPermissions(dst.appendingPathComponent("sub/leaf.txt")) == 0o600)
        #expect(posixPermissions(dst.appendingPathComponent("sub")) == 0o700)
        #expect(posixPermissions(outsideFile) == 0o644)
        #expect(posixPermissions(outsideDir) == 0o755)
        #expect(fileData(outsideFile) == Data("outside".utf8))
    }

    @Test func createDirectoryFailureIsIOError() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let fs = sb.fs
        try fs.createDirectory(sb.env.storeDir)
        let file = sb.env.storeDir.appendingPathComponent("file")
        try fs.write(Data("x".utf8), to: file)
        guard case .io = switcherError({ try fs.createDirectory(file.appendingPathComponent("sub")) }) else {
            Issue.record("expected io"); return
        }
    }
}
