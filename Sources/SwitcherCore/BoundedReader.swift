import Darwin
import Foundation

public enum BoundedRead: Equatable {
    case data(Data)
    case unreadable
    case timedOut
}

/// Bounds potentially stalled file reads and reports timeouts separately from unreadable files.
public final class BoundedReader: @unchecked Sendable {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func set(_ value: Data?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public static let shared = BoundedReader()

    private let timeout: TimeInterval
    private let read: @Sendable (String) -> Data?
    private let lock = NSLock()
    private var stalled: Set<String> = []
    private var inFlight: [String: Set<UUID>] = [:]
    private var timedOut: [String: Set<UUID>] = [:]

    public init(timeout: TimeInterval = 2,
                read: @escaping @Sendable (String) -> Data? = BoundedReader.readSmallText) {
        self.timeout = timeout
        self.read = read
    }

    public func contents(atPath path: String) -> Data? {
        if case let .data(data) = read(atPath: path) { return data }
        return nil
    }

    public func contents(atPath path: String,
                         using read: @escaping @Sendable (String) -> Data?) -> Data? {
        if case let .data(data) = self.read(atPath: path, using: read) { return data }
        return nil
    }

    public func read(atPath path: String) -> BoundedRead {
        self.read(atPath: path, using: read)
    }

    public func read(atPath path: String,
                     using read: @escaping @Sendable (String) -> Data?) -> BoundedRead {
        lock.lock()
        guard !stalled.contains(path) else {
            lock.unlock()
            return .timedOut
        }
        let readID = UUID()
        inFlight[path, default: []].insert(readID)
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Thread { [self] in
            result.set(read(path))
            self.lock.lock()
            var activeReads = self.inFlight[path] ?? []
            activeReads.remove(readID)
            if activeReads.isEmpty {
                self.inFlight.removeValue(forKey: path)
            } else {
                self.inFlight[path] = activeReads
            }
            var stalledReads = self.timedOut[path] ?? []
            stalledReads.remove(readID)
            if stalledReads.isEmpty {
                self.timedOut.removeValue(forKey: path)
                self.stalled.remove(path)
            } else {
                self.timedOut[path] = stalledReads
            }
            self.lock.unlock()
            semaphore.signal()
        }.start()
        if semaphore.wait(timeout: .now() + timeout) != .success {
            lock.lock()
            let stillInFlight = inFlight[path]?.contains(readID) == true
            if stillInFlight {
                timedOut[path, default: []].insert(readID)
                stalled.insert(path)
            }
            lock.unlock()
            if stillInFlight { return .timedOut }
        }
        return result.get().map(BoundedRead.data) ?? .unreadable
    }

    /// Small text only: at most 64 KiB and no NUL byte.
    public static func readSmallText(_ path: String) -> Data? {
        readBounded(path, limit: 65_536, allowBinary: false)
    }

    /// Reads a regular file smaller than `limit` bytes and nothing else. The size is taken from the opened
    /// file, so a symlink is measured by its target, and devices, FIFOs and directories are refused
    /// without reading them.
    public static func readBounded(_ path: String, limit: Int, allowBinary: Bool) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < off_t(limit) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer[0..<count])
            // The file grew past the limit after fstat.
            guard data.count < limit else { return nil }
        }
        if !allowBinary, data.contains(0) { return nil }
        return data
    }
}
