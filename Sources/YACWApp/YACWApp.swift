import SwiftUI
import YACWCore

@main
struct YACWApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `YACW --check-resources`: verifies the bundled resources load (used by scripts/check-bundle.sh), then exits.
        if CommandLine.arguments.contains("--check-resources") {
            let ok = (try? PricingTable.load())?.models.isEmpty == false
            print(ok ? "resources ok" : "resources MISSING")
            exit(ok ? 0 : 1)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuLabel(parts: model.labelParts)
        }
        .menuBarExtraStyle(.window)

        Window("YACW — painel estendido", id: "extended") {
            ExtendedView(model: model)
        }

        Window("Entrar no claude.ai", id: "login") {
            LoginWindow(model: model)
        }
    }
}
