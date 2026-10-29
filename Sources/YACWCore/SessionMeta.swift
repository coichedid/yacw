import Foundation

/// Which Claude product produced a work session's local log.
public enum SessionOrigin: String, CaseIterable, Sendable, Identifiable {
    case code, codeDesktop, cowork
    public var id: String { rawValue }
    public var label: String {
        switch self { case .code: return "Code"; case .codeDesktop: return "Code (app)"; case .cowork: return "Cowork" }
    }
}

public struct SessionMeta: Equatable, Sendable {
    public var title: String
    public var origin: SessionOrigin
    public init(title: String, origin: SessionOrigin) { self.title = title; self.origin = origin }
}

/// Session labels written by the Claude desktop app (field names confirmed on this Mac, values never logged):
/// - `Application Support/Claude/local-agent-mode-sessions/<uuid>/<uuid>/local_*.json`: Cowork, with `title`, `cliSessionId`
/// - `Application Support/Claude/claude-code-sessions/<uuid>/<uuid>/local_*.json`: Code tab of the app, same fields
/// `cliSessionId` equals the `sessionId` found in the JSONL logs (22/22 Cowork files that have one). Only those two
/// fields are read; prompts and everything else in these files are ignored.
public final class SessionMetadata: @unchecked Sendable {
    public static let shared = SessionMetadata()
    private let lock = NSLock()
    private var cache: [URL: (mtime: Date, id: String?, meta: SessionMeta?)] = [:]
    private var lastScan = Date.distantPast
    private var map: [String: SessionMeta] = [:]
    private let base: URL

    public init(base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")) {
        self.base = base
    }

    /// `cliSessionId` -> label, re-scanned at most every 5 minutes; files are re-parsed only when their mtime changes.
    public func snapshot(now: Date = Date()) -> [String: SessionMeta] {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(lastScan) < 300 && !map.isEmpty { return map }
        lastScan = now
        var out: [String: SessionMeta] = [:]
        for (dir, origin) in [("local-agent-mode-sessions", SessionOrigin.cowork), ("claude-code-sessions", .codeDesktop)] {
            guard let e = FileManager.default.enumerator(at: base.appendingPathComponent(dir), includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                let n = url.lastPathComponent
                guard n.hasPrefix("local_"), n.hasSuffix(".json"), e.level == 3 else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if cache[url]?.mtime != mtime {
                    var id: String?, meta: SessionMeta?
                    if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                       let cli = o["cliSessionId"] as? String, !cli.isEmpty {
                        id = cli
                        meta = SessionMeta(title: String(((o["title"] as? String) ?? "").prefix(80)), origin: origin)
                    }
                    cache[url] = (mtime, id, meta)
                }
                if let c = cache[url], let id = c.id, let m = c.meta { out[id] = m }
            }
        }
        map = out
        return out
    }
}
