import Foundation

/// The Resolve pages we attribute time to. Raw values match `resolve.GetCurrentPage()`.
enum ResolvePage: String, CaseIterable, Codable {
    case media, cut, edit, fusion, color, fairlight, deliver, photo

    var displayName: String {
        switch self {
        case .media:     return "Media"
        case .cut:       return "Cut"
        case .edit:      return "Edit"
        case .fusion:    return "Fusion"
        case .color:     return "Color"
        case .fairlight: return "Fairlight"
        case .deliver:   return "Deliver"
        case .photo:     return "Photo"
        }
    }

    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

/// One decoded JSON line from the Python probe. Tolerant of missing keys.
struct ResolveStatus: Codable, Equatable {
    var running: Bool = false
    var apiOk: Bool = false
    var reason: String? = nil          // why the API isn't usable, when apiOk == false
    var page: String? = nil
    var project: String? = nil
    var timeline: String? = nil
    var timecode: String? = nil         // timeline playhead position; changes between
                                        // polls => the user is playing back / scrubbing.
    var rendering: Bool = false
    var busy: Bool = false              // API is up + a project is loaded, but Resolve isn't on a
                                        // standard page — a dialog / background task (transcribe,
                                        // sync, cache, load) is up. Not a reason to stop tracking.
    var transientError: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running        = try c.decodeIfPresent(Bool.self,   forKey: .running) ?? false
        apiOk          = try c.decodeIfPresent(Bool.self,   forKey: .apiOk) ?? false
        reason         = try c.decodeIfPresent(String.self, forKey: .reason)
        page           = try c.decodeIfPresent(String.self, forKey: .page)
        project        = try c.decodeIfPresent(String.self, forKey: .project)
        timeline       = try c.decodeIfPresent(String.self, forKey: .timeline)
        timecode       = try c.decodeIfPresent(String.self, forKey: .timecode)
        rendering      = try c.decodeIfPresent(Bool.self,   forKey: .rendering) ?? false
        busy           = try c.decodeIfPresent(Bool.self,   forKey: .busy) ?? false
        transientError = try c.decodeIfPresent(String.self, forKey: .transientError)
    }

    /// True when Resolve is on a page inside a loaded project (actively editable).
    var inProject: Bool { running && apiOk && page != nil && (project?.isEmpty == false) }

    /// True when a project is loaded, even if Resolve is momentarily showing a dialog
    /// or grinding on a background task. This is the signal for "the user is in a project".
    var hasProject: Bool { running && apiOk && (project?.isEmpty == false) }

    var pageEnum: ResolvePage? { page.flatMap { ResolvePage(rawValue: $0) } }

    static let offline = ResolveStatus()
}

/// How the app is doing at talking to Resolve — surfaced in the dropdown.
enum ConnectionState: Equatable {
    case connected
    case resolveNotRunning
    case apiUnavailable(String)   // Resolve is up but scripting isn't answering
    case probeUnavailable(String) // we can't even run the helper (e.g. python missing)

    var isHealthy: Bool { self == .connected }

    var shortLabel: String {
        switch self {
        case .connected:            return "Connected"
        case .resolveNotRunning:    return "Resolve not running"
        case .apiUnavailable:       return "Can't reach Resolve scripting"
        case .probeUnavailable:     return "Tracker helper unavailable"
        }
    }

    var detail: String? {
        switch self {
        case .connected, .resolveNotRunning:  return nil
        case .apiUnavailable(let r):           return r
        case .probeUnavailable(let r):         return r
        }
    }
}

/// A recorded work session. Everything the UI shows is derived from an array of these.
/// Custom decoder so older `sessions.json` files (missing newer fields) still load.
struct Session: Codable, Identifiable {
    var id: UUID = UUID()
    var project: String
    var start: Date
    var end: Date
    var durationSec: Double
    var rate: Double
    var currency: String
    var note: String
    var pageSeconds: [String: Double] = [:]
    var timelineSeconds: [String: Double] = [:]
    var manual: Bool = false

    var earnings: Double { durationSec / 3600.0 * rate }

    init(id: UUID = UUID(), project: String, start: Date, end: Date, durationSec: Double,
         rate: Double, currency: String, note: String,
         pageSeconds: [String: Double] = [:], timelineSeconds: [String: Double] = [:],
         manual: Bool = false) {
        self.id = id; self.project = project; self.start = start; self.end = end
        self.durationSec = durationSec; self.rate = rate; self.currency = currency
        self.note = note; self.pageSeconds = pageSeconds
        self.timelineSeconds = timelineSeconds; self.manual = manual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        project         = try c.decodeIfPresent(String.self, forKey: .project) ?? "Untitled"
        start           = try c.decode(Date.self, forKey: .start)
        end             = try c.decodeIfPresent(Date.self, forKey: .end) ?? start
        durationSec     = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0
        rate            = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 0
        currency        = try c.decodeIfPresent(String.self, forKey: .currency) ?? "€"
        note            = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        pageSeconds     = try c.decodeIfPresent([String: Double].self, forKey: .pageSeconds) ?? [:]
        timelineSeconds = try c.decodeIfPresent([String: Double].self, forKey: .timelineSeconds) ?? [:]
        manual          = try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false
    }
}

struct Settings: Codable, Equatable {
    var rate: Double = 25.0                       // default / fallback rate
    var currency: String = "€"
    var projectRates: [String: Double] = [:]      // per-project overrides
    var idleMinutes: Int = 3                      // 0 = off
    var pauseDuringRenders: Bool = true           // don't idle-pause while Resolve is rendering
    var trackOnlyWhenFrontmost: Bool = true       // only accrue time while Resolve is the active app
    var playSoundOnStart: Bool = true
    var toastOnIdleResume: Bool = false
    var soundName: String = "Glass"
    var menuBarShowTime: Bool = true              // show H:MM:SS next to the icon
    var launchAtLogin: Bool = false

    init() {}

    /// Tolerant decoder — a settings.json from an earlier version keeps every value it had.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        rate              = try c.decodeIfPresent(Double.self, forKey: .rate) ?? d.rate
        currency          = try c.decodeIfPresent(String.self, forKey: .currency) ?? d.currency
        projectRates      = try c.decodeIfPresent([String: Double].self, forKey: .projectRates) ?? d.projectRates
        idleMinutes       = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        pauseDuringRenders = try c.decodeIfPresent(Bool.self, forKey: .pauseDuringRenders) ?? d.pauseDuringRenders
        trackOnlyWhenFrontmost = try c.decodeIfPresent(Bool.self, forKey: .trackOnlyWhenFrontmost) ?? d.trackOnlyWhenFrontmost
        playSoundOnStart  = try c.decodeIfPresent(Bool.self, forKey: .playSoundOnStart) ?? d.playSoundOnStart
        toastOnIdleResume = try c.decodeIfPresent(Bool.self, forKey: .toastOnIdleResume) ?? d.toastOnIdleResume
        soundName         = try c.decodeIfPresent(String.self, forKey: .soundName) ?? d.soundName
        menuBarShowTime   = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowTime) ?? d.menuBarShowTime
        launchAtLogin     = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    func rate(for project: String) -> Double { projectRates[project] ?? rate }

    static let `default` = Settings()

    static let availableSounds = ["Glass", "Tink", "Ping", "Pop", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Purr", "Sosumi", "Submarine"]
}

enum TrackerState: Equatable {
    case notInProject
    case tracking
    case idlePaused
    case manuallyPaused

    var isPaused: Bool { self == .idlePaused || self == .manuallyPaused }
}

/// Derived totals for the menu-bar panel.
struct Stats: Equatable {
    var project: String? = nil
    var todaySec: Double = 0
    var weekSec: Double = 0
    var projectTotalSec: Double = 0
    var projectEarnings: Double = 0
    var breakdown: [PageStat] = []

    struct PageStat: Equatable, Identifiable {
        var id: String { page }
        var page: String
        var seconds: Double
    }
}
