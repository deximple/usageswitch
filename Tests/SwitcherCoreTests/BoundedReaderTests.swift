import Foundation
import Testing
@testable import SwitcherCore

@Suite("Bounded reader", .serialized)
struct BoundedReaderTests {
    @Test("returns data from a fast read")
    func fastRead() {
        let expected = Data("contents".utf8)
        let reader = BoundedReader { _ in expected }
        #expect(reader.contents(atPath: "fast") == expected)
    }

    @Test("times out and caches the stalled path")
    func stalledPathIsCached() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedCounter()
        let reader = BoundedReader(timeout: 0.2) { _ in
            calls.increment()
            release.wait()
            return Data("late".utf8)
        }

        let started = Date()
        #expect(reader.contents(atPath: "stalled") == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(reader.contents(atPath: "stalled") == nil)
        #expect(calls.value == 1)
    }

    @Test("a stalled path does not prevent reading another path")
    func otherPathStillReads() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedCounter()
        let reader = BoundedReader(timeout: 0.2) { path in
            calls.increment()
            if path == "stalled" {
                release.wait()
                return nil
            }
            return Data(path.utf8)
        }

        #expect(reader.contents(atPath: "stalled") == nil)
        #expect(reader.contents(atPath: "available") == Data("available".utf8))
        #expect(calls.value == 2)
    }

    @Test("a late read clears the stalled path")
    func completedReadClearsStall() {
        let release = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { release.signal() }
        }
        let calls = LockedCounter()
        let expected = Data("recovered".utf8)
        let reader = BoundedReader(timeout: 0.2) { _ in
            if calls.increment() == 1 {
                release.wait()
            }
            return expected
        }

        #expect(reader.contents(atPath: "recoverable") == nil)
        release.signal()
        released = true

        let deadline = Date().addingTimeInterval(1)
        var recovered: Data?
        while recovered == nil, Date() < deadline {
            recovered = reader.contents(atPath: "recoverable")
            if recovered == nil {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        #expect(recovered == expected)
        #expect(calls.value == 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        return current
    }
}
