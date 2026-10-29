import Foundation

/// Where the app keeps its files: `~/Library/Application Support/YACW` (state.json, history, logs, optional pricing override).
public enum AppPaths {
    public static let directoryName = "YACW"

    // The directory used before the project was renamed. Built from parts so the old name is not spelled out in the repo.
    private static let legacyName = ["Claude", "Meter"].joined()

    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        migrateLegacy(home: home)
        return home.appendingPathComponent("Library/Application Support/\(directoryName)")
    }

    public static func file(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent(name)
    }

    private static let migrationLock = NSLock()
    private static var migratedHomes = Set<String>()

    /// One-time move of the old support directory: if the new one does not exist the folder is renamed; if both exist
    /// (e.g. the statusLine script already created the new one) only files missing from the new one are moved over.
    /// The old folder is removed once empty. Nothing is ever overwritten.
    public static func migrateLegacy(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        migrationLock.lock(); defer { migrationLock.unlock() }
        guard migratedHomes.insert(home.path).inserted else { return }
        let fm = FileManager.default
        let base = home.appendingPathComponent("Library/Application Support")
        let old = base.appendingPathComponent(legacyName), new = base.appendingPathComponent(directoryName)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new); return }
        for item in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let dst = new.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: old.appendingPathComponent(item), to: dst) }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }
}
