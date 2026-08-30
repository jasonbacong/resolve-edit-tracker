import Foundation

struct ReportRange {
    var project: String?          // nil = all projects
    var from: Date
    var to: Date                  // inclusive day

    func contains(_ s: Session) -> Bool {
        if let project, s.project != project { return false }
        let cal = Calendar.current
        let lower = cal.startOfDay(for: from)
        let upper = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to)) ?? to
        return s.start >= lower && s.start < upper
    }
}

enum Timesheet {

    /// A self-contained, printable HTML timesheet (print → Save as PDF from the browser).
    static func html(sessions: [Session], range: ReportRange, currency: String) -> String {
        let rows = sessions.filter(range.contains).sorted { $0.start < $1.start }
        let cal = Calendar.current

        // Group by day
        var byDay: [Date: [Session]] = [:]
        for s in rows { byDay[cal.startOfDay(for: s.start), default: []].append(s) }
        let days = byDay.keys.sorted()

        let totalSec = rows.reduce(0) { $0 + $1.durationSec }
        let totalEarn = rows.reduce(0) { $0 + $1.earnings }

        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE d MMM yyyy"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let now = DateFormatter(); now.dateFormat = "d MMM yyyy, HH:mm"

        func money(_ v: Double) -> String { Fmt.money(v, currency: currency) }
        func hours(_ sec: Double) -> String { String(format: "%.2f h", sec / 3600) }

        var body = ""
        for day in days {
            let daySessions = byDay[day]!.sorted { $0.start < $1.start }
            let daySec = daySessions.reduce(0) { $0 + $1.durationSec }
            let dayEarn = daySessions.reduce(0) { $0 + $1.earnings }
            body += "<tr class='day'><td colspan='5'>\(dayFmt.string(from: day))</td></tr>"
            for s in daySessions {
                let span = "\(timeFmt.string(from: s.start))–\(timeFmt.string(from: s.end))"
                let note = s.note.isEmpty ? (s.manual ? "manual entry" : "") : escape(s.note)
                body += """
                <tr>
                  <td class='t'>\(span)</td>
                  <td>\(escape(s.project))</td>
                  <td class='r'>\(hours(s.durationSec))</td>
                  <td class='r'>\(money(s.rate))/h</td>
                  <td class='r'>\(money(s.earnings))</td>
                </tr>
                """
                if !note.isEmpty {
                    body += "<tr class='note'><td></td><td colspan='4'>\(note)</td></tr>"
                }
            }
            body += """
            <tr class='subtotal'>
              <td colspan='2'>\(dayFmt.string(from: day)) subtotal</td>
              <td class='r'>\(hours(daySec))</td><td></td>
              <td class='r'>\(money(dayEarn))</td>
            </tr>
            """
        }

        // Breakdown
        var pageAgg: [String: Double] = [:]
        var tlAgg: [String: Double] = [:]
        for s in rows {
            for (k, v) in s.pageSeconds { pageAgg[k, default: 0] += v }
            for (k, v) in s.timelineSeconds { tlAgg[k, default: 0] += v }
        }
        func breakdownList(_ dict: [String: Double], transform: (String) -> String) -> String {
            dict.filter { $0.value >= 1 }.sorted { $0.value > $1.value }
                .map { "<li>\(escape(transform($0.key))) — \(hours($0.value))</li>" }
                .joined()
        }
        let pageHTML = breakdownList(pageAgg) { ResolvePage(rawValue: $0)?.displayName ?? $0.capitalized }
        let tlHTML = breakdownList(tlAgg) { $0 == "—" ? "No timeline" : $0 }

        let title = range.project ?? "All projects"
        let periodFmt = DateFormatter(); periodFmt.dateFormat = "d MMM yyyy"
        let period = "\(periodFmt.string(from: range.from)) – \(periodFmt.string(from: range.to))"

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <title>Timesheet — \(escape(title))</title>
        <style>
          :root { color-scheme: light; }
          * { box-sizing: border-box; }
          body { font: 14px/1.5 -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1a1a1a; max-width: 820px; margin: 40px auto; padding: 0 24px; }
          h1 { font-size: 22px; margin: 0 0 2px; }
          .sub { color: #666; margin-bottom: 24px; }
          table { width: 100%; border-collapse: collapse; margin: 8px 0 28px; }
          th, td { padding: 7px 10px; border-bottom: 1px solid #e6e6e6; text-align: left; vertical-align: top; }
          th { font-size: 11px; letter-spacing: .04em; text-transform: uppercase; color: #888; border-bottom: 2px solid #ccc; }
          td.r, th.r { text-align: right; font-variant-numeric: tabular-nums; }
          td.t { color: #666; font-variant-numeric: tabular-nums; white-space: nowrap; }
          tr.day td { padding-top: 18px; font-weight: 600; border-bottom: none; }
          tr.note td { color: #888; font-size: 12px; padding-top: 0; border-bottom: 1px solid #f0f0f0; }
          tr.subtotal td { font-weight: 600; border-bottom: 2px solid #ccc; }
          .total { display: flex; justify-content: space-between; align-items: baseline; padding: 14px 10px; background: #f6f6f6; border-radius: 8px; font-size: 16px; }
          .total b { font-size: 20px; }
          .cols { display: flex; gap: 40px; margin-top: 24px; }
          .cols h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #888; }
          .cols ul { margin: 6px 0; padding-left: 18px; color: #444; }
          footer { margin-top: 36px; color: #aaa; font-size: 12px; }
          @media print { body { margin: 0; max-width: none; } .total { background: none; border: 1px solid #ccc; } }
        </style></head><body>
        <h1>\(escape(title))</h1>
        <div class="sub">Timesheet · \(period)</div>
        <table>
          <thead><tr><th>Time</th><th>Project</th><th class="r">Hours</th><th class="r">Rate</th><th class="r">Amount</th></tr></thead>
          <tbody>\(body.isEmpty ? "<tr><td colspan='5'>No sessions in this range.</td></tr>" : body)</tbody>
        </table>
        <div class="total"><span>Total — \(hours(totalSec))</span> <b>\(money(totalEarn))</b></div>
        <div class="cols">
          <div><h3>By page</h3><ul>\(pageHTML.isEmpty ? "<li>—</li>" : pageHTML)</ul></div>
          <div><h3>By timeline</h3><ul>\(tlHTML.isEmpty ? "<li>—</li>" : tlHTML)</ul></div>
        </div>
        <footer>Generated \(now.string(from: Date())) by Resolve Edit Tracker</footer>
        </body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
