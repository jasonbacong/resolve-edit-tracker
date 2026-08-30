import Foundation

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Owns `sessions.json` (the log) and `current.json` (crash-recovery checkpoint).
final class SessionStore {
    let directory: URL
    private let sessionsURL: URL
    private let currentURL: URL

    private(set) var sessions: [Session] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("ResolveEditTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionsURL = directory.appendingPathComponent("sessions.json")
        currentURL = directory.appendingPathComponent("current.json")

        if let data = try? Data(contentsOf: sessionsURL),
           let arr = try? JSONDecoder.iso.decode([Session].self, from: data) {
            sessions = arr
        }
    }

    func append(_ session: Session) {
        sessions.append(session)
        persist()
    }

    func replaceAll(_ arr: [Session]) {
        sessions = arr.sorted { $0.start < $1.start }
        persist()
    }

    func delete(ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        persist()
    }

    func update(_ session: Session) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i] = session
        sessions.sort { $0.start < $1.start }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder.pretty.encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    // MARK: - In-progress checkpoint

    func saveCurrent(_ session: Session?) {
        if let session, let data = try? JSONEncoder.pretty.encode(session) {
            try? data.write(to: currentURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: currentURL)
        }
    }

    func loadCurrent() -> Session? {
        guard let data = try? Data(contentsOf: currentURL) else { return nil }
        return try? JSONDecoder.iso.decode(Session.self, from: data)
    }
}
