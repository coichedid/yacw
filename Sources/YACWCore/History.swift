import Foundation
import SQLite3

public struct HistorySample: Equatable, Sendable {
    public var ts: Date
    public var kind: LimitWindowKind
    public var percent: Double
    public var resetsAt: Date
    public var source: SourceKind
    public init(ts: Date, kind: LimitWindowKind, percent: Double, resetsAt: Date, source: SourceKind = .statusLine) {
        self.ts = ts; self.kind = kind; self.percent = percent; self.resetsAt = resetsAt; self.source = source
    }
}

public protocol HistoryStore: Sendable {
    func append(_ samples: [HistorySample]) throws
    func samples(since: Date, kind: LimitWindowKind) throws -> [HistorySample]
    func prune(olderThan: Date) throws
}

public struct HistoryError: Error { public var message: String }

/// SQLite-backed history using the system libsqlite3 (no external dependency).
public final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    public static let retention: TimeInterval = 180 * 86_400
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(path: String? = nil) throws {
        let p = path ?? {
            let dir = AppPaths.supportDirectory()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("history.sqlite").path
        }()
        guard sqlite3_open(p, &db) == SQLITE_OK else { throw HistoryError(message: "open \(p)") }
        try exec("CREATE TABLE IF NOT EXISTS samples (ts INTEGER NOT NULL, kind TEXT NOT NULL, percent REAL NOT NULL, resets_at INTEGER NOT NULL)")
        // Older databases have no source column; those rows were all written from the statusLine source.
        _ = sqlite3_exec(db, "ALTER TABLE samples ADD COLUMN source TEXT NOT NULL DEFAULT 'statusLine'", nil, nil, nil)
        try exec("CREATE INDEX IF NOT EXISTS samples_kind_ts ON samples(kind, ts)")
        try prune(olderThan: Date().addingTimeInterval(-Self.retention))
    }
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func append(_ samples: [HistorySample]) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO samples (ts, kind, percent, resets_at, source) VALUES (?,?,?,?,?)", -1, &st, nil) == SQLITE_OK else {
            throw HistoryError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        for s in samples {
            sqlite3_reset(st)
            sqlite3_bind_int64(st, 1, Int64(s.ts.timeIntervalSince1970))
            sqlite3_bind_text(st, 2, s.kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(st, 3, s.percent)
            sqlite3_bind_int64(st, 4, Int64(s.resetsAt.timeIntervalSince1970))
            sqlite3_bind_text(st, 5, s.source.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(st) == SQLITE_DONE else { throw HistoryError(message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    public func samples(since: Date, kind: LimitWindowKind) throws -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ts, percent, resets_at, source FROM samples WHERE kind=? AND ts>=? ORDER BY ts", -1, &st, nil) == SQLITE_OK else {
            throw HistoryError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(st, 2, Int64(since.timeIntervalSince1970))
        var out: [HistorySample] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(HistorySample(ts: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 0))), kind: kind,
                                     percent: sqlite3_column_double(st, 1),
                                     resetsAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 2))),
                                     source: SourceKind(rawValue: String(cString: sqlite3_column_text(st, 3))) ?? .statusLine))
        }
        return out
    }

    public func prune(olderThan: Date) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM samples WHERE ts < \(Int64(olderThan.timeIntervalSince1970))")
    }
}

/// In-memory store for tests.
public final class MemoryHistoryStore: HistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [HistorySample] = []
    public init() {}
    public func append(_ samples: [HistorySample]) throws { lock.lock(); all += samples; lock.unlock() }
    public func samples(since: Date, kind: LimitWindowKind) throws -> [HistorySample] {
        lock.lock(); defer { lock.unlock() }; return all.filter { $0.kind == kind && $0.ts >= since }.sorted { $0.ts < $1.ts }
    }
    public func prune(olderThan: Date) throws { lock.lock(); all.removeAll { $0.ts < olderThan }; lock.unlock() }
}
