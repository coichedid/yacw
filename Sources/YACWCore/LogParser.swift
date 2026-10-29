import Foundation

/// Parses Claude Code JSONL logs (`~/.claude/projects/**/*.jsonl`).
///
/// Confirmed on real logs (docs/FINDINGS.md): one API response is written as several
/// `assistant` lines sharing `(message.id, requestId)`, and `output_tokens` grows across
/// them, so the LAST line of each pair wins.
/// Sidechains: `isSidechain` exists on every line; no real sample had it true, so the
/// handling (counted under the same sessionId, flagged) is covered by a synthetic fixture only.
public enum LogParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    public static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }

    /// Parses one line; nil for non-assistant lines or lines without usage.
    public static func parseLine(_ line: Data) -> UsageRecord? {
        // Cheap pre-filter: most lines (progress, snapshots, blobs) carry no usage.
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "assistant",
              let sessionId = o["sessionId"] as? String,
              let ts = (o["timestamp"] as? String).flatMap(parseDate),
              let msg = o["message"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",   // local error placeholders, no real usage
              let messageId = msg["id"] as? String,
              let u = msg["usage"] as? [String: Any] else { return nil }
        func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        var usage = TokenUsage(input: int(u, "input_tokens"), output: int(u, "output_tokens"),
                               cacheRead: int(u, "cache_read_input_tokens"),
                               cacheWrite: int(u, "cache_creation_input_tokens"))
        if let cc = u["cache_creation"] as? [String: Any] { usage.cacheWrite1h = int(cc, "ephemeral_1h_input_tokens") }
        return UsageRecord(sessionId: sessionId, messageId: messageId,
                           requestId: o["requestId"] as? String ?? "", timestamp: ts,
                           cwd: o["cwd"] as? String, model: model, usage: usage,
                           isSidechain: o["isSidechain"] as? Bool ?? false)
    }

    /// Dedups by `(messageId, requestId)` keeping the last line seen. Order of first appearance is kept.
    public static func records(fromLines lines: [Data]) -> [UsageRecord] {
        var order: [String] = []
        var byKey: [String: UsageRecord] = [:]
        for l in lines {
            guard let r = parseLine(l) else { continue }
            let key = r.messageId + "|" + r.requestId
            if byKey[key] == nil { order.append(key) }
            byKey[key] = r
        }
        return order.compactMap { byKey[$0] }
    }

    public static func records(fromFile url: URL) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        return records(fromLines: data.split(separator: UInt8(ascii: "\n")).map { Data($0) })
    }

    public static func logFiles(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}
