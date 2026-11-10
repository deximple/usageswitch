import Foundation
import Testing
@testable import SwitcherCore

@Suite("Bounded reader", .serialized)
struct BoundedReaderTests {
    @Test("returns data from a fast read")
    func fastRead() {
        let expected = Data("contents".utf8)
        let reader = BoundedReader { _ in expected }
        #expect(reader.read(atPath: "result") == .data(expected))
        #expect(reader.contents(atPath: "fast") == expected)
        #expect(reader.read(atPath: "missing", using: { _ in nil }) == .unreadable)
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
        #expect(reader.read(atPath: "stalled") == .timedOut)
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

    // MARK: - readSmallText (audit A-02)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readSmallTextRefusesASymlinkToALargeFile() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.txt"), link = dir.appendingPathComponent("link")
        try Data(repeating: 0x61, count: 70 * 1024).write(to: big)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        #expect(BoundedReader.readSmallText(link.path) == nil)
        #expect(BoundedReader.readSmallText(big.path) == nil)
    }

    @Test func readSmallTextRefusesSpecialFiles() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let started = Date()
        #expect(BoundedReader.readSmallText(fifo.path) == nil)
        #expect(BoundedReader.readSmallText("/dev/zero") == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func readSmallTextReadsASmallFileThroughASymlink() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("small.sh"), link = dir.appendingPathComponent("link")
        let body = Data(repeating: 0x62, count: 1024)
        try body.write(to: small)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: small)
        #expect(BoundedReader.readSmallText(link.path) == body)
        #expect(BoundedReader.readSmallText(dir.appendingPathComponent("missing").path) == nil)
    }

    @Test func readSmallTextRefusesBinaryButReadBoundedCanAllowIt() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("bin")
        let body = Data([0x62, 0x00, 0x63])
        try body.write(to: binary)
        #expect(BoundedReader.readSmallText(binary.path) == nil)
        #expect(BoundedReader.readBounded(binary.path, limit: 16, allowBinary: true) == body)
        #expect(BoundedReader.readBounded(binary.path, limit: 3, allowBinary: true) == nil)
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
