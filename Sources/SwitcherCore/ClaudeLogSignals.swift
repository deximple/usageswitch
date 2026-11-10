import Darwin
import Foundation

/// What status polling needs from Claude's log, recomputed only when `main.log` changes.
/// Switching itself (the recapture guard, launch verification) reads the log directly.
final class ClaudeLogSignals: @unchecked Sendable {
    struct Snapshot: Equatable {
        let latestIdentity: ClaudeLog.IdentitySignal?
        /// `main.log` mentions Claude's own multi-account endpoint.
        let nativeMultiAccount: Bool
    }

    private struct MarkerScan {
        var inode: ino_t
        /// Bytes of this inode already searched.
        var scanned: UInt64
        var found: Bool
    }

    private let log: ClaudeLog
    private let lock = NSLock()
    private var fingerprint: String?
    private var snapshot: Snapshot?
    private var marker: MarkerScan?

    init(log: ClaudeLog) { self.log = log }

    func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        let exists = stat(log.logsDir.appendingPathComponent("main.log").path, &info) == 0
        let now = exists
            ? "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : "missing"
        if let snapshot, fingerprint == now { return snapshot }
        let fresh = Snapshot(latestIdentity: log.latestIdentity(),
                             nativeMultiAccount: exists && markerFound(inode: info.st_ino, size: UInt64(info.st_size)))
        fingerprint = now
        snapshot = fresh
        return fresh
    }

    /// Once seen, the marker stays in that file, so only the bytes added since the last look are searched.
    private func markerFound(inode: ino_t, size: UInt64) -> Bool {
        var scan = marker.flatMap { $0.inode == inode && $0.scanned <= size ? $0 : nil }
            ?? MarkerScan(inode: inode, scanned: 0, found: false)
        if !scan.found {
            let needle = Data(ClaudeLog.multiAccountMarker.utf8)
            // Step back so a marker split across two appends is still seen.
            let overlap = UInt64(needle.count - 1)
            let start = scan.scanned > overlap ? scan.scanned - overlap : 0
            guard let data = log.readData("main.log", from: start) else { return false }
            scan.found = data.range(of: needle) != nil
            scan.scanned = start + UInt64(data.count)
        }
        marker = scan
        return scan.found
    }
}
