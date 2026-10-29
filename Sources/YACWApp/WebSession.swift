import Foundation
import WebKit
import YACWCore

/// Source C transport. Login happens in a WKWebView window; cookies stay inside WKWebsiteDataStore.
/// The usage request is a same-origin `fetch` executed inside a hidden WKWebView, so this code never reads,
/// copies or logs a cookie or token. Only HTTP status codes are logged.
@MainActor
final class ClaudeWebSession: NSObject, WKNavigationDelegate {
    static let shared = ClaudeWebSession()
    nonisolated static let host = "claude.ai"

    private let webView: WKWebView
    private var waiters: [CheckedContinuation<Void, Error>] = []

    static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()                         // persistent, per-app cookie jar
        c.applicationNameForUserAgent = safariApplicationName   // Google rejects embedded WebViews that do not look like Safari
        c.preferences.javaScriptCanOpenWindowsAutomatically = true  // OAuth popups (window.open)
        return c
    }

    /// "Version/<installed Safari> Safari/605.1.15", read from the Safari bundle on this Mac (fallback 17.6).
    nonisolated static var safariApplicationName: String {
        let paths = ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        let v = paths.lazy.compactMap { Bundle(path: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }.first ?? "17.6"
        return "Version/\(v) Safari/605.1.15"
    }

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: Self.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    /// URLs typed in Settings (UserDefaults, never bundled or versioned). Credits fall back to the shape derived from the usage URL.
    nonisolated static func configuredURL(credits: Bool) -> URL? {
        let d = UserDefaults.standard
        let usage = EndpointURL.validate(d.string(forKey: "usageURL") ?? "")
        if !credits { return usage }
        return EndpointURL.validate(d.string(forKey: "creditsURL") ?? "") ?? usage.flatMap(EndpointURL.derivedCreditsURL(fromUsage:))
    }

    func fetchUsage(url: URL, label: String = "endpoint") async throws -> Data {
        guard EndpointURL.validate(url.absoluteString) != nil else { throw ProviderError.endpointChanged("URL fora do formato esperado") }
        if webView.url?.host != Self.host { try await loadOrigin() }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                "const r = await fetch(url, {credentials: 'include', headers: {'Accept': 'application/json'}}); return {status: r.status, body: await r.text()};",
                arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        } catch {
            DebugLog.write("\(label) fetch failed (network/JS)")
            throw ProviderError.offline
        }
        guard let d = result as? [String: Any], let status = d["status"] as? Int, let body = d["body"] as? String else {
            throw ProviderError.endpointChanged("retorno inesperado do WebView")
        }
        DebugLog.write("\(label) HTTP \(status)")
        switch status {
        case 200:
            if label == "endpoint" { Self.logShapeOnce(body) }
            return Data(body.utf8)
        case 401, 403: throw ProviderError.sessionExpired("HTTP \(status)")
        case 404: throw ProviderError.endpointChanged("HTTP 404")
        default: throw ProviderError.http(status)
        }
    }

    private static var shapeLogged = false
    private static var windowShape = ""
    /// One debug line with KEY NAMES only (no values) of the credit-related sections, to see whether the live response
    /// carries a spending cap or balance. Never logs amounts, ids or cookies.
    private static func logShapeOnce(_ body: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return }
        func keys(_ v: Any?) -> String {
            guard let d = v as? [String: Any] else { return v == nil || v is NSNull ? "null" : "(\(type(of: v!)))" }
            return d.keys.sorted().map { "\($0)=\(d[$0] is NSNull ? "null" : "set")" }.joined(separator: ",")
        }
        // Window shapes are logged again whenever they change (e.g. resets_at going null before the first message).
        let ws = "five_hour{\(keys(o["five_hour"]))} seven_day{\(keys(o["seven_day"]))}"
        if ws != windowShape { windowShape = ws; DebugLog.write("endpoint shape " + ws) }
        guard !shapeLogged else { return }
        shapeLogged = true
        DebugLog.write("endpoint shape extra_usage{\(keys(o["extra_usage"]))} spend{\(keys(o["spend"]))}")
    }

    /// Loads a tiny same-origin document so `fetch` runs with claude.ai as origin.
    private func loadOrigin() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
            if waiters.count == 1 { webView.load(URLRequest(url: URL(string: "https://\(Self.host)/robots.txt")!, timeoutInterval: 20)) }
        }
    }
    private func finish(_ error: Error?) {
        let w = waiters; waiters = []
        for c in w { if let error { c.resume(throwing: error) } else { c.resume() } }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in self.finish(nil) } }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in DebugLog.write("origin load failed"); self.finish(ProviderError.offline) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in DebugLog.write("origin load failed"); self.finish(ProviderError.offline) }
    }
}

enum DebugLog {
    private static let url = AppPaths.file("debug.log")
    /// Never pass credentials or response bodies here.
    static func write(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
