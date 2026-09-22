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
    @Published private(set) var sessionApp: EditorApp = .resolve   // app of the current / last-paused session
    private let detailProbe = EditorDetailProbe()
    private var activeUnit: String?           // current sequence / composition
    private var pendingApp: EditorApp?        // editor that just came to the front
    private var pendingAppSince = Date.distantPast
    private let appSwitchGrace: TimeInterval = 8  // a quick peek at another app doesn't split the session
    private var pendingDoc: String?
    private var pendingDocSince = Date.distantPast
    private var loggedFront: EditorApp?       // last front app written to the debug log
    private var adobeTimecode: String?        // Premiere / AE playhead, for playback detection
    private var adobeTimecodeMovedAt = Date.distantPast

    // Playback detection — a moving playhead means the user is reviewing, not idle.
    private var lastTimecode: String?
    private var timecodeMovedAt = Date.distantPast
    private var zeroInputSince: Date?        // ~when keyboard/mouse input last stopped
    private let hardIdleSec: Double = 30 * 60 // playback / busy can't defer a stop past this

    private enum IdlePauseReason { case idle, away }
    private var idlePauseReason: IdlePauseReason = .idle

    private enum StartReason { case fresh, resume, projectSwitch, appSwitch }

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

        // While an Adobe session owns the tracker, Resolve readings are kept for display
        // but must not drive state — "Resolve has no project" is not a reason to stop
        // a Premiere session.
        if sessionApp != .resolve && state != .notInProject {
            rebuildStats()
            return
        }

        switch state {
        case .notInProject:
            guard settings.enabledEditors.contains(.resolve),
                  case .editing(let project) = p else { pendingProject = nil; break }
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
        settings.enabledEditors.contains(.resolve)
            && (!settings.trackOnlyWhenFrontmost || isResolveFrontmost())
    }

    private func isRunning(_ app: EditorApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && EditorApp.matching(bundleID: $0.bundleIdentifier) == app
        }
    }

    /// The document (and sequence/comp) open in an Adobe app, if detail tracking is on
    /// and the app answered. Falls back to the app's own name.
    private func documentName(for app: EditorApp) -> (project: String, unit: String?) {
        guard settings.trackDocumentDetail, app != .resolve, app.unitLabel != nil,
              let d = detailProbe.detail(for: app), let doc = d.document
        else { return (app.displayName, nil) }
        return (doc, d.unit)
    }

    private func enterTracking(project: String, reason: StartReason,
                               app: EditorApp = .resolve, unit: String? = nil,
                               creditSince: Date? = nil) {
        beginSession(project: project, app: app, unit: unit, creditSince: creditSince)
        state = .tracking
        let label = app == .resolve || project == app.displayName
            ? project : "\(app.shortName) · \(project)"
        switch reason {
        case .fresh:
            Log.write("▶︎ start tracking — \(label)")
            ToastController.shared.show(
                title: "Tracking started", subtitle: label,
                symbol: "record.circle.fill",
                playSound: settings.playSoundOnStart, soundName: settings.soundName
            )
        case .resume:
            Log.write("▶︎ resume — \(label)")
            if settings.toastOnIdleResume {
                ToastController.shared.show(
                    title: "Resumed", subtitle: label,
                    symbol: "record.circle.fill",
                    playSound: false, soundName: settings.soundName
                )
            }
        case .projectSwitch:
            ToastController.shared.show(
                title: "Switched project", subtitle: label,
                symbol: "arrow.triangle.2.circlepath",
                playSound: false, soundName: settings.soundName
            )
        case .appSwitch:
            // The menu-bar icon changing is the signal; a toast on every app switch is noise.
            Log.write("⇄ switched app → \(label)")
        }
        announcedProject = project
    }

    // MARK: - Per-second tick

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let idle = IdleMonitor.idleSeconds()
        let front = frontmostEnabledEditor()
        if front != loggedFront {
            loggedFront = front
            Log.write("◧ in front: \(front?.displayName ?? "another app") (state \(state), idle \(Int(idle))s)")
        }
        // How long the current front app has held the front — the switch grace is
        // measured from here, never from when you left the previous app.
        if front != pendingApp {
            pendingApp = front
            pendingAppSince = now
        }

        if state == .tracking && sessionApp != .resolve {
            tickTrackingOther(front: front, now: now, dt: dt, idle: idle)
        } else if let front, front != .resolve {
            tickEnterOther(front, now: now, dt: dt, idle: idle)
        } else {
            // Paused in an Adobe app that has since quit — nothing left to resume there.
            if state.isPaused, sessionApp != .resolve, !isRunning(sessionApp) {
                state = .notInProject
                sessionApp = .resolve
                announcedProject = nil
            }
            tickResolve(now: now, dt: dt, idle: idle)
        }

        tickCount += 1
        if tickCount % 20 == 0 { store.saveCurrent(current) }
        rebuildStats()
    }

    // MARK: Adobe apps

    /// Tracking an Adobe app: accrue while it's in front; when something else is, freeze,
    /// then hand over to the new editor or save the session.
    private func tickTrackingOther(front: EditorApp?, now: Date, dt: Double, idle: Double) {
        let app = sessionApp
        guard isRunning(app) else {
            endSession(autoNote: "(auto-stopped: \(app.shortName) quit)")
            state = .notInProject
            sessionApp = .resolve
            announcedProject = nil
            Log.write("⏹ \(app.shortName) quit")
            return
        }

        if front == app {
            awaySince = nil
            followDocument(in: app, now: now)
            guard state == .tracking, sessionApp == app else { return }   // a document switch restarted us
            accrue(dt: dt, now: now, page: app.rawValue, unit: activeUnit)
            // As with Resolve: a moving playhead means you're reviewing, not away —
            // up to the same hard ceiling, so looped playback can't bill forever.
            // (The playhead is read every few seconds, hence the wider window.)
            let reviewing = now.timeIntervalSince(adobeTimecodeMovedAt) < 10
            if settings.idleMinutes > 0, idle >= Double(settings.idleMinutes) * 60,
               !reviewing || idle >= hardIdleSec {
                endSession(autoNote: "(auto-stopped: idle)")
                state = .idlePaused
                idlePauseReason = .idle
                Log.write("⏸ idle pause — \(app.shortName) (idle \(Int(idle))s)")
            }
            return
        }

        // Something else is in front — freeze the clock.
        elapsed = current?.durationSec ?? 0
        if awaySince == nil { awaySince = now }
        let away = now.timeIntervalSince(awaySince!)
        let held = now.timeIntervalSince(pendingAppSince)

        // Another tracked editor has held the front long enough: hand over to it,
        // crediting it only the time it has actually been in front.
        if let front, held >= appSwitchGrace {
            if front == .resolve {
                if status.hasProject, let project = status.project {
                    endSession(autoNote: "(auto-stopped: switched to Resolve)")
                    enterTracking(project: project, reason: .appSwitch,
                                  unit: status.timeline, creditSince: pendingAppSince)
                    return
                }
            } else {
                let doc = documentName(for: front)
                endSession(autoNote: "(auto-stopped: switched to \(front.shortName))")
                enterTracking(project: doc.project, reason: .appSwitch,
                              app: front, unit: doc.unit, creditSince: pendingAppSince)
                return
            }
        }

        if away >= awayGraceSec {
            endSession(autoNote: "(auto-stopped: switched away from \(app.shortName))")
            state = .idlePaused
            idlePauseReason = .away
            awaySince = nil
            Log.write("⏸ away from \(app.shortName)")
        }
    }

    /// An Adobe app is in front and we're not yet tracking it.
    private func tickEnterOther(_ app: EditorApp, now: Date, dt: Double, idle: Double) {
        switch state {
        case .tracking:
            // Moving from Resolve. Freeze it; hand over once the new app has stuck.
            elapsed = current?.durationSec ?? 0
            busySince = nil
            guard now.timeIntervalSince(pendingAppSince) >= appSwitchGrace else { return }
            let doc = documentName(for: app)
            endSession(autoNote: "(auto-stopped: switched to \(app.shortName))")
            enterTracking(project: doc.project, reason: .appSwitch,
                          app: app, unit: doc.unit, creditSince: pendingAppSince)

        case .idlePaused where app == sessionApp:
            // Back in the app we paused in — resume on the first input, like Resolve.
            elapsed = 0
            guard idle < 2 else { return }
            let doc = documentName(for: app)
            let project = doc.project == app.displayName ? (activeProject ?? doc.project) : doc.project
            enterTracking(project: project,
                          reason: announcedProject == project ? .resume : .fresh,
                          app: app, unit: doc.unit ?? activeUnit)

        case .idlePaused, .notInProject:
            // Starting fresh needs a few seconds of real use, so a quick peek at an app
            // doesn't leave a stub session behind.
            elapsed = 0
            if idle >= 10 { pendingAppSince = now; return }
            guard now.timeIntervalSince(pendingAppSince) >= appSwitchGrace else { return }
            let doc = documentName(for: app)
            enterTracking(project: doc.project, reason: .fresh,
                          app: app, unit: doc.unit, creditSince: pendingAppSince)

        case .manuallyPaused:
            elapsed = 0
            guard app == sessionApp, idle < 3, dt > 0, dt < 5 else {
                activeWhilePausedSec = 0
                return
            }
            activeWhilePausedSec += dt
            guard activeWhilePausedSec >= manualResumeAfterSec else { return }
            activeWhilePausedSec = 0
            Log.write("▶︎ auto-resume from manual pause (kept working)")
            enterTracking(project: activeProject ?? app.displayName, reason: .resume,
                          app: app, unit: activeUnit)
        }
    }

    /// Keeps the session's document and sequence in step with the app. The first real
    /// name to arrive just labels the session (it may start before the app answers); a
    /// later change of document splits it, once the new name has held for a few seconds.
    private func followDocument(in app: EditorApp, now: Date) {
        guard settings.trackDocumentDetail, app.unitLabel != nil,
              let d = detailProbe.detail(for: app), let doc = d.document else { return }
        activeUnit = d.unit
        if let tc = d.timecode, tc != adobeTimecode {
            if adobeTimecode != nil { adobeTimecodeMovedAt = now }
            adobeTimecode = tc
        }

        if doc == activeProject { pendingDoc = nil; return }

        // Placeholder names — the app's own name before it answered, or an unsaved AE
        // project — get relabelled in place, so the first save doesn't split the session.
        let placeholder = activeProject == app.displayName || activeProject == "Untitled Project"
        if placeholder, var s = current {
            s.project = doc
            s.rate = settings.rate(for: doc)
            // Time recorded before the name arrived belongs to the first sequence we see.
            if s.timelineSeconds.isEmpty, let unit = d.unit, s.durationSec > 0 {
                s.timelineSeconds[unit] = s.durationSec
            }
            current = s
            activeProject = doc
            announcedProject = doc
            Log.write("✎ \(app.shortName) session is \(doc)\(d.unit.map { " · \($0)" } ?? "")")
            return
        }

        if pendingDoc != doc {
            pendingDoc = doc
            pendingDocSince = now
            return
        }
        guard now.timeIntervalSince(pendingDocSince) >= switchGrace else { return }
        endSession(autoNote: "(auto-stopped: switched project)")
        enterTracking(project: doc, reason: .projectSwitch, app: app, unit: d.unit)
        Log.write("⇄ switched project → \(app.shortName) — \(doc)")
    }

    private func accrue(dt: Double, now: Date, page: String, unit: String?) {
        guard dt > 0, dt < 5, var session = current else {
            elapsed = current?.durationSec ?? 0
            return
        }
        session.pageSeconds[page, default: 0] += dt
        if let unit { session.timelineSeconds[unit, default: 0] += dt }
        session.durationSec = session.pageSeconds.values.reduce(0, +)
        session.end = now
        current = session
        elapsed = session.durationSec
    }

    // MARK: Resolve

    private func tickResolve(now: Date, dt: Double, idle: Double) {
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
    }

    // MARK: - Session bookkeeping

    /// `creditSince` backdates the start — used when handing over between apps, so the
    /// seconds spent confirming the switch belong to the new app rather than vanishing.
    private func beginSession(project: String, app: EditorApp = .resolve,
                              unit: String? = nil, creditSince: Date? = nil) {
        activeProject = project
        activeUnit = unit
        sessionApp = app
        busySince = nil
        awaySince = nil
        pendingProject = nil
        pendingApp = nil
        pendingDoc = nil
        zeroInputSince = nil
        adobeTimecode = nil
        let now = Date()
        let start = min(creditSince ?? now, now)
        let credited = now.timeIntervalSince(start)
        var session = Session(
            app: app,
            project: project,
            start: start,
            end: now,
            durationSec: credited,
            rate: settings.rate(for: project),
            currency: settings.currency,
            note: ""
        )
        if credited > 0 {
            session.pageSeconds[app == .resolve ? lastKnownPage : app.rawValue] = credited
            if let unit { session.timelineSeconds[unit] = credited }
        }
        current = session
        elapsed = credited
        lastTick = now
        store.saveCurrent(current)
    }

    private func endSession(autoNote: String) {
        guard var session = current else { return }
        // `end` already holds the last second actually tracked. Stamping "now" here
        // would stretch a session over the time it sat frozen (away, asleep) before
        // being saved, and make back-to-back sessions overlap on the timesheet.
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
            if sessionApp != .resolve, isRunning(sessionApp) {
                enterTracking(project: activeProject ?? sessionApp.displayName, reason: .resume,
                              app: sessionApp, unit: activeUnit)
            } else if status.hasProject, let project = status.project {
                enterTracking(project: project,
                              reason: announcedProject == project ? .resume : .fresh)
            }
        case .notInProject:
            break
        }
        rebuildStats(force: true)
    }

    /// Whether the Pause/Resume button has anything to act on.
    var canToggle: Bool {
        switch state {
        case .tracking:                   return true
        case .idlePaused, .manuallyPaused: return (sessionApp != .resolve && isRunning(sessionApp)) || status.hasProject
        case .notInProject:               return false
        }
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
        if s.pageSeconds.isEmpty {
            s.pageSeconds = [s.app == .resolve ? ResolvePage.edit.rawValue : s.app.rawValue: s.durationSec]
        }
        store.update(s)
        rebuildStats(force: true)
    }

    func addManualSession(project: String, start: Date, minutes: Double, note: String,
                          page: ResolvePage, app: EditorApp = .resolve) {
        let dur = max(0, minutes * 60)
        let s = Session(
            app: app,
            project: project.isEmpty ? "Untitled" : project,
            start: start,
            end: start.addingTimeInterval(dur),
            durationSec: dur,
            rate: settings.rate(for: project),
            currency: settings.currency,
            note: note,
            pageSeconds: [app == .resolve ? page.rawValue : app.rawValue: dur],
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
        let app = state == .notInProject ? EditorApp.resolve : sessionApp
        stats = StatsBuilder.build(
            sessions: store.sessions,
            current: current,
            project: app == .resolve ? (status.project ?? activeProject) : activeProject,
            app: app
        )
    }

    /// Reading Premiere's window needs Accessibility access for this app.
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func onSettingsChanged(from old: Settings) {
        if settings.launchAtLogin != old.launchAtLogin {
            let effective = LoginItem.setEnabled(settings.launchAtLogin)
            if effective != settings.launchAtLogin { settings.launchAtLogin = effective }
        }
        if settings.trackDocumentDetail && !old.trackDocumentDetail && !accessibilityGranted {
            requestAccessibility()
        }
        // An app was switched off while we were tracking it.
        if state == .tracking, !settings.enabledEditors.contains(sessionApp) {
            endSession(autoNote: "(tracking turned off for \(sessionApp.shortName))")
            state = .notInProject
            sessionApp = .resolve
            announcedProject = nil
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

    /// The editor whose icon belongs in the menu bar: the one being tracked.
    var menuBarEditor: EditorApp? { state == .tracking ? sessionApp : nil }

    var headerTitle: String {
        switch state {
        case .tracking, .idlePaused, .manuallyPaused:
            if sessionApp != .resolve { return activeProject ?? sessionApp.displayName }
            return status.project ?? activeProject ?? "Resolve Edit Tracker"
        case .notInProject:
            return status.project ?? stats.project ?? "Resolve Edit Tracker"
        }
    }

    var statusLine: String {
        if state == .tracking && sessionApp != .resolve {
            if let unit = activeUnit { return "\(sessionApp.shortName) · \(unit)" }
            return "Tracking · \(sessionApp.shortName)"
        }
        switch state {
        case .tracking:
            if status.rendering { return "Tracking · Rendering" }
            if status.busy {
                let last = ResolvePage(rawValue: lastKnownPage)?.displayName ?? "Working"
                return "Tracking · \(last)"
            }
            return "Tracking · \(status.pageEnum?.displayName ?? status.page ?? "—")"
        case .idlePaused:
            return idlePauseReason == .away ? "Paused · switch to \(sessionApp.shortName)" : "Paused (idle)"
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
