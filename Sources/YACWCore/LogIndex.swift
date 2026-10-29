import Foundation

/// Incremental reader of Claude Code logs: remembers a byte offset per file and only parses new lines.
/// Records are keyed by (message.id, requestId) across ALL files; the last line seen wins.
public final class LogIndex: @unchecked Sendable {
    private let lock = NSLock()
    private let fixedRoots: [URL]?
    private var roots: [URL] = []
    private var lastDiscovery = Date.distantPast
    private var offsets: [URL: UInt64] = [:]
    private var byKey: [String: UsageRecord] = [:]

    /// `roots == nil` discovers the default locations (see `LogRoots`), re-scanned every 5 minutes.
    public init(roots: [URL]? = nil) { self.fixedRoots = roots }

    public var activeRoots: [URL] { lock.lock(); defer { lock.unlock() }; return roots }

    public var records: [UsageRecord] { lock.lock(); defer { lock.unlock() }; return Array(byKey.values) }

    /// Reads whatever was appended since the last call.
    public func refresh() {
        lock.lock(); defer { lock.unlock() }
        if let fixedRoots { roots = fixedRoots }
        else if Date().timeIntervalSince(lastDiscovery) > 300 { roots = LogRoots.discover(); lastDiscovery = Date() }
        for (root, url) in roots.flatMap({ r in LogParser.logFiles(root: r).map { (r, $0) } }) {
            let origin: SessionOrigin = root.path.contains("/local-agent-mode-sessions/") ? .cowork : .code
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            var pos = offsets[url] ?? 0
            if size < pos { pos = 0 }                // truncated or rewritten
            guard size > pos else { continue }
            // Read in 1 MB chunks (files reach tens of MB) and only consume complete lines;
            // a partial last line is re-read on the next refresh.
            var carry = Data()
            while pos < size {
                let progressed: Bool = autoreleasepool {
                    guard (try? h.seek(toOffset: pos)) != nil, let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                    pos += UInt64(chunk.count)
                    var buf = carry; buf.append(chunk)
                    guard let lastNL = buf.lastIndex(of: UInt8(ascii: "\n")) else { carry = buf; return true }
                    for l in buf[buf.startIndex..<lastNL].split(separator: UInt8(ascii: "\n")) {
                        if var r = LogParser.parseLine(Data(l)) { r.origin = origin; byKey[r.messageId + "|" + r.requestId] = r }
                    }
                    carry = Data(buf[buf.index(after: lastNL)...])
                    return true
                }
                if !progressed { break }
            }
            offsets[url] = pos - UInt64(carry.count)
        }
    }
}
