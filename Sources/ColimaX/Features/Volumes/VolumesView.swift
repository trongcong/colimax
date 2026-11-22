import SwiftUI

struct VolumesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\DockerVolume.name)]
    @State private var showCreate = false
    @State private var inspecting: DockerVolume?
    @State private var restoreFile: URL?

    private func users(_ volume: DockerVolume) -> [DockerContainer] {
        store.containers.filter { $0.volumeNames.contains(volume.name) }
    }

    private var filtered: [DockerVolume] {
        store.volumes
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var selected: DockerVolume? { store.volumes.first { $0.name == selection } }

    var body: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { volume in
                HStack(spacing: 6) {
                    if store.operations.busy.contains(volume.name) { ProgressView().controlSize(.mini) }
                    Text(volume.isAnonymous ? String(volume.name.prefix(12)) + "…" : volume.name)
                        .foregroundStyle(volume.isAnonymous ? .secondary : .primary)
                        .help(volume.name)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Project") { Text($0.composeProject ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)
            TableColumn("Size") { volume in
                Text(store.volumeUsage[volume.name].map { $0.size >= 0 ? Format.bytes($0.size) : "—" } ?? "…")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            TableColumn("Used By") { volume in
                let names = users(volume).map(\.name)
                Text(names.isEmpty ? "—" : names.joined(separator: ", ")).lineLimit(1)
            }
            TableColumn("Created") { Text(Format.relative(iso: $0.createdAt)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let volume = store.volumes.first(where: { $0.name == id }) {
                Button("Inspect") { inspecting = volume }
                Button("Backup…") { backup(volume) }
                Button("Restore into This Volume…") { restore(into: volume) }
                Button("Copy Name") { Pasteboard.copy(volume.name) }
                Divider()
                Button("Delete…", role: .destructive) { confirmRemove(volume) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search volumes")
        .toolbar {
            ToolbarItemGroup {
                Button("Create", systemImage: "plus") { showCreate = true }
                    .help("Create")
                Button("Inspect", systemImage: "info.circle") { inspecting = selected }
                    .help("Inspect")
                    .disabled(selected == nil)
                Button("Backup", systemImage: "square.and.arrow.down") { if let selected { backup(selected) } }
                    .help("Backup")
                    .disabled(selected == nil)
                Button("Restore", systemImage: "square.and.arrow.up") { restoreFromFile() }
                    .help("Restore")
                Button("Verify Backup", systemImage: "checkmark.shield") { verifyFile() }
                    .help("Check a backup file against its SHA-256 manifest")
                Button("Delete", systemImage: "trash") { if let selected { confirmRemove(selected) } }
                    .help("Delete")
                    .disabled(selected == nil)
                Button("Prune", systemImage: "sparkles") { confirmPrune() }
                    .help("Prune")
                    .accessibilityIdentifier("volumes.prune")
                    .disabled(store.operations.busy.contains("prune:volumes"))
            }
        }
        .task { await store.refreshOverview() }
        .sheet(isPresented: $showCreate) {
            NameSheet(title: String(localized: "Create Volume"), placeholder: "my-data", action: String(localized: "Create")) { store.volumesModel.create($0) }
        }
        .sheet(item: $restoreFile) { file in
            NameSheet(title: String(localized: "Restore \(file.lastPathComponent) into Volume"), placeholder: String(localized: "volume name (created if it does not exist)"), action: String(localized: "Restore")) { name in
                confirmRestore(file: file, into: name)
            }
        }
        .sheet(item: $inspecting) { volume in
            InspectSheet(title: volume.name) { try await store.docker.inspectVolume(volume.name) }
        }
    }

    private func backup(_ volume: DockerVolume) {
        let stamp = Date().formatted(.iso8601.year().month().day())
        guard let url = FilePanels.save(name: "\(volume.name)-\(stamp).tar") else { return }
        store.volumesModel.backup(volume, to: url)
    }

    private func restore(into volume: DockerVolume) {
        guard let file = FilePanels.open(title: String(localized: "Choose a backup file (.tar)")).first else { return }
        confirmRestore(file: file, into: volume.name)
    }

    private func restoreFromFile() {
        guard let file = FilePanels.open(title: String(localized: "Choose a backup file (.tar)")).first else { return }
        restoreFile = file
    }

    private func verifyFile() {
        guard let file = FilePanels.open(title: String(localized: "Choose a backup file to verify")).first else { return }
        store.volumesModel.verifyBackup(file)
    }

    /// Verifies integrity **before** asking for confirmation, so the user can see whether the file matches its manifest.
    private func confirmRestore(file: URL, into name: String) {
        Task {
            let verification: BackupVerification
            do {
                verification = try await BackupVerifier.verify(file)
                try TarInspector.validateVolumeArchive(file)
            } catch {
                store.operations.errorMessage = String(localized: "Cannot restore: \(error.localizedDescription)")
                return
            }
            let exists = store.volumes.contains { $0.name == name }
            let users = store.containers.filter { $0.isRunning && $0.volumeNames.contains(name) }.map(\.name)
            var message = verification.summary + "\n\n"
            message += exists
                ? String(localized: "Files with the same name in the volume will be overwritten (other files are kept).")
                : String(localized: "A new volume will be created.")
            if !users.isEmpty { message += "\n\n" + String(localized: "In use by running containers: \(users.joined(separator: ", ")). Stop them first to avoid inconsistent data.") }
            let ok = Confirm.destructive(String(localized: "Restore into volume \(name)?"), message: message, button: String(localized: "Restore"))
            if ok { store.volumesModel.restore(name, from: file) }
        }
    }

    private func confirmRemove(_ volume: DockerVolume) {
        let using = users(volume)
        guard using.isEmpty else {
            store.operations.errorMessage = String(localized: "Volume is in use by: \(using.map(\.name).joined(separator: ", ")). Remove those containers first.")
            return
        }
        let ok = Confirm.destructive(
            String(localized: "Delete volume \(volume.name)?"),
            message: String(localized: "All data in the volume will be permanently lost. Back it up first if needed.")
        )
        if ok { store.volumesModel.remove(volume) }
    }

    private func confirmPrune() {
        let result = Confirm.ask(
            String(localized: "Prune unused volumes?"),
            message: String(localized: "Deletes volumes not attached to any container. The data will be permanently lost."),
            button: String(localized: "Prune"),
            checkbox: String(localized: "Also delete named volumes (by default only anonymous volumes)")
        )
        if result.confirmed { store.volumesModel.prune(all: result.checkboxOn) }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Sheet for entering a validated name (volume, network, ...).
struct NameSheet: View {
    let title: String
    let placeholder: String
    let action: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var isValid: Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text(placeholder))
                .onSubmit(submit)
            if !name.isEmpty, !isValid {
                Text("Use only letters, digits, '.', '-' and '_'").font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(action, action: submit).disabled(!isValid) }
        }
    }

    private func submit() {
        guard isValid else { return }
        dismiss()
        onSubmit(name)
    }
}
