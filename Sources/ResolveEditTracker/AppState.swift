import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static private(set) weak var shared: AppState?

    // Published UI state
    @Published private(set) var state: TrackerState = .notInProject
    @Published private(set) var status: ResolveStatus = .offline
    @Published private(set) var connection: ConnectionState = .resolveNotRunning
    @Published private(set) var stats: Stats = Stats()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var settings: Settings { didSet { onSettingsChanged(from: oldValue) } }
    @Published var noteDraft: String = ""

    // Internals
    private let store = SessionStore()
    private var monitor: ResolveMonitor?
    private var ticker: Timer?
    private var current: Session?
    private var activeProject: String?
    private var lastTick = Date()
    private var tickCount = 0
    private var notInProjectStreak = 0
    private let stopConfirmations = 3
    private var announcedProject: String?
    private var activeWhilePausedSec: Double = 0
    private let manualResumeAfterSec: Double = 20
    private var lastStatsAt = Date.distantPast

    private enum StartReason { case fresh, resume, projectSwitch }

    private let settingsURL: URL

    var storeDirectory: URL { store.directory }
    var sessions: [Session] { store.sessions }

    var projectNames: [String] {
        var names = Set(store.sessions.map(\.project))
        if let p = status.project { names.insert(p) }
        if let p = activeProject { names.insert(p) }
        return names.sorted()
    }

    // MARK: - Lifecycle

    init() {
        settingsURL = store.directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
        AppState.shared = self

        Log.write("— launch —")
        recoverCrashedSession()
        rebuildStats(force: true)

        settings.launchAtLogin = LoginItem.isEnabled

        monitor = ResolveMonitor { [weak self] status, connection in
            MainActor.assumeIsolated { self?.handle(status, connection) }
        }
        monitor?.start()

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker?.tolerance = 0.2

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastTick = Date() }
        }
    }

    private func recoverCrashedSession() {
        guard var s = store.loadCurrent() else { return }
        s.durationSec = s.pageSeconds.values.reduce(0, +)
        s.end = max(s.end, s.start.addingTimeInterval(s.durationSec))
        if s.durationSec >= 1 {
            s.note = ["(recovered)", s.note].filter { !$0.isEmpty }.joined(separator: " ")
            store.append(s)
        }
        store.saveCurrent(nil)
    }

    private func handleSleep() {
        if current != nil { endSession(autoNote: "(auto-stopped: Mac sleep)") }
        if state == .tracking { state = .idlePaused }
        lastTick = Date()
        Log.write("💤 sleep")
    }

    // MARK: - Resolve status handling

    private func handle(_ newStatus: ResolveStatus, _ newConnection: ConnectionState) {
        status = newStatus
        connection = newConnection

        let inProject = newStatus.inProject
        if inProject { notInProjectStreak = 0 } else { notInProjectStreak += 1 }
        let confirmedOut = notInProjectStreak >= stopConfirmations

        switch state {
        case .notInProject:
            if inProject, let project = newStatus.project {
                if isIdleBeyondLimit() {
                    state = .idlePaused
                    activeProject = project
                    announcedProject = nil
                    Log.write("• project open but idle — waiting for input (\(project))")
                } else {
                    enterTracking(project: project, reason: .fresh)
                }
            }

        case .tracking:
            if !inProject {
                if confirmedOut {
                    endSession(autoNote: stopNote(for: newConnection))
                    state = .notInProject
                    announcedProject = nil
                    Log.write("⏹ \(stopNote(for: newConnection))")
                }
            } else if let project = newStatus.project, project != activeProject {
                endSession(autoNote: "(auto-stopped: switched project)")
                enterTracking(project: project, reason: .projectSwitch)
                Log.write("⇄ switched project → \(project)")
            }

        case .idlePaused, .manuallyPaused:
            if !inProject, confirmedOut {
                state = .notInProject
                announcedProject = nil
            }
        }

        rebuildStats()
    }

    private func stopNote(for connection: ConnectionState) -> String {
        switch connection {
        case .resolveNotRunning:  return "(auto-stopped: Resolve quit)"
        case .apiUnavailable:     return "(auto-stopped: lost Resolve connection)"
        case .probeUnavailable:   return "(auto-stopped: tracker helper stopped)"
        case .connected:          return "(auto-stopped: project closed)"
        }
    }

    private func isIdleBeyondLimit() -> Bool {
        guard settings.idleMinutes > 0 else { return false }
        if settings.pauseDuringRenders && status.rendering { return false }
        return IdleMonitor.idleSeconds() >= Double(settings.idleMinutes) * 60
    }

    private func enterTracking(project: String, reason: StartReason) {
        beginSession(project: project)
        state = .tracking
        switch reason {
        case .fresh:
            Log.write("▶︎ start tracking — \(project)")
            ToastController.shared.show(
                title: "Tracking started", subtitle: project,
                symbol: "record.circle.fill",
                playSound: settings.playSoundOnStart, soundName: settings.soundName
            )
        case .resume:
            Log.write("▶︎ resume — \(project)")
            if settings.toastOnIdleResume {
                ToastController.shared.show(
                    title: "Resumed", subtitle: project,
                    symbol: "record.circle.fill",
                    playSound: false, soundName: settings.soundName
                )
            }
        case .projectSwitch:
            ToastController.shared.show(
                title: "Switched project", subtitle: project,
                symbol: "arrow.triangle.2.circlepath",
                playSound: false, soundName: settings.soundName
            )
        }
        announcedProject = project
    }

    // MARK: - Per-second tick

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let idle = IdleMonitor.idleSeconds()
        let renderHold = settings.pauseDuringRenders && status.rendering
        let idleLimit: Double = settings.idleMinutes > 0 && !renderHold
            ? Double(settings.idleMinutes) * 60
            : .greatestFiniteMagnitude

        switch state {
        case .tracking:
            if dt > 0, dt < 5, var session = current {
                let page = status.pageEnum?.rawValue ?? ResolvePage.edit.rawValue
                session.pageSeconds[page, default: 0] += dt
                session.timelineSeconds[status.timeline ?? "—", default: 0] += dt
                session.durationSec = session.pageSeconds.values.reduce(0, +)
                session.end = now
                current = session
            }
            elapsed = current?.durationSec ?? 0

            if idle >= idleLimit {
                endSession(autoNote: "(auto-stopped: idle)")
                state = .idlePaused
                elapsed = 0
                Log.write("⏸ idle pause (idle \(Int(idle))s)")
            }

        case .idlePaused:
            if idle < 2, status.inProject, let project = status.project {
                enterTracking(project: project,
                              reason: announcedProject == project ? .resume : .fresh)
            }

        case .manuallyPaused:
            elapsed = 0
            if status.inProject, idle < 3, dt > 0, dt < 5 {
                activeWhilePausedSec += dt
                if activeWhilePausedSec >= manualResumeAfterSec, let project = status.project {
                    Log.write("▶︎ auto-resume from manual pause (kept working)")
                    enterTracking(project: project,
                                  reason: announcedProject == project ? .resume : .fresh)
                    activeWhilePausedSec = 0
                }
            } else {
                activeWhilePausedSec = 0
            }

        case .notInProject:
            elapsed = 0
        }

        tickCount += 1
        if tickCount % 20 == 0 { store.saveCurrent(current) }
        rebuildStats()
    }

    // MARK: - Session bookkeeping

    private func beginSession(project: String) {
        activeProject = project
        let now = Date()
        current = Session(
            project: project,
            start: now,
            end: now,
            durationSec: 0,
            rate: settings.rate(for: project),
            currency: settings.currency,
            note: ""
        )
        lastTick = now
        store.saveCurrent(current)
    }

    private func endSession(autoNote: String) {
        guard var session = current else { return }
        session.end = Date()
        session.durationSec = session.pageSeconds.values.reduce(0, +)
        let user = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        session.note = [user, autoNote].filter { !$0.isEmpty }.joined(separator: " ")
        if session.durationSec >= 1 {
            store.append(session)
        }
        current = nil
        store.saveCurrent(nil)
        noteDraft = ""
        elapsed = 0
        rebuildStats(force: true)
    }

    // MARK: - User actions

    func togglePause() {
        switch state {
        case .tracking:
            endSession(autoNote: "(paused)")
            state = .manuallyPaused
            activeWhilePausedSec = 0
            Log.write("⏸ manual pause")
        case .manuallyPaused, .idlePaused:
            if status.inProject, let project = status.project {
                enterTracking(project: project,
                              reason: announcedProject == project ? .resume : .fresh)
            }
        case .notInProject:
            break
        }
        rebuildStats(force: true)
    }

    func flushForQuit() {
        if current != nil { endSession(autoNote: "(app quit)") }
        store.saveCurrent(nil)
        monitor?.stop()
    }

    // MARK: - History editing

    func deleteSessions(_ ids: Set<UUID>) {
        store.delete(ids: ids)
        rebuildStats(force: true)
    }

    func updateSession(_ session: Session) {
        var s = session
        s.durationSec = max(0, s.durationSec)
        s.end = s.start.addingTimeInterval(s.durationSec)
        if s.pageSeconds.isEmpty { s.pageSeconds = ["edit": s.durationSec] }
        store.update(s)
        rebuildStats(force: true)
    }

    func addManualSession(project: String, start: Date, minutes: Double, note: String, page: ResolvePage) {
        let dur = max(0, minutes * 60)
        let s = Session(
            project: project.isEmpty ? "Untitled" : project,
            start: start,
            end: start.addingTimeInterval(dur),
            durationSec: dur,
            rate: settings.rate(for: project),
            currency: settings.currency,
            note: note,
            pageSeconds: [page.rawValue: dur],
            timelineSeconds: [:],
            manual: true
        )
        store.append(s)
        rebuildStats(force: true)
        Log.write("＋ manual entry — \(s.project) \(Int(minutes))m")
    }

    func clearHistory() {
        store.replaceAll([])
        announcedProject = nil
        rebuildStats(force: true)
        Log.write("history cleared")
    }

    func importSessions(from text: String) -> Int {
        let imported = CSVIO.import(text, defaultCurrency: settings.currency)
        guard !imported.isEmpty else { return 0 }
        store.replaceAll(store.sessions + imported)
        rebuildStats(force: true)
        return imported.count
    }

    func exportCSV() -> String { CSVIO.export(store.sessions) }

    // MARK: - Derived

    private func rebuildStats(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastStatsAt) < 2 { return }
        lastStatsAt = now
        stats = StatsBuilder.build(
            sessions: store.sessions,
            current: current,
            project: status.project ?? activeProject
        )
    }

    private func onSettingsChanged(from old: Settings) {
        if settings.launchAtLogin != old.launchAtLogin {
            let effective = LoginItem.setEnabled(settings.launchAtLogin)
            if effective != settings.launchAtLogin { settings.launchAtLogin = effective }
        }
        if let data = try? JSONEncoder.pretty.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
        rebuildStats(force: true)
    }

    // MARK: - Menu-bar helpers

    var menuBarSymbol: String {
        if !connection.isHealthy && state == .notInProject { return "exclamationmark.triangle.fill" }
        switch state {
        case .tracking:       return "record.circle.fill"
        case .idlePaused,
             .manuallyPaused: return "pause.circle.fill"
        case .notInProject:   return "timer"
        }
    }

    var menuBarText: String? {
        guard settings.menuBarShowTime, state == .tracking else { return nil }
        return Fmt.hms(elapsed)
    }

    var statusLine: String {
        switch state {
        case .tracking:
            if status.rendering { return "Tracking · Rendering" }
            return "Tracking · \(status.pageEnum?.displayName ?? status.page ?? "—")"
        case .idlePaused:     return "Paused (idle)"
        case .manuallyPaused: return "Paused"
        case .notInProject:
            switch connection {
            case .connected:          return "Resolve open · no project"
            case .resolveNotRunning:  return "Resolve not running"
            case .apiUnavailable:     return connection.shortLabel
            case .probeUnavailable:   return connection.shortLabel
            }
        }
    }
}
