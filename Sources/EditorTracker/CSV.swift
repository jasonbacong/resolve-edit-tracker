import Foundation

enum CSVIO {
    // MARK: Export  — columns match the original Resolve script: Date, Duration, Earnings, Note

    static func export(_ sessions: [Session]) -> String {
        var rows = ["Date,Duration,Earnings,Note"]
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let cells = [
                Fmt.sessionDate.string(from: s.start),
                Fmt.hms(s.durationSec),
                Fmt.money(s.earnings, currency: s.currency),
                s.note
            ]
            rows.append(cells.map(field).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: Import — best-effort; pageSeconds are unknown for imported rows

    static func `import`(_ text: String, defaultCurrency: String) -> [Session] {
        var out: [Session] = []
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            if i == 0 && line.lowercased().hasPrefix("date,") { continue }
            let cols = parseRow(line)
            guard cols.count >= 3, let start = Fmt.sessionDate.date(from: cols[0]) else { continue }
            let dur = parseHMS(cols[1])
            let earn = parseMoney(cols[2])
            let note = cols.count >= 4 ? cols[3] : ""
            let rate = dur > 0 ? earn / (dur / 3600.0) : 0
            out.append(Session(
                project: "Imported",
                start: start,
                end: start.addingTimeInterval(dur),
                durationSec: dur,
                rate: rate,
                currency: defaultCurrency,
                note: note,
                pageSeconds: [:]
            ))
        }
        return out
    }

    // MARK: Helpers

    private static func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func parseRow(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { current.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { current.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { result.append(current); current = "" }
                else { current.append(c) }
            }
            i += 1
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseHMS(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func parseMoney(_ s: String) -> Double {
        let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned) ?? 0
    }
}
