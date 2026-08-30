import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var appState: AppState!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var pauseSignalSource: DispatchSourceSignal?
    private lazy var outsideClickMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
        guard let self, self.popover.isShown else { return }
        self.popover.performClose(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        appState = state

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }
        Log.write("statusItem created (button=\(statusItem.button != nil))")

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: MenuContentView()
                .environmentObject(state)
                .environment(\.openSettings, OpenSettingsAction { [weak self] in self?.openSettings() })
                .environment(\.openHistory, OpenSettingsAction { [weak self] in self?.openHistory() })
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 308, height: 460)

        refreshStatusButton()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusButton() }
        }
        refreshTimer?.tolerance = 0.25

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusButton() }
            .store(in: &cancellables)

        // `killall -USR1 ResolveEditTracker` toggles pause — bind it to a hotkey app if you like.
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { state.togglePause() } }
        src.resume()
        pauseSignalSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.flushForQuit()
    }

    // MARK: - Status button

    private func refreshStatusButton() {
        guard let button = statusItem.button, let appState else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: appState.menuBarSymbol, accessibilityDescription: "Resolve Edit Tracker")?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = true
        button.image = image
        if let text = appState.menuBarText {
            button.title = " " + text
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.title = ""
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            outsideClickMonitor.stop()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            outsideClickMonitor.start()
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated { outsideClickMonitor.stop() }
    }

    // MARK: - Auxiliary windows

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Resolve Edit Tracker Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setContentSize(NSSize(width: 480, height: 620))
            window.contentMinSize = NSSize(width: 420, height: 360)
            window.contentMaxSize = NSSize(width: 640, height: 1200)
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func openHistory() {
        if historyWindow == nil {
            let hosting = NSHostingController(rootView: HistoryView().environmentObject(appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Resolve Edit Tracker — History & Reports"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setContentSize(NSSize(width: 720, height: 480))
            window.contentMinSize = NSSize(width: 560, height: 360)
            window.center()
            historyWindow = window
        }
        present(historyWindow)
    }

    private func present(_ window: NSWindow?) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Tiny environment actions so the SwiftUI panel can drive AppKit windows

struct OpenSettingsAction {
    let run: () -> Void
    func callAsFunction() { run() }
}

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction(run: {})
}
private struct OpenHistoryKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction(run: {})
}

extension EnvironmentValues {
    var openSettings: OpenSettingsAction {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
    var openHistory: OpenSettingsAction {
        get { self[OpenHistoryKey.self] }
        set { self[OpenHistoryKey.self] = newValue }
    }
}
