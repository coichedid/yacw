import Foundation

/// Locates SwiftPM resources without the generated `Bundle.module` accessor, which only looks in the app root or at the
/// absolute build path (and calls `fatalError` otherwise): a packaged .app keeps `yacw_YACWCore.bundle` in
/// `Contents/Resources`. `Bundle.module` is used only when not running from an .app (swift run / swift test).
enum Resources {
    static let bundleName = "yacw_YACWCore"

    static func url(_ name: String, _ ext: String) -> URL? {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("\(bundleName).bundle"),
           let url = Bundle(url: dir)?.url(forResource: name, withExtension: ext) { return url }
        // Packaged app: never touch Bundle.module, a missing bundle would be fatal.
        if Bundle.main.bundlePath.hasSuffix(".app") { return nil }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
