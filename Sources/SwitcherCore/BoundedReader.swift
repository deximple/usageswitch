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

    public init(timeout: TimeInterval = 1,
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
        let isStalled = stalled.contains(path)
        lock.unlock()
        guard !isStalled else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global(qos: .utility).async {
            result.set(read(path))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            stalled.insert(path)
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
