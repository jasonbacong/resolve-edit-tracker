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
    private var lastInProjectAt = Date()      // last reading that showed a live project (editing or busy)
    private var lastKnownPage = ResolvePage.edit.rawValue
    private var busySince: Date?              // when Resolve last went "busy" (off-page) while tracking
    private let maxBusySec: Double = 15 * 60  // stop if Resolve stays off-page this long while tracking
    private var announcedProject: String?
    private var activeWhilePausedSec: Double = 0
    private let manualResumeAfterSec: Double = 20
    private var lastStatsAt = Date.distantPast

    // Project-name debounce — Resolve flashes a default "Untitled Project" name while
    // loading a project or running a modal task; don't treat those as real switches.
    private var pendingProject: String?
    private var pendingProjectSince = Date.distantPast
    private let startGrace: TimeInterval = 4
    private let switchGrace: TimeInterval = 6

    // Frontmost-app gating
    private var awaySince: Date?              // when the editor stopped being frontmost while tracking
    private let awayGraceSec: Double = 90     // freeze this long before saving the session
    private var lastFrontmostEditor: EditorApp? = .resolve

    // Non-Resolve editors (Premiere, After Effects, Photoshop, Lightroom). These have no
    // scripting API worth the name, so being frontmost is the only signal we get.
    private let detailProbe = EditorDetailProbe()
    private var activeUnit: String?           // current sequence / composition

    // Playback detection — a moving playhead means the user is reviewing, not idle.
    private var lastTimecode: String?
    private var timecodeMovedAt = Date.distantPast
    private var zeroInputSince: Date?        // ~when keyboard/mouse input last stopped
    private let hardIdleSec: Double = 30 * 60 // playback / busy can't defer a stop past this

    private enum IdlePauseReason { case idle, away }
    private var idlePauseReason: IdlePauseReason = .idle

    private enum StartReason { case fresh, resume, projectSwitch }

    /// What Resolve is doing right now, distilled from a probe reading.
    private enum Presence {
        case editing(String)   // on a page, inside a loaded project
        case busy(String)      // project loaded, Resolve on a dialog / background task
        case noProject         // Resolve + API up, but no project (Project Manager)
        case apiDown           // Resolve up, scripting not answering
        case resolveGone       // Resolve not running
    }

    private func presence(_ s: ResolveStatus) -> Presence {
        if !s.running { return .resolveGone }
        if !s.apiOk { return .apiDown }
        guard let project = s.project, !project.isEmpty else { return .noProject }
        return s.page == nil ? .busy(project) : .editing(project)
    }

    /// How long a non-editing reading must persist before we commit to stopping.
    private func stopGrace(for p: Presence) -> TimeInterval {
        switch p {
        case .resolveGone:    return 4    // pgrep is reliable — no need to wait long
        case .apiDown:        return 10
        case .noProject:      return 20   // a dialog that also nulls the project recovers in seconds
        case .busy, .editing: return .infinity
        }
    }

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
        noteTimecode(newStatus.timecode)

        let now = Date()
        let p = presence(newStatus)
        switch p {
        case .editing, .busy:                lastInProjectAt = now
        case .noProject, .apiDown, .resolveGone: break
        }
        let confirmedOut = now.timeIntervalSince(lastInProjectAt) >= stopGrace(for: p)

        switch state {
        case .notInProject:
            guard case .editing(let project) = p else { pendingProject = nil; break }
            // Require the name to hold briefly before starting — filters the default
            // "Untitled Project" name Resolve flashes during load / modal tasks.
            if pendingProject != project {
                pendingProject = project
                pendingProjectSince = now
                break
            }
            guard now.timeIntervalSince(pendingProjectSince) >= startGrace else { break }
            pendingProject = nil

            let gatedOut = settings.trackOnlyWhenFrontmost && !isResolveFrontmost()
            if isIdleBeyondLimit() || gatedOut {
                state = .idlePaused
                idlePauseReason = gatedOut ? .away : .idle
                activeProject = project
                announcedProject = nil
                Log.write("• project open, waiting — \(gatedOut ? "not in Resolve" : "idle") (\(project))")
            } else {
                enterTracking(project: project, reason: .fresh)
            }

        case .tracking:
            switch p {
            case .editing(let project):
                if project == activeProject {
                    pendingProject = nil
                } else if pendingProject != project {
                    pendingProject = project
                    pendingProjectSince = now
                } else if now.timeIntervalSince(pendingProjectSince) >= switchGrace {
                    endSession(autoNote: "(auto-stopped: switched project)")
                    enterTracking(project: project, reason: .projectSwitch)
                    Log.write("⇄ switched project → \(project)")
                }
            case .busy:
                pendingProject = nil   // a modal task never accompanies a real switch
            case .noProject, .apiDown, .resolveGone:
                if confirmedOut {
                    let note = stopNote(for: newConnection)
                    endSession(autoNote: note)
                    state = .notInProject
                    announcedProject = nil
                    pendingProject = nil
                    Log.write("⏹ \(note)")
                }
            }

        case .idlePaused, .manuallyPaused:
            switch p {
            case .noProject, .apiDown, .resolveGone:
                if confirmedOut {
                    state = .notInProject
                    announcedProject = nil
                    pendingProject = nil
                }
            case .editing, .busy:
                break
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

    /// Records when the timeline playhead last moved, so playback can defeat the idle timer.
    private func noteTimecode(_ tc: String?) {
        guard let tc, !tc.isEmpty, tc != lastTimecode else { return }
        lastTimecode = tc
        timecodeMovedAt = Date()
    }

    /// True while the playhead is moving — playback, scrubbing, or jogging from a
    /// hardware panel (Speed Editor etc.) that doesn't register as keyboard/mouse.
    /// Used to defeat the idle timer, not to decide whether the user is "in Resolve".
    private var isPlayingBack: Bool {
        Date().timeIntervalSince(timecodeMovedAt) < 5
    }

    /// Which tracked editor is frontmost right now, if any. Our own popover / Settings
    /// window doesn't count as leaving the editor you were in.
    private func frontmostEditor() -> EditorApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return lastFrontmostEditor }
        if let mine = Bundle.main.bundleIdentifier, front.bundleIdentifier == mine {
            return lastFrontmostEditor
        }
        let match = EditorApp.matching(bundleID: front.bundleIdentifier)
        lastFrontmostEditor = match
        return match
    }

    /// The frontmost editor, but only if the user has it switched on.
    private func frontmostEnabledEditor() -> EditorApp? {
        guard let app = frontmostEditor(), settings.enabledEditors.contains(app) else { return nil }
        return app
    }

    private func isResolveFrontmost() -> Bool { frontmostEditor() == .resolve }

    /// Whether the frontmost-app requirement (if enabled) is currently met.
    private var trackingGateOpen: Bool {
        !settings.trackOnlyWhenFrontmost || isResolveFrontmost()
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

        switch state {
        case .tracking:
            if let pg = status.pageEnum?.rawValue { lastKnownPage = pg }

            // Freeze — don't accrue or stop — while the user is working in another app.
            // Save the session if they stay away past the grace window.
            if settings.trackOnlyWhenFrontmost && !isResolveFrontmost() {
                busySince = nil
                if awaySince == nil { awaySince = now }
                elapsed = current?.durationSec ?? 0
                if now.timeIntervalSince(awaySince!) >= awayGraceSec {
                    endSession(autoNote: "(auto-stopped: switched away from Resolve)")
                    state = .idlePaused
                    idlePauseReason = .away
                    elapsed = 0
                    awaySince = nil
                    Log.write("⏸ away from Resolve")
                }
                break
            }
            awaySince = nil

            if status.busy {
                if busySince == nil { busySince = now }
            } else {
                busySince = nil
            }

            if dt > 0, dt < 5, var session = current {
                let page = status.pageEnum?.rawValue ?? lastKnownPage
                session.pageSeconds[page, default: 0] += dt
                session.timelineSeconds[status.timeline ?? "—", default: 0] += dt
                session.durationSec = session.pageSeconds.values.reduce(0, +)
                session.end = now
                current = session
            }
            elapsed = current?.durationSec ?? 0

            if idle < 5 {
                zeroInputSince = nil
            } else if zeroInputSince == nil {
                zeroInputSince = now.addingTimeInterval(-idle)
            }

            // Renders (if opted in) fully exempt from idle. Resolve's modal tasks and
            // playback review also defer an idle-stop — but only up to a hard ceiling,
            // so a looping playback left running can't bill forever.
            let renderHold = settings.pauseDuringRenders && status.rendering
            let softHold = status.busy || isPlayingBack
            let hardIdle = (zeroInputSince.map { now.timeIntervalSince($0) } ?? 0) >= hardIdleSec

            if let since = busySince, now.timeIntervalSince(since) > maxBusySec {
                endSession(autoNote: "(auto-stopped: Resolve inactive)")
                state = .idlePaused
                idlePauseReason = .idle
                elapsed = 0
                busySince = nil
                Log.write("⏸ paused — Resolve off-page for \(Int(maxBusySec / 60))m")
            } else if settings.idleMinutes > 0, !renderHold,
                      idle >= Double(settings.idleMinutes) * 60, !softHold || hardIdle {
                endSession(autoNote: "(auto-stopped: idle)")
                state = .idlePaused
                idlePauseReason = .idle
                elapsed = 0
                Log.write("⏸ idle pause (idle \(Int(idle))s)")
            }

        case .idlePaused:
            if idle < 2, trackingGateOpen, status.hasProject, let project = status.project {
                enterTracking(project: project,
                              reason: announcedProject == project ? .resume : .fresh)
            }

        case .manuallyPaused:
            elapsed = 0
            if status.hasProject, idle < 3, dt > 0, dt < 5, trackingGateOpen {
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
        busySince = nil
        awaySince = nil
        pendingProject = nil
        zeroInputSince = nil
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
            if status.hasProject, let project = status.project {
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
            if status.busy {
                let last = ResolvePage(rawValue: lastKnownPage)?.displayName ?? "Working"
                return "Tracking · \(last)"
            }
            return "Tracking · \(status.pageEnum?.displayName ?? status.page ?? "—")"
        case .idlePaused:     return idlePauseReason == .away ? "Paused · switch to Resolve" : "Paused (idle)"
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
