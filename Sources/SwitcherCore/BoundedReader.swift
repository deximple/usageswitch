import Foundation

/// Bounds filesystem reads that can stall; a read that misses the deadline is treated as unreadable.
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
        contents(atPath: path, using: read)
    }

    public func contents(atPath path: String,
                         using read: @escaping @Sendable (String) -> Data?) -> Data? {
        lock.lock()
        guard !stalled.contains(path) else {
            lock.unlock()
            return nil
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
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            if inFlight[path]?.contains(readID) == true {
                timedOut[path, default: []].insert(readID)
                stalled.insert(path)
            }
            lock.unlock()
            return nil
        }
        return result.get()
    }

    public static func readSmallText(_ path: String) -> Data? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              (attrs[.size] as? NSNumber)?.intValue ?? 0 < 65_536,
              let data = fm.contents(atPath: path),
              !data.contains(0) else { return nil }
        return data
    }
}
