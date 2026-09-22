import Foundation
import AppKit
import ApplicationServices

/// What we managed to learn about the document open in an editor.
struct EditorDetail: Equatable {
    var document: String?   // project / file name
    var unit: String?       // sequence / composition
    var timecode: String?   // playhead; changes while playing back
}

/// Reads the open document (and where possible the active sequence/composition) from
/// the Adobe apps. Resolve is not handled here — it has a real scripting API and is
/// covered by the Python probe.
///
/// Everything runs off the main thread behind a hard timeout: an Adobe app that is busy
/// can leave an Apple Event unanswered for a long time, and the UI must not wait on it.
/// Callers get the last cached answer immediately and a refresh is kicked off in the
/// background. If a provider can't answer, the detail is simply absent and the session
/// is still tracked at app level.
final class EditorDetailProbe {
    private let queue = DispatchQueue(label: "com.jasongrech.resolveedittracker.detail")
    private let lock = NSLock()

    private var cache: [EditorApp: EditorDetail] = [:]
    private var lastFetch: [EditorApp: Date] = [:]
    private var inFlight: Set<EditorApp> = []

    /// How long a cached answer stays good. Document/sequence changes are not urgent
    /// enough to justify hammering the apps with Apple Events.
    private let refreshInterval: TimeInterval = 4

    /// Latest known detail, refreshing in the background when stale.
    func detail(for app: EditorApp) -> EditorDetail? {
        lock.lock()
        let cached = cache[app]
        let last = lastFetch[app] ?? .distantPast
        let busy = inFlight.contains(app)
        let stale = Date().timeIntervalSince(last) >= refreshInterval
        if stale && !busy { inFlight.insert(app) }
        lock.unlock()

        if stale && !busy {
            queue.async { [weak self] in
                guard let self else { return }
                let fresh = Self.fetch(app)
                self.lock.lock()
                if let fresh { self.cache[app] = fresh }
                self.lastFetch[app] = Date()
                self.inFlight.remove(app)
                self.lock.unlock()
            }
        }
        return cached
    }

    func forget(_ app: EditorApp) {
        lock.lock()
        cache[app] = nil
        lastFetch[app] = nil
        lock.unlock()
    }

    // MARK: - Per-app providers

    private static func fetch(_ app: EditorApp) -> EditorDetail? {
        switch app {
        case .premiere:     return premiereDetail()
        case .afterEffects: return afterEffectsDetail()
        // Photoshop and Lightroom are tracked at app level only: a photo pass means a
        // pile of throwaway documents, and naming each one is noise, not signal.
        case .photoshop, .lightroomClassic, .lightroom, .resolve: return nil
        }
    }

    // MARK: Premiere Pro — Accessibility only
    //
    // Premiere's entire AppleScript dictionary is `capture` and `editoriginal`, so both
    // names come from its UI: the project from the window title, the active sequence
    // from the Program Monitor's tab ("Program: <sequence>"), which always follows the
    // sequence in focus even when several are open in the Timeline.

    private static func premiereDetail() -> EditorDetail? {
        guard let pid = pid(of: .premiere), AXIsProcessTrusted() else { return nil }
        let ax = AXUIElementCreateApplication(pid)

        var detail: EditorDetail?
        for w in axChildren(ax, kAXWindowsAttribute) {
            if let title = axString(w, kAXTitleAttribute), let parsed = parsePremiereTitle(title) {
                detail = parsed
                break
            }
        }
        guard var detail else { return nil }

        // The panel tabs sit ~3 levels down; searching 4 deep visits ~200 elements, ~10 ms.
        var timecodes: [String] = []
        var queue: [(AXUIElement, Int)] = [(ax, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = axString(el, kAXRoleAttribute)
            let desc = axString(el, kAXDescriptionAttribute)
            if role == "AXRadioButton", let desc, desc.hasPrefix("Program: "), detail.unit == nil {
                let name = String(desc.dropFirst("Program: ".count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.hasPrefix("(") { detail.unit = name }   // "(no sequences)"
            } else if role == "AXTextField", desc == "UI_HotText",
                      let v = axString(el, kAXValueAttribute), looksLikeTimecode(v) {
                timecodes.append(v)
            }
            if depth < 4 {
                for c in axChildren(el, kAXChildrenAttribute) { queue.append((c, depth + 1)) }
            }
        }
        if !timecodes.isEmpty { detail.timecode = timecodes.joined(separator: "|") }
        return detail
    }

    /// Premiere titles its main window with the project's path, plus " *" while there
    /// are unsaved changes — which must be dropped, or every save would look like a new
    /// project. Also handles older shapes:
    ///   "/Volumes/Work/Client/Cut.prproj *"
    ///   "Adobe Premiere Pro 2026 - /Users/me/Cut.prproj"
    ///   "Adobe Premiere Pro 2026 - Cut.prproj : Episode 3"
    static func parsePremiereTitle(_ raw: String) -> EditorDetail? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("*") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        if let r = s.range(of: "Adobe Premiere Pro", options: .caseInsensitive), r.lowerBound == s.startIndex {
            s = String(s[r.upperBound...])
            // drop a release year and the separating dash
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " 0123456789"))
            if s.hasPrefix("-") { s = String(s.dropFirst()) }
            s = s.trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }

        // A trailing " : <sequence>" is the active sequence when Premiere includes it.
        var unit: String?
        if let sep = s.range(of: " : ", options: .backwards) {
            unit = String(s[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            s = String(s[..<sep.lowerBound])
        }

        var document = (s as NSString).lastPathComponent
        if document.lowercased().hasSuffix(".prproj") { document = String(document.dropLast(7)) }
        document = document.trimmingCharacters(in: .whitespaces)
        guard !document.isEmpty else { return nil }
        return EditorDetail(document: document, unit: unit?.isEmpty == false ? unit : nil)
    }

    // MARK: After Effects — ExtendScript over Apple Events
    //
    // AE's DoScript runs ExtendScript in-process, but in AE 2026 it always answers "0"
    // whatever the script returns — so the script writes its answer to a temp file.

    private static func afterEffectsDetail() -> EditorDetail? {
        // Address the running copy by its own ID (currently com.adobe.AfterEffects.application)
        // rather than guessing one that may change between releases.
        guard let bundleID = runningApp(.afterEffects)?.bundleIdentifier else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ret-ae-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        let js = [
            "var p = app.project;",
            "var d = (p && p.file) ? p.file.name : 'Untitled Project.aep';",
            "var a = p ? p.activeItem : null;",
            "var isComp = (a && a instanceof CompItem);",
            "var f = new File('\(out.path)'); f.encoding = 'UTF-8'; f.open('w');",
            // A plain-text separator: an escaped "\n" has to survive Swift, AppleScript and
            // ExtendScript quoting, and doesn't.
            "f.write(d + '|~|' + (isComp ? a.name : '') + '|~|' + (isComp ? a.time : ''));",
            "f.close();",
        ].joined(separator: " ")
        let script = """
        tell application id "\(bundleID)"
            DoScript "\(js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        guard runOSAScript(script, timeout: 3) != nil || FileManager.default.fileExists(atPath: out.path),
              let text = try? String(contentsOf: out, encoding: .utf8) else { return nil }

        let parts = text.components(separatedBy: "|~|")
        var doc = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if doc.lowercased().hasSuffix(".aep") { doc = String(doc.dropLast(4)) }
        let comp = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let time = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        guard !doc.isEmpty else { return nil }
        return EditorDetail(document: doc,
                            unit: comp.isEmpty ? nil : comp,
                            timecode: time.isEmpty ? nil : time)
    }

    // MARK: - Helpers

    private static func runningApp(_ app: EditorApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && EditorApp.matching(bundleID: $0.bundleIdentifier) == app
        }
    }

    private static func pid(of app: EditorApp) -> pid_t? { runningApp(app)?.processIdentifier }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func axChildren(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    /// "00:03:56:12" or drop-frame "00:03:56;12".
    private static func looksLikeTimecode(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}:\d{2}:\d{2}[:;]\d{2}$"#, options: .regularExpression) != nil
    }

    /// Runs AppleScript in a child process so a wedged Apple Event can be killed.
    /// `NSAppleScript` runs in-process and offers no way out if the target never answers.
    private static func runOSAScript(_ source: String, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()

        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }
}
