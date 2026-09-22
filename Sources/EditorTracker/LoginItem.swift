import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private static let registeredPathKey = "loginItemRegisteredPath"

    /// Keeps launch-at-login pointing at this copy of the app. A login item registered
    /// before the app was moved or renamed can go missing, or keep pointing at the old
    /// path — re-register once when that happens. If it was switched off in System
    /// Settings (`requiresApproval`), leave it off.
    static func reconcile(wanted: Bool) {
        guard wanted else { return }
        let service = SMAppService.mainApp
        if service.status == .requiresApproval { return }
        let path = Bundle.main.bundlePath
        let moved = UserDefaults.standard.string(forKey: registeredPathKey) != path
        if service.status != .enabled || moved {
            try? service.unregister()
            do { try service.register() } catch { NSLog("LoginItem: \(error.localizedDescription)") }
        }
        if service.status == .enabled {
            UserDefaults.standard.set(path, forKey: registeredPathKey)
        }
    }

    /// Returns the effective state after the attempt.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItem: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
