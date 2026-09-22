import Foundation

/// Where sessions, settings and logs live: `~/Library/Application Support/EditorTracker/`.
///
/// `EDITOR_TRACKER_DATA_DIR` redirects everything to another folder, so a development
/// build can run alongside the installed app without touching its data.
enum DataLocation {
    static let directory: URL = {
        if let override = ProcessInfo.processInfo.environment["EDITOR_TRACKER_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return prepare(in: base)
    }()

    /// Returns `<base>/EditorTracker`, creating it if needed. The app was called Resolve
    /// Edit Tracker up to v1.2.0: if only the old `<base>/ResolveEditTracker` exists, it's
    /// renamed into place — same volume, so all-or-nothing. If both exist, the new one
    /// wins and the old one is left alone.
    static func prepare(in base: URL) -> URL {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("EditorTracker", isDirectory: true)
        let legacy = base.appendingPathComponent("ResolveEditTracker", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
