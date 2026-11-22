import SwiftUI

struct ContainersView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var sortOrder = [KeyPathComparator(\DockerContainer.name)]

    enum Filter: String, CaseIterable, Identifiable {
        case all, running, stopped
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .running: String(localized: "Running")
            case .stopped: String(localized: "Stopped")
            }
        }
    }

    private var filtered: [DockerContainer] {
        store.containers
            .filter { container in
                switch filter {
                case .all: true
                case .running: container.isRunning
                case .stopped: !container.isRunning
                }
            }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.image.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var selected: DockerContainer? { store.containers.first { $0.id == selection } }

    var body: some View {
        // Combined min width (table 340 + details 380) must stay <= 730 = smallest window - widest sidebar (MainWindow).
        HSplitView {
            table
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            if let selected {
                ContainerDetailView(container: selected)
                    .id(selected.id)
                    .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search containers / images")
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear {
            if let focus = store.focusContainerID {
                selection = focus
                store.focusContainerID = nil
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { container in
                HStack(spacing: 6) {
                    if store.operations.busy.contains(container.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        StatusDot(color: container.stateColor)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(container.name)
                        if let project = container.composeProject {
                            Text(project).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 160, ideal: 200)
            TableColumn("Image", value: \.image) { Text($0.image).lineLimit(1).truncationMode(.middle) }
            TableColumn("Status", value: \.status) { container in
                HStack(spacing: 4) {
                    if let health = container.health {
                        Image(systemName: health == "healthy" ? "heart.fill" : (health == "unhealthy" ? "heart.slash.fill" : "heart"))
                            .foregroundStyle(health == "healthy" ? .green : (health == "unhealthy" ? .red : .orange))
                            .help("Health: \(health)")
                    }
                    Text(container.status).foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn("Ports") { Text($0.portsDescription).font(.caption.monospacedDigit()) }
                .width(min: 80, ideal: 140)
            TableColumn("Created", value: \.created) { Text(Format.relative($0.createdDate)).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let container = store.containers.first(where: { $0.id == id }) {
                ContainerActions(container: container)
            }
        }
    }
}

/// Container actions menu, shared by the context menu and the details toolbar.
struct ContainerActions: View {
    @Environment(AppStore.self) private var store
    let container: DockerContainer

    var body: some View {
        if container.isRunning {
            Button("Stop", systemImage: "stop.fill") { store.containersModel.perform("stop", on: container) }
                .help("Stop")
            Button("Restart", systemImage: "arrow.clockwise") { store.containersModel.perform("restart", on: container) }
                .help("Restart")
            Button("Pause", systemImage: "pause.fill") { store.containersModel.perform("pause", on: container) }
                .help("Pause")
        } else if container.isPaused {
            Button("Unpause", systemImage: "playpause.fill") { store.containersModel.perform("unpause", on: container) }
                .help("Unpause")
        } else {
            Button("Start", systemImage: "play.fill") { store.containersModel.perform("start", on: container) }
                .help("Start")
        }
        ForEach(container.publishedPorts, id: \.self) { port in
            Button("Open localhost:\(Format.digits(port))", systemImage: "safari") {
                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
            }
                .help("Open localhost:\(Format.digits(port))")
        }
        if let engine = DatabaseEngine.detect(image: container.image) {
            Button("Backup \(engine.title)…", systemImage: "cylinder.split.1x2") { backupDatabase(engine) }
                .help("Backup \(engine.title)…")
                .disabled(!container.isRunning)
            Button("Restore \(engine.title)…", systemImage: "arrow.counterclockwise.circle") { restoreDatabase(engine) }
                .help("Restore \(engine.title)…")
                .disabled(!container.isRunning)
        }
        if ElasticsearchSnapshot.detect(image: container.image) {
            Button("Snapshots…", systemImage: "camera.on.rectangle") { store.snapshotTarget = container }
                .help("Snapshots…")
                .disabled(!container.isRunning)
        }
        Divider()
        Button("Copy ID", systemImage: "doc.on.doc") { Pasteboard.copy(container.id) }
            .help("Copy ID")
        Button("Copy Name", systemImage: "textformat") { Pasteboard.copy(container.name) }
            .help("Copy Name")
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { confirmRemove() }
            .help("Remove…")
            .accessibilityIdentifier("container.remove")
    }

    private func backupDatabase(_ engine: DatabaseEngine) {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        guard let url = FilePanels.save(name: "\(container.name)-\(engine.rawValue)-\(stamp).\(engine.fileExtension)") else { return }
        store.containersModel.backupDatabase(container, engine: engine, to: url)
    }

    /// Validates the file first (manifest, dump type, complete dump), then asks the user to confirm by typing the container name.
    private func restoreDatabase(_ engine: DatabaseEngine) {
        guard let file = FilePanels.open(title: String(localized: "Choose \(engine.title) backup (.\(engine.fileExtension))")).first else { return }
        let container = container
        Task {
            let verification: BackupVerification
            do {
                verification = try await DatabaseRestore.preflight(file, engine: engine)
            } catch {
                store.operations.errorMessage = String(localized: "Restore cancelled: \(error.localizedDescription)")
                return
            }
            let effect = switch DatabaseRestore.family(engine) {
            case .redis: String(localized: "The container will be stopped, its RDB file replaced, then started again. All current keys are lost.")
            case .mysql, .postgres: String(localized: "The dump is replayed into the running server. Tables (MySQL / MariaDB) or databases (PostgreSQL) contained in the dump are dropped and recreated; anything not in the dump is kept.")
            }
            let ok = Confirm.typed(
                String(localized: "Restore into \(container.name)?"),
                message: verification.summary + "\n\n" + effect,
                expected: container.name,
                button: String(localized: "Restore")
            )
            if ok { store.containersModel.restoreDatabase(container, engine: engine, from: file) }
        }
    }

    private func confirmRemove() {
        let result = Confirm.ask(
            String(localized: "Remove container \(container.name)?"),
            message: String(localized: "The container will be stopped and permanently removed."),
            button: String(localized: "Remove"),
            checkbox: String(localized: "Also remove the container's anonymous volumes")
        )
        if result.confirmed { store.containersModel.remove(container, volumes: result.checkboxOn) }
    }
}

// MARK: - Detail

struct ContainerDetailView: View {
    @Environment(AppStore.self) private var store
    let container: DockerContainer
    @State private var tab = Self.initialTab

    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", logs = "Logs", inspect = "Inspect", exec = "Exec"
        var id: String { rawValue }
    }

    /// Logs, or the tab named by `COLIMAX_UI_TEST_DETAIL_TAB` in a UI-test launch (demo screenshots).
    private static var initialTab: Tab {
        #if COLIMAX_UI_TESTING
        if AppServices.isUITestLaunch, let raw = ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_DETAIL_TAB"],
           let tab = Tab(rawValue: raw) { return tab }
        #endif
        return .logs
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(color: container.stateColor)
                Text(container.name).font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    ContainerActions(container: container)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .help("Actions")
                .fixedSize()
            }
            .padding(10)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()

            switch tab {
            case .info: ContainerDetailsPane(container: container, client: store.docker)
            case .logs: LogsPane(container: container, client: store.docker)
            case .inspect: InspectPane(container: container, client: store.docker)
            case .exec: ExecPane(container: container, client: store.docker, socketPath: store.socketPath)
            }
        }
    }
}

private struct InspectPane: View {
    let container: DockerContainer
    let client: any DockerEngine
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTextView(text: text)
            }
        }
        .task(id: container.status) {
            do {
                text = try await client.inspectContainer(container.id)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ExecPane: View {
    let container: DockerContainer
    let client: any DockerEngine
    let socketPath: String
    @State private var command = ""
    @State private var transcript = ""
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commands run inside the container with `sh -c` (no TTY).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Terminal", systemImage: "terminal") {
                    do {
                        try TerminalLauncher.openShell(containerID: container.id, socketPath: socketPath)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                    .help("Open Terminal")
                .disabled(!container.isRunning)
            }
            .padding(10)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
            CodeTextView(text: transcript, autoScroll: true)
            Divider()
            HStack {
                Text("$").font(.system(.body, design: .monospaced))
                TextField("ls -la /", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                if running { ProgressView().controlSize(.small) }
                Button("Run", action: run)
                    .disabled(command.trimmed.isEmpty || running || !container.isRunning)
            }
            .padding(10)
        }
    }

    private func run() {
        let cmd = command.trimmed
        guard !cmd.isEmpty, !running, container.isRunning else { return }
        running = true
        command = ""
        Task {
            transcript += "$ \(cmd)\n"
            do {
                let result = try await client.exec(container.id, command: cmd, timeout: 300)
                transcript += result.output
                if !result.output.hasSuffix("\n"), !result.output.isEmpty { transcript += "\n" }
                if result.exitCode != 0 { transcript += "[exit \(result.exitCode)]\n" }
            } catch {
                transcript += String(localized: "Error: \(error.localizedDescription)") + "\n"
            }
            if transcript.utf8.count > 500_000 { transcript = String(transcript.suffix(250_000)) }
            running = false
        }
    }
}
