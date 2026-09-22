import Foundation

/// Where sessions, settings and logs live.
///
/// `RET_DATA_DIR` redirects everything to another folder, so a development build can
/// run alongside the installed app without touching its data.
enum DataLocation {
    static let directory: URL = {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["RET_DATA_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("ResolveEditTracker", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
