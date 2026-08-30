import AppKit

// Pure AppKit entry point. A SwiftUI `MenuBarExtra` scene cannot show its panel
// over a full-screen Space (e.g. Resolve running full-screen), so the menu-bar
// item and its popover are built by hand in AppDelegate.

@main
enum ResolveEditTrackerMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
