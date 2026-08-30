import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openHistory) private var openHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let warning = connectionWarning {
                warningBanner(warning)
            }
            Divider()
            totals
            if !app.stats.breakdown.isEmpty {
                Divider()
                breakdown
            }
            Divider()
            noteField
            controls
        }
        .padding(14)
        .frame(width: 308)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: app.menuBarSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(app.state == .tracking ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.status.project ?? app.stats.project ?? "Resolve Edit Tracker")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(app.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(app.state == .tracking ? Fmt.hms(app.elapsed) : "0:00:00")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(app.state == .tracking ? .primary : .secondary)
        }
    }

    // MARK: Connection warning

    private var connectionWarning: String? {
        switch app.connection {
        case .connected, .resolveNotRunning: return nil
        case .apiUnavailable(let r), .probeUnavailable(let r): return r
        }
    }

    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Totals

    private var totals: some View {
        VStack(spacing: 6) {
            row("Today", Fmt.hms(app.stats.todaySec))
            row("This week", Fmt.hms(app.stats.weekSec))
            row("Project total", Fmt.hms(app.stats.projectTotalSec))
            row("Earnings", Fmt.money(app.stats.projectEarnings, currency: app.settings.currency))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("WHERE YOUR TIME GOES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            let maxSec = app.stats.breakdown.map(\.seconds).max() ?? 1
            ForEach(app.stats.breakdown.prefix(6)) { item in
                HStack(spacing: 8) {
                    Text(ResolvePage(rawValue: item.page)?.displayName ?? item.page.capitalized)
                        .font(.system(size: 11))
                        .frame(width: 62, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(Color.green)
                                .frame(width: max(3, geo.size.width * item.seconds / maxSec))
                        }
                    }
                    .frame(height: 7)
                    Text(Fmt.hms(item.seconds))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Note + controls

    private var noteField: some View {
        TextField("Session note (saved when the timer stops)", text: $app.noteDraft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .font(.system(size: 11))
            .disabled(app.state == .notInProject)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Button {
                app.togglePause()
            } label: {
                Label(pauseLabel, systemImage: app.state == .tracking ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(app.state == .notInProject && !app.status.hasProject)

            HStack(spacing: 6) {
                Button { openHistory() } label: {
                    Label("History", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
                }
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.regular)

            Button(role: .destructive) {
                AppState.shared?.flushForQuit()
                NSApp.terminate(nil)
            } label: {
                Text("Quit Resolve Edit Tracker").frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
        .buttonStyle(.bordered)
    }

    private var pauseLabel: String {
        switch app.state {
        case .tracking:       return "Pause"
        case .idlePaused,
             .manuallyPaused: return "Resume"
        case .notInProject:   return "Not tracking"
        }
    }
}
