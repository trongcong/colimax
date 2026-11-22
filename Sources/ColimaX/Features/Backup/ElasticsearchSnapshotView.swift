import SwiftUI

/// Manages Elasticsearch / OpenSearch snapshots for a container (G25).
struct ElasticsearchSnapshotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let container: DockerContainer

    @State private var location: String?
    @State private var snapshots: [ElasticsearchSnapshot.Snapshot] = []
    @State private var selection: String?
    @State private var error: String?
    @State private var busy: String?
    @State private var newName = ElasticsearchSnapshot.defaultName()

    private var client: any DockerEngine { store.docker }
    private var selected: ElasticsearchSnapshot.Snapshot? { snapshots.first { $0.name == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Elasticsearch Snapshots").font(.headline)
                    Text(location.map { String(localized: "\(container.name) · repository “\(ElasticsearchSnapshot.repository)” at \($0)") } ?? container.name)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let error {
                Banner(kind: .error, message: error) { self.error = nil }.padding(12)
            }
            HStack {
                TextField("Snapshot name", text: $newName).frame(width: 260)
                Button("Create Snapshot") { create() }
                    .disabled(location == nil || busy != nil || !ElasticsearchSnapshot.isValidName(newName))
                Spacer()
                Button("Restore…") { if let selected { restore(selected) } }
                    .disabled(selected == nil || busy != nil)
                Button("Delete…") { if let selected { delete(selected) } }
                    .disabled(selected == nil || busy != nil)
                Button("Export Repository…") { export() }
                    .disabled(location == nil || busy != nil)
                    .help("Download the whole snapshot repository from the container as .tar with a SHA-256 manifest")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Table(snapshots, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("State") { Text($0.state).foregroundStyle($0.state == "SUCCESS" ? .green : .orange) }
                    .width(90)
                TableColumn("Indices") { Text(ElasticsearchSnapshot.userIndices($0.indices).joined(separator: ", ")).lineLimit(1) }
                TableColumn("Started") { Text($0.start.map(Format.relative) ?? "—").foregroundStyle(.secondary) }
                    .width(110)
            }
        }
        .frame(minWidth: 820, idealWidth: 860, maxWidth: .infinity, minHeight: 480, idealHeight: 540, maxHeight: .infinity)
        .task { await reload(prepare: true) }
    }

    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        busy = label
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    private func reload(prepare: Bool) async {
        busy = String(localized: "Loading…")
        do {
            if prepare { location = try await ElasticsearchSnapshot.ensureRepository(container: container.id, client: client) }
            snapshots = try await ElasticsearchSnapshot.list(container: container.id, client: client)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        busy = nil
    }

    private func create() {
        let name = newName
        run(String(localized: "Creating \(name)…")) {
            try await ElasticsearchSnapshot.create(name, container: container.id, client: client)
            newName = ElasticsearchSnapshot.defaultName()
            await reload(prepare: false)
            store.flash(String(localized: "Snapshot \(name) created"))
        }
    }

    private func restore(_ snapshot: ElasticsearchSnapshot.Snapshot) {
        let indices = ElasticsearchSnapshot.userIndices(snapshot.indices)
        let result = Confirm.ask(
            String(localized: "Restore snapshot \(snapshot.name)?"),
            message: String(localized: "Indices: \(indices.joined(separator: ", "))\n\nBy default indices are restored as new copies named restored-<index>; existing data is not touched."),
            button: String(localized: "Restore as Copies"),
            checkbox: String(localized: "Replace existing indices instead (deletes them first)"),
            destructive: false
        )
        guard result.confirmed else { return }
        var mode = ElasticsearchSnapshot.RestoreMode.renamed
        if result.checkboxOn {
            guard Confirm.typed(String(localized: "Replace \(indices.count) indices in \(container.name)?"),
                                message: String(localized: "These indices are deleted, then restored from \(snapshot.name): \(indices.joined(separator: ", "))"),
                                expected: container.name, button: String(localized: "Replace")) else { return }
            mode = .replace
        }
        run(String(localized: "Restoring \(snapshot.name)…")) {
            try await ElasticsearchSnapshot.restore(snapshot, mode: mode, container: container.id, client: client)
            store.flash(mode == .renamed ? String(localized: "Snapshot \(snapshot.name) restored as restored-* indices") : String(localized: "Snapshot \(snapshot.name) restored"))
        }
    }

    private func delete(_ snapshot: ElasticsearchSnapshot.Snapshot) {
        guard Confirm.destructive(String(localized: "Delete snapshot \(snapshot.name)?"), message: String(localized: "The snapshot is removed from the repository. Indices are not affected."), button: String(localized: "Delete")) else { return }
        run(String(localized: "Deleting \(snapshot.name)…")) {
            try await ElasticsearchSnapshot.delete(snapshot.name, container: container.id, client: client)
            await reload(prepare: false)
        }
    }

    private func export() {
        guard let location, let url = FilePanels.save(name: "\(container.name)-es-repo-\(BackupSchedule.stamp(.now)).tar") else { return }
        run(String(localized: "Exporting…")) {
            let manifest = try await ElasticsearchSnapshot.export(location: location, container: container, to: url, client: client)
            store.flash(String(localized: "Exported repository → \(url.lastPathComponent) (\(Format.bytes(manifest.size)))"))
        }
    }
}
