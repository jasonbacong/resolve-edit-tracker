import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var importResult: String?
    @State private var confirmClear = false

    private var defaultRateHint: String {
        Fmt.money(app.settings.rate, currency: app.settings.currency)
    }

    var body: some View {
        Form {
            Section("Billing") {
                LabeledContent("Default rate") {
                    HStack(spacing: 6) {
                        TextField("Currency", text: $app.settings.currency)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 46).multilineTextAlignment(.center)
                        TextField("Rate", value: $app.settings.rate,
                                  format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 88).multilineTextAlignment(.trailing)
                        Text("per hour").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if app.projectNames.isEmpty {
                    Text("Projects will appear here once you've tracked time on them. Each one bills at the default rate unless you set an override.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(app.projectNames, id: \.self) { project in
                        HStack {
                            Text(project).lineLimit(1)
                            Spacer(minLength: 8)
                            TextField(defaultRateHint, text: rateBinding(for: project))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .frame(width: 76).multilineTextAlignment(.trailing)
                            if app.settings.projectRates[project] != nil {
                                Button {
                                    app.settings.projectRates.removeValue(forKey: project)
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                                    .help("Use the default rate")
                            }
                        }
                    }
                }
            } header: {
                Text("Per-project rates")
            } footer: {
                Text("Leave blank to use the default rate. Changing a rate here does not alter time already recorded.")
                    .font(.caption)
            }

            Section("Tracking") {
                LabeledContent("Idle stop") {
                    HStack(spacing: 6) {
                        TextField("Minutes", value: $app.settings.idleMinutes, format: .number)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(width: 52).multilineTextAlignment(.trailing)
                        Stepper("Idle stop", value: $app.settings.idleMinutes, in: 0...240)
                            .labelsHidden()
                        Text("minutes").foregroundStyle(.secondary)
                    }
                }
                Text("Pause after this many minutes with no keyboard or mouse activity anywhere. 0 disables it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep tracking while Resolve is rendering", isOn: $app.settings.pauseDuringRenders)
            }

            Section("Notifications") {
                Toggle("Play a sound when tracking starts", isOn: $app.settings.playSoundOnStart)
                LabeledContent("Sound") {
                    HStack(spacing: 8) {
                        Picker("Sound", selection: $app.settings.soundName) {
                            ForEach(Settings.availableSounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        Button("Preview") { ToastController.playPing(named: app.settings.soundName) }
                    }
                    .disabled(!app.settings.playSoundOnStart)
                }
                Toggle("Show a toast when resuming from idle", isOn: $app.settings.toastOnIdleResume)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $app.settings.launchAtLogin)
                Toggle("Show elapsed time in the menu bar", isOn: $app.settings.menuBarShowTime)

                LabeledContent("History") {
                    HStack(spacing: 8) {
                        Button("Import CSV…") { importCSV() }
                        Button("Clear all…", role: .destructive) { confirmClear = true }
                    }
                }
                if let importResult {
                    Text(importResult).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Data folder") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.storeDirectory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 640,
               minHeight: 360, idealHeight: 640, maxHeight: .infinity)
        .confirmationDialog("Delete every recorded session? This cannot be undone.",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all history", role: .destructive) { app.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func rateBinding(for project: String) -> Binding<String> {
        Binding(
            get: {
                if let r = app.settings.projectRates[project] {
                    return r == r.rounded() ? String(Int(r)) : String(r)
                }
                return ""
            },
            set: { str in
                let t = str.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    app.settings.projectRates.removeValue(forKey: project)
                } else if let v = Double(t) {
                    app.settings.projectRates[project] = v
                }
            }
        )
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let n = app.importSessions(from: text)
        importResult = n > 0 ? "Imported \(n) session\(n == 1 ? "" : "s")" : "Nothing imported"
    }
}
