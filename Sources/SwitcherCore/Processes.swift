import Darwin
import Foundation

public struct ProcInfo: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let pgid: pid_t
    public let comm: String
    public let path: String
    public let startTime: Date
}

/// Read-only process inspection via sysctl/libproc (no `ps`, so no env dumps).
public protocol ProcessTable: Sendable {
    func all() -> [ProcInfo]
    /// Values of only the requested environment keys of `pid`; other variables are never returned.
    func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String]
    /// Names (never values) of `pid`'s initial environment variables.
    func environmentNames(pid: pid_t) -> Set<String>
}

extension ProcessTable {
    public func environmentNames(pid: pid_t) -> Set<String> { [] }
}

public struct SystemProcessTable: ProcessTable {
    public init() {}

    public func all() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        let uid = getuid()
        var out: [ProcInfo] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            var kp = procs[i]
            let pid = kp.kp_proc.p_pid
            // Only this user's processes: another user's Claude must never be matched or signalled.
            guard pid > 0, kp.kp_eproc.e_ucred.cr_uid == uid else { continue }
            let comm = withUnsafePointer(to: &kp.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(decoding: pathBuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            let tv = kp.kp_proc.p_starttime
            out.append(ProcInfo(
                pid: pid, ppid: kp.kp_eproc.e_ppid, pgid: kp.kp_eproc.e_pgid, comm: comm, path: path,
                startTime: Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)))
        }
        return out
    }

    public func environmentValues(pid: pid_t, keys: Set<String>) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        return Self.parseProcArgs(Array(buf[0..<size]), keys: keys)
    }

    public func environmentNames(pid: pid_t) -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return Self.parseProcArgNames(Array(buf[0..<size]))
    }

    static func parseProcArgNames(_ buf: [UInt8]) -> Set<String> {
        var names: Set<String> = []
        forEachEnvEntry(buf) { entry in
            if let eq = entry.firstIndex(of: UInt8(ascii: "=")) { names.insert(String(decoding: entry[entry.startIndex..<eq], as: UTF8.self)) }
        }
        return names
    }

    static func forEachEnvEntry(_ buf: [UInt8], _ body: (ArraySlice<UInt8>) -> Void) {
        guard buf.count > 4 else { return }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < buf.count && buf[i] != 0 { i += 1 }
        while i < buf.count && buf[i] == 0 { i += 1 }
        var skipped = 0
        while i < buf.count && skipped < argc {
            while i < buf.count && buf[i] != 0 { i += 1 }
            i += 1
            skipped += 1
        }
        while i < buf.count {
            let start = i
            while i < buf.count && buf[i] != 0 { i += 1 }
            if i == start { break }
            body(buf[start..<i])
            i += 1
        }
    }

    /// KERN_PROCARGS2 layout: argc, exec path, padding NULs, argv[argc], envp…
    static func parseProcArgs(_ buf: [UInt8], keys: Set<String>) -> [String: String] {
        guard buf.count > 4 else { return [:] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < buf.count && buf[i] != 0 { i += 1 }        // exec path
        while i < buf.count && buf[i] == 0 { i += 1 }        // padding
        var skipped = 0
        while i < buf.count && skipped < argc {               // argv
            while i < buf.count && buf[i] != 0 { i += 1 }
            i += 1
            skipped += 1
        }
        var result: [String: String] = [:]
        while i < buf.count {
            let start = i
            while i < buf.count && buf[i] != 0 { i += 1 }
            if i == start { break }
            if let eq = buf[start..<i].firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: buf[start..<eq], as: UTF8.self)
                if keys.contains(key) { result[key] = String(decoding: buf[(eq + 1)..<i], as: UTF8.self) }
            }
            i += 1
        }
        return result
    }
}

/// Claude.app process model (design D2-1/D2-4).
public struct ClaudeProcesses: Sendable {
    public let table: ProcessTable
    public let mainExecutable: String

    public init(table: ProcessTable, mainExecutable: String) {
        self.table = table
        self.mainExecutable = mainExecutable
    }

    public func mainProcesses(in procs: [ProcInfo]) -> [ProcInfo] {
        procs.filter { $0.path == mainExecutable }
    }

    public func mainProcess() -> ProcInfo? { mainProcesses(in: table.all()).first }

    /// Same check the user's keepalive script uses (`pgrep -x Claude`).
    public func anyClaudeNamedProcess() -> Bool { table.all().contains { $0.comm == "Claude" } }

    public func descendants(of root: pid_t, in procs: [ProcInfo]) -> [ProcInfo] {
        var children: [pid_t: [ProcInfo]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        var out: [ProcInfo] = []
        var stack = [root]
        while let pid = stack.popLast() {
            for c in children[pid] ?? [] where c.pid != root {
                out.append(c)
                stack.append(c.pid)
            }
        }
        return out
    }

    /// Code-tab CLI processes: children of a `Helpers/disclaimer` wrapper under the Claude main process.
    public func codeSessionCLIs(in procs: [ProcInfo], main: ProcInfo) -> [ProcInfo] {
        let tree = descendants(of: main.pid, in: procs)
        let wrappers = Set(tree.filter { $0.path.hasSuffix("/Contents/Helpers/disclaimer") }.map(\.pid))
        return tree.filter { wrappers.contains($0.ppid) }
    }

    /// Processes that must be gone before the profile may be touched. Chrome-owned native hosts and the
    /// crash handler are excluded: they are not part of the app's process tree.
    public func blockingProcesses(snapshotTree: [ProcInfo], now procs: [ProcInfo]) -> [ProcInfo] {
        let alive = Set(procs.map(\.pid))
        return snapshotTree.filter { p in
            alive.contains(p.pid)
                && !p.path.hasSuffix("/chrome-native-host")
                && !p.path.hasSuffix("/chrome_crashpad_handler")
                && procs.first(where: { $0.pid == p.pid })?.startTime == p.startTime
        }
    }

    public static let codeIdentityKeys: Set<String> = ["CLAUDE_CODE_ACCOUNT_UUID", "CLAUDE_CODE_USER_EMAIL", "CLAUDE_CONFIG_DIR"]

    /// Variables that must never reach Claude's main process: they would redirect Code-tab sessions to
    /// another config dir or account (only names are inspected).
    public static let forbiddenLaunchKeys: Set<String> = [
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
    ]

    /// Prefixes of variables set by Claude Code or the Anthropic SDK in the caller's shell.
    public static let forbiddenLaunchPrefixes = ["CLAUDE_", "CLAUDECODE", "ANTHROPIC_"]

    public func leakedLaunchKeys(main: ProcInfo) -> Set<String> {
        table.environmentNames(pid: main.pid).filter { name in
            Self.forbiddenLaunchKeys.contains(name) || Self.forbiddenLaunchPrefixes.contains { name.hasPrefix($0) }
        }
    }
}
