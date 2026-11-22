import SwiftUI

/// Recurring backup schedules (G19) for volumes and databases, with count-based retention.
struct BackupsView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    @State private var editing: BackupSchedule?
    @State private var creating = false

    private var scheduler: BackupScheduler { store.scheduler }
    private var selected: BackupSchedule? { scheduler.schedules.first { $0.id == selection } }

    var body: some View {
        Group {
            if scheduler.schedules.isEmpty {
                ContentUnavailableView {
                    Label("No backup schedules", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Schedules run while ColimaX is open. A run missed while the app was closed starts at the next check after launch.")
                } actions: {
                    Button("New Schedule…") { creating = true }.buttonStyle(.borderedProminent)
                }
            } else {
                table
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("New", systemImage: "plus") { creating = true }
                    .help("New")
                Button("Run Now", systemImage: "play.fill") { if let selection { scheduler.runNow(selection) } }
                    .help("Run Now")
                    .disabled(selected == nil || scheduler.runningID != nil)
                Button("Edit", systemImage: "pencil") { editing = selected }
                    .help("Edit")
                    .disabled(selected == nil)
                Button("Delete", systemImage: "trash") { if let selected { confirmDelete(selected) } }
                    .help("Delete")
                    .disabled(selected == nil)
            }
        }
        .sheet(isPresented: $creating) {
            ScheduleEditor(schedule: nil) { scheduler.add($0) }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule) { scheduler.update($0) }
        }
    }

    private var table: some View {
        Table(scheduler.schedules, selection: $selection) {
            TableColumn("On") { schedule in
                Toggle("", isOn: Binding(
                    get: { schedule.enabled },
                    set: { value in
                        var copy = schedule
                        copy.enabled = value
                        scheduler.update(copy)
                    }
                ))
                .labelsHidden()
            }
            .width(34)
            TableColumn("Target") { schedule in
                HStack(spacing: 6) {
                    if scheduler.runningID == schedule.id { ProgressView().controlSize(.mini) }
                    Text(schedule.target.title)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Profile") { Text($0.profile).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("Every") { Text($0.interval.title) }
                .width(min: 80, ideal: 100)
            TableColumn("Keep") { Text("\($0.keep)").monospacedDigit() }
                .width(40)
            TableColumn("Last run") { schedule in
                if let error = schedule.lastError {
                    Label(schedule.lastRun.map(Format.relative) ?? "—", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                } else {
                    Text(schedule.lastSuccess.map(Format.relative) ?? String(localized: "Never")).foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Next") { schedule in
                Text(schedule.enabled ? Format.relative(schedule.nextRun(after: .now)) : String(localized: "Off")).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Folder") { schedule in
                Text(schedule.directory).lineLimit(1).truncationMode(.head).help(schedule.directory)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let schedule = scheduler.schedules.first(where: { $0.id == id }) {
                Button("Run Now") { scheduler.runNow(id) }.disabled(scheduler.runningID != nil)
                Button("Edit…") { editing = schedule }
                Button("Show in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: schedule.directory, isDirectory: true))
                }
                if let error = schedule.lastError {
                    Button("Copy Last Error") { Pasteboard.copy(error) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete(schedule) }
            }
        }
    }

    private func confirmDelete(_ schedule: BackupSchedule) {
        let ok = Confirm.destructive(
            String(localized: "Delete schedule for \(schedule.target.title)?"),
            message: String(localized: "Existing backup files in \(schedule.directory) are kept."),
            button: String(localized: "Delete")
        )
        if ok { scheduler.remove(schedule.id) }
    }
}

private struct ScheduleEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let schedule: BackupSchedule?
    let onSave: (BackupSchedule) -> Void

    enum Kind: String, CaseIterable, Identifiable { case volume = "Volume", database = "Database"
        var id: String { rawValue }
        var title: String { self == .volume ? String(localized: "Volume") : String(localized: "Database") }
    }

    @State private var kind = Kind.volume
    @State private var volume = ""
    @State private var container = ""
    @State private var interval = BackupSchedule.Interval.daily
    @State private var keep = 7
    @State private var directory = ""

    private var databaseContainers: [DockerContainer] {
        store.containers.filter { DatabaseEngine.detect(image: $0.image) != nil }.sorted { $0.name < $1.name }
    }

    private var draft: BackupSchedule? {
        let target: BackupSchedule.Target
        switch kind {
        case .volume:
            guard !volume.isEmpty else { return nil }
            target = .volume(name: volume)
        case .database:
            guard let match = databaseContainers.first(where: { $0.name == container }),
                  let engine = DatabaseEngine.detect(image: match.image) else { return nil }
            target = .database(container: container, engine: engine.rawValue)
        }
        var result = schedule ?? BackupSchedule(profile: store.selectedProfileName, target: target, interval: interval, directory: directory, keep: keep)
        result.target = target
        result.interval = interval
        result.directory = directory
        result.keep = keep
        return result.isValid ? result : nil
    }

    var body: some View {
        Form {
            Picker("Back up", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch kind {
            case .volume:
                Picker("Volume", selection: $volume) {
                    Text("Choose…").tag("")
                    ForEach(store.volumes.filter { !$0.isAnonymous }) { Text($0.name).tag($0.name) }
                }
            case .database:
                Picker("Container", selection: $container) {
                    Text("Choose…").tag("")
                    ForEach(databaseContainers) { item in
                        Text("\(item.name) (\(DatabaseEngine.detect(image: item.image)?.title ?? ""))").tag(item.name)
                    }
                }
                Text("The container is matched by name, so it keeps working after compose recreates it. It must be running at backup time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Every", selection: $interval) {
                ForEach(BackupSchedule.Interval.allCases) { Text($0.title).tag($0) }
            }
            PlusMinusStepper(value: $keep, in: BackupSchedule.minKeep...BackupSchedule.maxKeep) {
                Text("Keep last \(keep) backups")
            }
            LabeledContent("Folder") {
                HStack {
                    Text(directory.isEmpty ? String(localized: "Not set") : directory).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(directory.isEmpty ? .secondary : .primary)
                    Button("Choose…") {
                        if let url = FilePanels.open(title: String(localized: "Backup folder"), directories: true).first { directory = url.path }
                    }
                }
            }
            Text("Only files created by this schedule (matching name pattern and manifest) are deleted by retention.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Profile: \(schedule?.profile ?? store.selectedProfileName)").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle(schedule == nil ? "New Backup Schedule" : "Edit Backup Schedule")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let draft { onSave(draft); dismiss() }
                }
                .disabled(draft == nil)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let schedule else { return }
        switch schedule.target {
        case .volume(let name): kind = .volume; volume = name
        case .database(let name, _): kind = .database; container = name
        }
        interval = schedule.interval
        keep = schedule.keep
        directory = schedule.directory
    }
}
