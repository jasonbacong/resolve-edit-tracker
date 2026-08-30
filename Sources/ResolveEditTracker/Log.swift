import Foundation

/// Lightweight append-only log at ~/Library/Application Support/ResolveEditTracker/debug.log
enum Log {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ResolveEditTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateFormat = "HH:mm:ss.SSS"
        return d
    }()

    private static let queue = DispatchQueue(label: "com.jasongrech.resolveedittracker.log")

    static func write(_ message: String) {
        let line = "[\(df.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }
}
