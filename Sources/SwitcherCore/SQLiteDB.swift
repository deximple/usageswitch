import Foundation
import SQLite3

/// Minimal SQLite wrapper. Only metadata columns are ever selected by callers; cookie values are never read.
final class SQLiteDB {
    private var handle: OpaquePointer?

    enum Mode { case readOnlyImmutable, readOnly, readWrite }

    init(path: String, mode: Mode) throws {
        let uri: String
        let flags: Int32
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch mode {
        case .readOnlyImmutable:
            uri = "file:\(escaped)?mode=ro&immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        case .readOnly:
            uri = "file:\(escaped)?mode=ro"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        case .readWrite:
            uri = "file:\(escaped)"
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI
        }
        if sqlite3_open_v2(uri, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SwitcherError.sqlite(message)
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    typealias Row = [SQLiteValue]

    func query(_ sql: String, _ params: [String] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, transient)
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: Row = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c) { row.append(.blob(Data(bytes: p, count: n))) } else { row.append(.blob(Data())) }
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    @discardableResult
    func execute(_ sql: String, _ params: [String] = []) throws -> Int {
        _ = try query(sql, params)
        return Int(sqlite3_changes(handle))
    }

    private func lastError() -> SwitcherError {
        SwitcherError.sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}

enum SQLiteValue: Equatable {
    case int(Int64), text(String), blob(Data), double(Double), null

    var int: Int64? { if case .int(let v) = self { return v }; if case .text(let s) = self { return Int64(s) }; return nil }
    var text: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        default: return nil
        }
    }
    var blob: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }
}
