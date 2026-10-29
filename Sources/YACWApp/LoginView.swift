import SwiftUI
import WebKit

/// Login window for claude.ai. Uses the app's persistent WKWebsiteDataStore; nothing is read from other browsers.
/// Google sign-in opens `accounts.google.com` in a popup (window.open) that talks back to claude.ai through
/// `window.opener`, so popups are created as child WebViews with the configuration WebKit hands us (same data store
/// and process pool as the opener) and closed when the page calls `window.close()`.
final class LoginCoordinator: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    private var popups: [(window: NSWindow, view: WKWebView)] = []

    /// Host + path only: query strings carry OAuth codes and must never be logged.
    private static func describe(_ url: URL?) -> String { "\(url?.host ?? "?")\(url?.path ?? "")" }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let w = max(windowFeatures.width?.doubleValue ?? 520, 420), h = max(windowFeatures.height?.doubleValue ?? 680, 520)
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: configuration)  // same configuration
        child.uiDelegate = self
        child.navigationDelegate = self
        child.customUserAgent = webView.customUserAgent
        let win = NSWindow(contentRect: child.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Entrar"
        win.contentView = child
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center(); win.makeKeyAndOrderFront(nil)
        popups.append((win, child))
        DebugLog.write("login popup opened -> \(Self.describe(navigationAction.request.url))")
        return child
    }

    /// `window.close()` from the popup (e.g. after Google hands the result back to claude.ai).
    func webViewDidClose(_ webView: WKWebView) {
        DebugLog.write("login popup closed by page")
        if let i = popups.firstIndex(where: { $0.view === webView }) { popups[i].window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        popups.removeAll { $0.window === w }
    }

    // Navigation between claude.ai and accounts.google.com (and the hosts Google redirects through) stays in the WebView.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(["https", "http", "about", "blob", "data"].contains(scheme ?? "") ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.write("login page loaded \(Self.describe(webView.url))")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.write("login navigation failed \(Self.describe(webView.url)) code=\((error as NSError).code)")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.write("login navigation failed \(Self.describe(webView.url)) code=\((error as NSError).code)")
    }
}

struct LoginWebView: NSViewRepresentable {
    func makeCoordinator() -> LoginCoordinator { LoginCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: ClaudeWebSession.makeConfiguration())
        v.uiDelegate = context.coordinator
        v.navigationDelegate = context.coordinator
        v.customUserAgent = nil          // the user agent comes from applicationNameForUserAgent (installed Safari version)
        v.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        v.evaluateJavaScript("navigator.userAgent") { ua, _ in DebugLog.write("login user agent: \(ua as? String ?? "?")") }
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

struct LoginWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entre na sua conta do claude.ai. O login fica só neste app; depois clique em Concluir.")
                    .font(.callout)
                Spacer()
                Button("Concluir") { dismiss() }.keyboardShortcut(.defaultAction)   // onDisappear below switches the source
            }
            .padding(10)
            Divider()
            LoginWebView()
        }
        .frame(minWidth: 520, minHeight: 680)
        .onDisappear { model.sourceChanged() }   // runs for "Concluir" and for the window's close button
    }
}
