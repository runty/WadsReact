import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct reactwatchApp: App {
    init() {
#if os(macOS)
        DispatchQueue.main.async {
            guard let url = Bundle.main.url(forResource: "DockIcon", withExtension: "png"),
                  let icon = NSImage(contentsOf: url) else {
                return
            }
            NSApplication.shared.applicationIconImage = icon
        }
#endif
    }

    var body: some Scene {
        WindowGroup("WadsReact") {
            ContentView()
        }
    }
}
