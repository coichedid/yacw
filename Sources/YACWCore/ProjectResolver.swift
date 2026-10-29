import Foundation

/// Maps a `cwd` to its repository root label, so worktrees and subfolders count as one project.
/// Order: Claude Code worktree path pattern, desktop-app sandbox, `.git` walk (dir = root, file = worktree
/// pointer to the main repo), then the cwd itself.
public final class ProjectResolver: @unchecked Sendable {
    public static let shared = ProjectResolver()
    public static let coworkLabel = "Cowork (app desktop)"
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init() {}

    public func project(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        lock.lock(); if let c = cache[cwd] { lock.unlock(); return c }; lock.unlock()
        let label = (Self.root(for: cwd) as NSString).lastPathComponent
        let desktop = cwd.hasPrefix("/sessions/") || cwd.contains("/Application Support/Claude/local-agent-mode-sessions/")
        let result = desktop ? Self.coworkLabel : (label.isEmpty ? cwd : label)
        lock.lock(); cache[cwd] = result; lock.unlock()
        return result
    }

    /// Repository root path (best effort; works when the directory no longer exists).
    public static func root(for cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        let fm = FileManager.default
        var dir = cwd
        while dir.count > 1 {
            let git = dir + "/.git"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // Linked worktree: ".git" file contains "gitdir: <main>/.git/worktrees/<name>".
                if let text = try? String(contentsOfFile: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }),
                   let r = line.range(of: "/.git/worktrees/") {
                    return String(line[line.index(line.startIndex, offsetBy: 7)..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return cwd
    }
}
