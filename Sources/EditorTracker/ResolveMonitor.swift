import Foundation

/// Runs the Python probe as a child process, turns its stdout into `ResolveStatus`
/// values, and reports an overall `ConnectionState`. Restarts the probe if it dies;
/// gives up (with a reason) if it can't be run at all.
final class ResolveMonitor {
    private let onUpdate: (ResolveStatus, ConnectionState) -> Void
    private let queue = DispatchQueue(label: "com.jasongrech.resolveedittracker.monitor")
    private var process: Process?
    private var buffer = Data()
    private var stopped = false

    private var consecutiveLaunchFailures = 0
    private var lastGoodLine = Date.distantPast
    private var lastStatus = ResolveStatus.offline
    private var watchdog: DispatchSourceTimer?

    private let pythonPath = "/usr/bin/python3"

    init(onUpdate: @escaping (ResolveStatus, ConnectionState) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            self?.startWatchdog()
            self?.launch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.watchdog?.cancel()
            self?.watchdog = nil
            self?.process?.terminate()
            self?.process = nil
        }
    }

    // MARK: - Probe process

    private func scriptURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor_tracker_probe.py")
        try? probeScriptSource.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func launch() {
        guard !stopped else { return }
        buffer.removeAll(keepingCapacity: true)

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            report(.probeUnavailable("python3 not found at \(pythonPath) — install Xcode or the Command Line Tools"))
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.launch() }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptURL().path]

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        proc.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.queue.async {
                self.consecutiveLaunchFailures += 1
                if self.consecutiveLaunchFailures >= 4 {
                    self.report(.probeUnavailable("the tracker helper keeps quitting unexpectedly"))
                }
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.launch() }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            consecutiveLaunchFailures += 1
            report(.probeUnavailable("couldn't start python3 (\(error.localizedDescription))"))
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.launch() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let status = try? JSONDecoder().decode(ResolveStatus.self, from: line)
            else { continue }

            consecutiveLaunchFailures = 0
            lastGoodLine = Date()

            if status.transientError != nil { continue }   // keep last good state

            lastStatus = status
            report(connectionState(for: status), status: status)
        }
    }

    // MARK: - Connection state

    private func connectionState(for s: ResolveStatus) -> ConnectionState {
        if !s.running { return .resolveNotRunning }
        if !s.apiOk { return .apiUnavailable(s.reason ?? "Resolve scripting isn't responding") }
        return .connected
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            guard Date().timeIntervalSince(self.lastGoodLine) > 12 else { return }
            self.report(.probeUnavailable("no response from the tracker helper — restarting"))
            // A stuck probe won't fire terminationHandler; force a restart.
            if let p = self.process, p.isRunning {
                self.lastGoodLine = Date()   // give the fresh one a grace window
                p.terminate()
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func report(_ state: ConnectionState, status: ResolveStatus? = nil) {
        let s = status ?? lastStatus
        DispatchQueue.main.async { [onUpdate] in onUpdate(s, state) }
    }
}
