import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @State private var selection = Set<Session.ID>()
    @State private var editing: Session?
    @State private var showingAdd = false
    @State private var showingExport = false

    private var rows: [Session] { app.sessions.sorted { $0.start > $1.start } }

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 380)
        .sheet(isPresented: $showingAdd) {
            SessionEditSheet(mode: .add, projects: app.projectNames, currency: app.settings.currency) { result in
                app.addManualSession(project: result.project, start: result.start,
                                     minutes: result.minutes, note: result.note,
                                     page: result.page, app: result.app)
            }
        }
        .sheet(item: $editing) { session in
            SessionEditSheet(mode: .edit(session), projects: app.projectNames, currency: app.settings.currency) { result in
                var s = session
                s.app = result.app
                s.project = result.project
                s.start = result.start
                s.note = result.note
                // Only rewrite the time breakdown if the time itself was changed — editing
                // a note or project must not flatten the page / sequence splits.
                let originalPage = session.pageSeconds.max(by: { $0.value < $1.value })?.key
                let pageKey = result.app == .resolve ? result.page.rawValue : result.app.rawValue
                let timeChanged = result.minutes != (session.durationSec / 60).rounded()
                    || result.app != session.app || pageKey != originalPage
                if timeChanged {
                    s.durationSec = result.minutes * 60
                    s.pageSeconds = [pageKey: s.durationSec]
                    s.timelineSeconds = [:]
                }
                if result.project != session.project { s.rate = app.settings.rate(for: result.project) }
                app.updateSession(s)
            }
        }
        .sheet(isPresented: $showingExport) {
            TimesheetExportSheet(projects: app.projectNames) { range in
                exportTimesheet(range)
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("When") { s in
                Text(Fmt.sessionDate.string(from: s.start)).monospacedDigit()
            }.width(min: 108, ideal: 116)
            TableColumn("App") { s in
                HStack(spacing: 5) {
                    if let icon = EditorCatalog.icon(for: s.app) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(s.app.shortName).lineLimit(1)
                }
            }.width(min: 80, ideal: 100)
            TableColumn("Project") { s in
                if let top = s.timelineSeconds.max(by: { $0.value < $1.value })?.key, s.app != .resolve {
                    (Text("\(s.project)  ") + Text(top).foregroundColor(.secondary)).lineLimit(1)
                } else {
                    Text(s.project).lineLimit(1)
                }
            }
            TableColumn("Duration") { s in
                Text(Fmt.hms(s.durationSec)).monospacedDigit().foregroundStyle(.secondary)
            }.width(min: 70, ideal: 78)
            TableColumn("Earnings") { s in
                Text(Fmt.money(s.earnings, currency: s.currency)).monospacedDigit()
            }.width(min: 70, ideal: 82)
            TableColumn("Note") { s in
                Text(s.note.isEmpty && s.manual ? "manual entry" : s.note)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contextMenu(forSelectionType: Session.ID.self) { ids in
            if ids.count == 1, let s = rows.first(where: { $0.id == ids.first }) {
                Button("Edit…") { editing = s }
            }
            Button("Delete", role: .destructive) { app.deleteSessions(ids) }
        } primaryAction: { ids in
            if let s = rows.first(where: { $0.id == ids.first }) { editing = s }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { showingAdd = true } label: { Label("Add entry", systemImage: "plus") }
            Button {
                if let id = selection.first, let s = rows.first(where: { $0.id == id }) { editing = s }
            } label: { Label("Edit", systemImage: "pencil") }
                .disabled(selection.count != 1)
            Button(role: .destructive) {
                app.deleteSessions(selection); selection.removeAll()
            } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)

            Spacer()

            Text("\(rows.count) session\(rows.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            Button { exportCSV() } label: { Label("CSV", systemImage: "tablecells") }
            Button { showingExport = true } label: { Label("Timesheet…", systemImage: "doc.text") }
        }
        .padding(10)
    }

    // MARK: Exports

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "resolve-edit-tracker.csv"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? app.exportCSV().data(using: .utf8)?.write(to: url)
        }
    }

    private func exportTimesheet(_ range: ReportRange) {
        let html = Timesheet.html(sessions: app.sessions, range: range, currency: app.settings.currency)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        let name = (range.project ?? "all-projects").replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "timesheet-\(name).html"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? html.data(using: .utf8)?.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Add / edit sheet

struct SessionEditResult {
    var app: EditorApp
    var project: String
    var start: Date
    var minutes: Double
    var page: ResolvePage
    var note: String
}

struct SessionEditSheet: View {
    enum Mode { case add, edit(Session) }

    let mode: Mode
    let projects: [String]
    let currency: String
    let onSave: (SessionEditResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var start = Date()
    @State private var minutes = 30.0
    @State private var page = ResolvePage.edit
    @State private var editor = EditorApp.resolve
    @State private var note = ""

    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Edit session" : "Add a session").font(.headline)

            Form {
                Picker("App", selection: $editor) {
                    ForEach(EditorApp.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Project") {
                    HStack(spacing: 6) {
                        TextField("Project name", text: $project)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                        if !projects.isEmpty {
                            Menu {
                                ForEach(projects, id: \.self) { p in
                                    Button(p) { project = p }
                                }
                            } label: { Image(systemName: "clock.arrow.circlepath") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Pick a project you've tracked before")
                        }
                    }
                }
                DatePicker("Start", selection: $start)
                HStack {
                    Text("Duration")
                    Spacer()
                    TextField("", value: $minutes, format: .number).frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $minutes, in: 0...1440, step: 5).labelsHidden()
                    Text("minutes").foregroundStyle(.secondary)
                }
                if editor == .resolve {
                    Picker("Page", selection: $page) {
                        ForEach(ResolvePage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                TextField("Note", text: $note)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") {
                    onSave(SessionEditResult(app: editor, project: project, start: start,
                                             minutes: minutes, page: page, note: note))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            if case .edit(let s) = mode {
                editor = s.app
                project = s.project
                start = s.start
                minutes = (s.durationSec / 60).rounded()
                page = s.pageSeconds.max(by: { $0.value < $1.value }).flatMap { ResolvePage(rawValue: $0.key) } ?? .edit
                note = s.note
            } else {
                project = projects.first ?? ""
            }
        }
    }
}

// MARK: - Timesheet export sheet

struct TimesheetExportSheet: View {
    let projects: [String]
    let onExport: (ReportRange) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var project = "All projects"
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export timesheet").font(.headline)
            Form {
                Picker("Project", selection: $project) {
                    Text("All projects").tag("All projects")
                    ForEach(projects, id: \.self) { Text($0).tag($0) }
                }
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
            }
            .formStyle(.grouped)
            HStack {
                Button("Last 7 days") { from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!; to = Date() }
                Button("This month") {
                    from = Calendar.current.dateInterval(of: .month, for: Date())!.start; to = Date()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    onExport(ReportRange(project: project == "All projects" ? nil : project, from: from, to: to))
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
