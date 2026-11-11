import Darwin
import Foundation
import Testing
@testable import SwitcherCore

@Suite("Processes")
struct ProcessesTests {
    /// Synthetic KERN_PROCARGS2 buffer: argc, exec path, NUL padding, argv[argc], envp, trailing apple strings.
    static func procArgs(argc: Int32, exec: String, argv: [String], envp: [String], padding: Int = 3) -> [UInt8] {
        var buf = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        buf += Array(exec.utf8) + [0] + Array(repeating: 0, count: padding)
        for a in argv { buf += Array(a.utf8) + [0] }
        for e in envp { buf += Array(e.utf8) + [0] }
        return buf
    }

    @Test func parsesOnlyRequestedEnvironmentKeys() {
        let buf = Self.procArgs(
            argc: 3, exec: "/fake/claude", argv: ["claude", "--output-format", "stream-json"],
            envp: ["HOME=/fake/home", "CLAUDE_CODE_ACCOUNT_UUID=\(FakeIdentity.a.account)",
                   "CLAUDE_CODE_OAUTH_TOKEN=FAKE-OAUTH-0001", "CLAUDE_CODE_USER_EMAIL=fake.20@example.com",
                   "WEIRD=a=b=c", "NOEQUALS"])
        let out = SystemProcessTable.parseProcArgs(buf, keys: ["CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_USER_EMAIL", "WEIRD", "ABSENT"])
        #expect(out == [
            "CLAUDE_CODE_ACCOUNT_UUID": FakeIdentity.a.account, "CLAUDE_CODE_USER_EMAIL": "fake.20@example.com",
            "WEIRD": "a=b=c",
        ])
        #expect(out["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test func argvIsNeverMistakenForEnvironment() {
        let buf = Self.procArgs(argc: 2, exec: "/x", argv: ["CLAUDE_CONFIG_DIR=/argv/value", ""],
                                envp: ["CLAUDE_CONFIG_DIR=/env/value"], padding: 0)
        #expect(SystemProcessTable.parseProcArgs(buf, keys: ["CLAUDE_CONFIG_DIR"]) == ["CLAUDE_CONFIG_DIR": "/env/value"])
    }

    @Test func stopsAtEmptyStringAndToleratesTruncation() {
        var buf = Self.procArgs(argc: 1, exec: "/x", argv: ["x"], envp: ["A=1"])
        buf += [0] + Array("B=2".utf8) + [0] // empty string ends envp; apple strings follow
        #expect(SystemProcessTable.parseProcArgs(buf, keys: ["A", "B"]) == ["A": "1"])
        #expect(SystemProcessTable.parseProcArgs([1, 0, 0], keys: ["A"]).isEmpty)
        let truncated = Array(Self.procArgs(argc: 5, exec: "/x", argv: ["a"], envp: []).prefix(9))
        #expect(SystemProcessTable.parseProcArgs(truncated, keys: ["A"]).isEmpty)
        let unterminated = Self.procArgs(argc: 0, exec: "/x", argv: [], envp: []) + Array("A=tail".utf8)
        #expect(SystemProcessTable.parseProcArgs(unterminated, keys: ["A"]) == ["A": "tail"])
    }

    @Test func parsesEnvironmentNamesOnly() {
        let buf = Self.procArgs(argc: 1, exec: "/x", argv: ["CLAUDE_CONFIG_DIR=/argv"],
                                envp: ["HOME=/h", "CLAUDE_CONFIG_DIR=/secret/path", "NOEQUALS", "A=b=c"])
        #expect(SystemProcessTable.parseProcArgNames(buf) == ["HOME", "CLAUDE_CONFIG_DIR", "A"])
        #expect(SystemProcessTable.parseProcArgNames([0, 0]).isEmpty)
    }

    @Test func leakedLaunchKeysAreNamesOnly() {
        struct NamesTable: ProcessTable {
            func all() -> [ProcInfo]? { [] }
            func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] { [:] }
            func environmentNames(pid: pid_t) -> Set<String> { ["HOME", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"] }
        }
        let main = Self.p(100, 1, "Claude", Self.exe)
        #expect(ClaudeProcesses(table: NamesTable(), mainExecutable: Self.exe).leakedLaunchKeys(main: main)
            == ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"])
        // Tables that cannot list names report nothing (protocol default).
        #expect(ClaudeProcesses(table: StaticTable(procs: []), mainExecutable: Self.exe).leakedLaunchKeys(main: main).isEmpty)
    }

    @Test func leakedLaunchKeysMatchExactNamesAndToolPrefixes() {
        struct NamesTable: ProcessTable {
            func all() -> [ProcInfo]? { [] }
            func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] { [:] }
            func environmentNames(pid: pid_t) -> Set<String> {
                ["HOME", "PATH", "CLAUDE_CODE_SSE_PORT", "CLAUDECODE", "CLAUDECODE_X", "OTHERTOOL_SESSION", "ANTHROPIC_MODEL",
                 "CLAUDE_CONFIG_DIR", "MY_CLAUDE_HOME", "XANTHROPIC_", "CLAUDE", "OTHERTOOL", "claude_code_lower"]
            }
        }
        let main = Self.p(100, 1, "Claude", Self.exe)
        #expect(ClaudeProcesses(table: NamesTable(), mainExecutable: Self.exe).leakedLaunchKeys(main: main) == [
            "CLAUDE_CODE_SSE_PORT", "CLAUDECODE", "CLAUDECODE_X", "ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR",
        ])
        #expect(ClaudeProcesses.forbiddenLaunchPrefixes == ["CLAUDE_", "CLAUDECODE", "ANTHROPIC_"])
    }

    @Test func launchEnvironmentIsDockLike() throws {
        let clean = SystemClaudeAppControl.cleanEnvironment(from: [
            "HOME": "/h", "USER": "u", "LOGNAME": "l", "SHELL": "/opt/evil/sh", "TMPDIR": "/t",
            "CLAUDE_CONFIG_DIR": "/other/config", "ANTHROPIC_API_KEY": "FAKE-KEY",
            "PATH": "/opt/evil/bin:/usr/bin", "OTHERTOOL_TOKEN": "FAKE-TOKEN", "CLAUDE_CODE_SSE_PORT": "1",
        ])
        // Identity variables come from the account database, never from the caller's (possibly redirected) values.
        let pw = try #require(getpwuid(getuid()))
        let name = String(cString: pw.pointee.pw_name)
        #expect(clean == [
            "HOME": String(cString: pw.pointee.pw_dir), "USER": name, "LOGNAME": name,
            "SHELL": String(cString: pw.pointee.pw_shell), "TMPDIR": "/t", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        #expect(clean["HOME"] != "/h")
        #expect(ClaudeProcesses.forbiddenLaunchKeys.isDisjoint(with: clean.keys))
        #expect(!clean.keys.contains { k in ClaudeProcesses.forbiddenLaunchPrefixes.contains { k.hasPrefix($0) } })
        // Identity is filled in even when the caller exported none of it.
        #expect(SystemClaudeAppControl.cleanEnvironment(from: [:])["HOME"] == String(cString: pw.pointee.pw_dir))
    }

    @Test func systemTableSeesThisProcessReadOnly() throws {
        let table = SystemProcessTable()
        let me = try #require(table.all()?.first { $0.pid == getpid() })
        #expect(me.ppid == getppid())
        #expect(!me.path.isEmpty)
        #expect(me.startTime < Date())
        let env = table.environmentValues(pid: getpid(), keys: ["PATH", "CDSW_NOT_SET_ANYWHERE"])
        #expect(Set(env.keys).isSubset(of: ["PATH"]))
        #expect(table.environmentValues(pid: -1, keys: ["PATH"]).isEmpty)
        let names = table.environmentNames(pid: getpid())
        #expect(!names.isEmpty && names.allSatisfy { !$0.contains("=") })
        #expect(table.environmentNames(pid: -1).isEmpty)
    }

    // MARK: ClaudeProcesses

    static let exe = "/Apps/Claude.app/Contents/MacOS/Claude"
    static let t = Date(timeIntervalSince1970: 1_800_000_000)

    static func p(_ pid: pid_t, _ ppid: pid_t, _ comm: String, _ path: String, start: Date = t) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, pgid: pid, comm: comm, path: path, startTime: start)
    }

    static let table: [ProcInfo] = [
        p(100, 1, "Claude", exe),
        p(101, 100, "Claude Helper", "/Apps/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
        p(102, 100, "disclaimer", "/Apps/Claude.app/Contents/Helpers/disclaimer"),
        p(103, 102, "claude", "/ud/claude-code/2.1.0/claude"),
        p(104, 103, "node", "/usr/local/bin/node"), // MCP server under the CLI
        p(105, 100, "chrome_crashpad_", "/Apps/Claude.app/Contents/Frameworks/x/chrome_crashpad_handler"),
        p(200, 1, "zsh", "/bin/zsh"),
        p(201, 200, "claude", "/opt/bin/claude"),
        p(300, 1, "Google Chrome", "/Chrome"),
        p(301, 300, "chrome-native-h", "/Apps/Claude.app/Contents/Helpers/chrome-native-host"),
    ]

    struct StaticTable: ProcessTable {
        let procs: [ProcInfo]
        func all() -> [ProcInfo]? { procs }
        func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] { [:] }
    }

    @Test func treeAndCodeSessions() throws {
        let cp = ClaudeProcesses(table: StaticTable(procs: Self.table), mainExecutable: Self.exe)
        let main = try #require(cp.mainProcess())
        #expect(main.pid == 100)
        #expect(cp.anyClaudeNamedProcess())
        #expect(Set(cp.descendants(of: 100, in: Self.table).map(\.pid)) == [101, 102, 103, 104, 105])
        #expect(cp.codeSessionCLIs(in: Self.table, main: main).map(\.pid) == [103])
        let noClaude = ClaudeProcesses(table: StaticTable(procs: Array(Self.table.dropFirst(6))), mainExecutable: Self.exe)
        #expect(noClaude.mainProcess() == nil)
        #expect(!noClaude.anyClaudeNamedProcess())
    }

    @Test func blockingProcessesIgnoreChromeHelpersAndPidReuse() {
        let cp = ClaudeProcesses(table: StaticTable(procs: []), mainExecutable: Self.exe)
        let tree = Array(Self.table.prefix(6)) + [Self.table[9]]
        #expect(Set(cp.blockingProcesses(snapshotTree: tree, now: Self.table).map(\.pid)) == [100, 101, 102, 103, 104])
        // Only the crash handler and native host survive → nothing blocks.
        #expect(cp.blockingProcesses(snapshotTree: tree, now: [Self.table[5], Self.table[9]]).isEmpty)
        // pid 101 reused by an unrelated, newer process → not ours.
        let reused = [Self.p(101, 1, "other", "/bin/other", start: Self.t.addingTimeInterval(500))]
        #expect(cp.blockingProcesses(snapshotTree: tree, now: reused).isEmpty)
    }

    @Test func descendantsToleratesCycles() {
        let cyc = [Self.p(1, 2, "a", "/a"), Self.p(2, 1, "b", "/b")]
        let cp = ClaudeProcesses(table: StaticTable(procs: cyc), mainExecutable: "/a")
        #expect(cp.descendants(of: 1, in: cyc).map(\.pid) == [2])
    }
}
