import Foundation

enum Fmt {
    /// "1:23:45" — hours are not zero-padded, matching the original script.
    static func hms(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    /// "2h 05m" / "45m" — compact, for per-app chips.
    static func hm(_ seconds: Double) -> String {
        let total = Int(seconds.rounded()) / 60
        let h = total / 60, m = total % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    static func money(_ amount: Double, currency: String) -> String {
        let symbolFirst = !(currency.count > 1 && currency.first!.isLetter)
        let value = String(format: "%.2f", amount)
        return symbolFirst ? "\(currency)\(value)" : "\(value) \(currency)"
    }

    static let sessionDate: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()
}

/// Builds the derived `Stats` for the menu-bar panel.
enum StatsBuilder {
    /// Totals are across every app. The project figures and breakdown cover one document
    /// in one app — Resolve splits by page; Premiere / After Effects by sequence / comp.
    static func build(sessions: [Session],
                      current: Session?,
                      project: String?,
                      app: EditorApp = .resolve,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Stats {
        var all = sessions
        if let current { all.append(current) }

        let startOfDay = calendar.startOfDay(for: now)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)

        var stats = Stats(project: project)
        stats.breakdownIsPages = app == .resolve
        var buckets: [String: Double] = [:]
        var todayApps: [EditorApp: Double] = [:]

        for s in all {
            if s.start >= startOfDay {
                stats.todaySec += s.durationSec
                todayApps[s.app, default: 0] += s.durationSec
            }
            if let w = weekInterval, w.contains(s.start) {
                stats.weekSec += s.durationSec
            }
            if let project, s.project == project, s.app == app {
                stats.projectTotalSec += s.durationSec
                stats.projectEarnings += s.earnings
                let source = app == .resolve ? s.pageSeconds : s.timelineSeconds
                for (key, sec) in source {
                    buckets[key, default: 0] += sec
                }
            }
        }

        stats.breakdown = buckets
            .filter { $0.value >= 1 }
            .map { Stats.PageStat(page: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        stats.todayByApp = todayApps
            .filter { $0.value >= 60 }
            .map { Stats.AppStat(app: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        return stats
    }
}
