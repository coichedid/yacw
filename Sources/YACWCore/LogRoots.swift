import Foundation

/// Where Claude Code session logs live. Only directories with the confirmed `projects/<slug>/*.jsonl` layout.
/// - `~/.claude/projects` (CLI)
/// - `$CLAUDE_CONFIG_DIR/projects` when set (only visible if the app is launched from a shell)
/// - Claude desktop app sandboxes: `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects`
///   (same format; includes real `isSidechain` subagent logs). Its `audit.jsonl` files use a different
///   schema (no `timestamp`, snake_case ids) and are deliberately ignored.
public enum LogRoots {
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                env: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        func add(_ u: URL) { if fm.fileExists(atPath: u.path), !roots.contains(u) { roots.append(u) } }
        add(home.appendingPathComponent(".claude/projects"))
        if let c = env["CLAUDE_CONFIG_DIR"], !c.isEmpty { add(URL(fileURLWithPath: c).appendingPathComponent("projects")) }

        let desktop = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        if let e = fm.enumerator(at: desktop, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in e {
                if e.level > 5 { e.skipDescendants(); continue }          // <uuid>/<uuid>/local_<uuid>/.claude/projects
                guard url.lastPathComponent == "projects", url.deletingLastPathComponent().lastPathComponent == ".claude" else { continue }
                add(url); e.skipDescendants()
            }
        }
        return roots
    }
}
