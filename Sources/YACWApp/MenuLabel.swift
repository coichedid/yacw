import SwiftUI
import AppKit

/// SwiftUI colors are flattened to a template in the menu bar, so the label is drawn into a non-template image.
struct MenuLabel: View {
    let parts: [(String, Color)]
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let img = render() { Image(nsImage: img) } else { Text(parts.map(\.0).joined()) }
        }
        // `open YACW.app --args --open-login` shows the login window right away (also handy for debugging).
        .onAppear {
            if CommandLine.arguments.contains("--open-login") { openWindow(id: "login"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    @MainActor private func render() -> NSImage? {
        let content = HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                Text(p.0).foregroundColor(p.1)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .padding(.horizontal, 2)
        let r = ImageRenderer(content: content)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = r.nsImage else { return nil }
        img.isTemplate = false
        return img
    }
}
