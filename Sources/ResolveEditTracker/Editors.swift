import Foundation
import AppKit

/// An editing app the tracker knows about.
///
/// `rawValue` is the stable key written into `Session.app` — never rename one without a
/// migration. Bundle identifiers are matched by *prefix* because Adobe stamps the release
/// year into theirs (`com.adobe.PremierePro.26`), so an exact match breaks every upgrade.
enum EditorApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case resolve
    case premiere
    case afterEffects
    case photoshop
    case lightroomClassic
    case lightroom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .resolve:          return "DaVinci Resolve"
        case .premiere:         return "Premiere Pro"
        case .afterEffects:     return "After Effects"
        case .photoshop:        return "Photoshop"
        case .lightroomClassic: return "Lightroom Classic"
        case .lightroom:        return "Lightroom"
        }
    }

    /// Short label for tight spaces (menu bar tooltip, History column).
    var shortName: String {
        switch self {
        case .resolve:          return "Resolve"
        case .premiere:         return "Premiere"
        case .afterEffects:     return "After Effects"
        case .photoshop:        return "Photoshop"
        case .lightroomClassic: return "Lightroom Classic"
        case .lightroom:        return "Lightroom"
        }
    }

    /// Matched case-insensitively against a running app's bundle identifier.
    var bundleIDPrefixes: [String] {
        switch self {
        case .resolve:          return ["com.blackmagic-design.davinciresolve"]
        case .premiere:         return ["com.adobe.premierepro"]
        case .afterEffects:     return ["com.adobe.aftereffects"]
        case .photoshop:        return ["com.adobe.photoshop"]
        case .lightroomClassic: return ["com.adobe.lightroomclassic"]
        case .lightroom:        return ["com.adobe.lightroomcc"]
        }
    }

    /// What one tracked unit inside a document is called, for UI copy.
    /// `nil` means the app has no sub-document unit worth tracking.
    var unitLabel: String? {
        switch self {
        case .resolve:      return "Timeline"
        case .premiere:     return "Sequence"
        case .afterEffects: return "Composition"
        case .photoshop, .lightroomClassic, .lightroom: return nil
        }
    }

    /// Fallback SF Symbol, used before the real app icon is available.
    var symbolName: String {
        switch self {
        case .resolve:          return "film.stack"
        case .premiere:         return "film"
        case .afterEffects:     return "square.stack.3d.down.right"
        case .photoshop:        return "photo"
        case .lightroomClassic, .lightroom: return "camera.aperture"
        }
    }

    static func matching(bundleID: String?) -> EditorApp? {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return nil }
        return allCases.first { app in
            app.bundleIDPrefixes.contains { id.hasPrefix($0) }
        }
    }
}

/// Finds where the supported editors are installed, for icons and an "is it installed"
/// check. Scans `/Applications` and one level below it — Adobe nests its apps in a
/// versioned folder (`/Applications/Adobe Premiere Pro 2026/…`). Never recursive: walking
/// every app bundle takes minutes.
enum EditorCatalog {
    private static var cachedPaths: [EditorApp: URL]?

    static func installedPaths() -> [EditorApp: URL] {
        if let cachedPaths { return cachedPaths }
        var found: [EditorApp: URL] = [:]
        let fm = FileManager.default
        let roots = ["/Applications", ("~/Applications" as NSString).expandingTildeInPath]

        var candidates: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let path = (root as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") {
                    candidates.append(URL(fileURLWithPath: path))
                } else if let nested = try? fm.contentsOfDirectory(atPath: path) {
                    for sub in nested where sub.hasSuffix(".app") {
                        candidates.append(URL(fileURLWithPath: (path as NSString).appendingPathComponent(sub)))
                    }
                }
            }
        }

        for url in candidates {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let dict = NSDictionary(contentsOf: plist),
                  let bid = dict["CFBundleIdentifier"] as? String,
                  let app = EditorApp.matching(bundleID: bid),
                  found[app] == nil
            else { continue }
            found[app] = url
        }

        cachedPaths = found
        return found
    }

    static func isInstalled(_ app: EditorApp) -> Bool { installedPaths()[app] != nil }

    /// The app's real icon, for the menu bar and Settings. Prefers the running instance.
    static func icon(for app: EditorApp) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            EditorApp.matching(bundleID: $0.bundleIdentifier) == app
        }), let icon = running.icon {
            return icon
        }
        guard let url = installedPaths()[app] else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
