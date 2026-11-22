import SwiftUI

struct ComposeView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var adding: ComposeProject?

    private var selected: ComposeProject? { store.composeModel.projects.first { $0.name == selection } }

    var body: some View {
        HSplitView {
            List(store.composeModel.projects, selection: $selection) { project in
                let items = store.composeModel.containers(in: project.name)
                let running = items.filter(\.isRunning).count
                HStack {
                    StatusDot(color: items.isEmpty ? .gray : (running == items.count ? .green : (running > 0 ? .orange : .gray)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                        Text(items.isEmpty ? "not running" : "\(running)/\(items.count) running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(project.name)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            .overlay {
                if store.composeModel.projects.isEmpty {
                    ContentUnavailableView("No Compose projects", systemImage: "square.stack.3d.up",
                                           description: Text("Projects started with docker compose appear here automatically."))
                }
            }

            Group {
                if let selected {
                    ComposeProjectDetail(project: selected)
                } else {
                    ContentUnavailableView("Select a project", systemImage: "square.stack.3d.up")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("From Folder (find compose files automatically)…") { pickDirectory() }
                    Button("Choose Compose Files…") { pickComposeFile() }
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add Project")
                .disabled(!ComposeService.isAvailable)
            }
        }
        .safeAreaInset(edge: .top) {
            if !ComposeService.isAvailable {
                Banner(kind: .error, message: String(localized: "docker CLI not found. Install it with: brew install docker docker-compose"))
                    .padding(12)
            }
        }
        .sheet(item: $adding) { project in
            AddComposeSheet(project: project)
        }
    }

    private func pickDirectory() {
        guard let directory = FilePanels.open(title: String(localized: "Choose the folder containing compose.yaml"), directories: true).first else { return }
        guard let found = ComposeDiscovery.scan(directory) else {
            store.operations.errorMessage = String(localized: "No compose.yaml / docker-compose.yml found in \(directory.lastPathComponent)")
            return
        }
        adding = ComposeProject(
            name: ComposeProject.defaultName(for: directory),
            workingDir: directory.path,
            configFiles: found.files.map(\.path)
        )
    }

    private func pickComposeFile() {
        let urls = FilePanels.open(title: String(localized: "Choose compose files (multiple allowed)"), multiple: true)
        guard let first = urls.first else { return }
        let directory = first.deletingLastPathComponent()
        adding = ComposeProject(
            name: ComposeProject.defaultName(for: directory),
            workingDir: directory.path,
            configFiles: urls.map(\.path)
        )
    }
}

private struct AddComposeSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var project: ComposeProject
    @State private var name = ""
    @State private var runUp = false

    var body: some View {
        Form {
            TextField("Project name", text: $name)
            if !name.isEmpty, !ComposeProject.isValidName(name) {
                Text("Use only lowercase letters, digits, '-' and '_'").font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Folder", value: project.workingDir ?? "—")
            LabeledContent("File") {
                VStack(alignment: .trailing) {
                    ForEach(project.configFiles, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent) }
                }
            }
            if let dir = project.workingDir, FileManager.default.fileExists(atPath: dir + "/.env") {
                LabeledContent("Env file", value: String(localized: ".env (loaded automatically by Compose)"))
            }
            Toggle("Run `up -d` now", isOn: $runUp)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { name = project.name }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let final = ComposeProject(name: name, workingDir: project.workingDir, configFiles: project.configFiles)
                    store.composeModel.add(final)
                    if runUp { store.composeModel.run(.up, final) }
                    dismiss()
                }
                .disabled(!ComposeProject.isValidName(name))
            }
        }
    }
}

private struct ComposeProjectDetail: View {
    @Environment(AppStore.self) private var store
    let project: ComposeProject
    @State private var showingLogs = false
    @State private var showingConfig = false
    @State private var validating = false

    private var missingFiles: [String] { ComposeService.missingFiles(project) }
    private var hasEnvFile: Bool { project.workingDir.map { FileManager.default.fileExists(atPath: $0 + "/.env") } ?? false }

    private var items: [DockerContainer] { store.composeModel.containers(in: project.name) }
    private var isSaved: Bool { store.composeModel.savedProjects.contains { $0.name == project.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(project.name).font(.title2.weight(.semibold))
                if let dir = project.workingDir {
                    HStack {
                        Text(dir).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir) } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
                if !project.configFiles.isEmpty {
                    Text(project.configFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                         + (hasEnvFile ? " · .env" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !missingFiles.isEmpty {
                    Label("No longer found: \(missingFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    Button("Up", systemImage: "arrow.up.circle") { store.composeModel.run(.up, project) }
                        .disabled(!project.canRunUp)
                        .help(project.canRunUp ? "docker compose up -d" : "The compose files for this project are unknown")
                    Button("Start", systemImage: "play.fill") { store.composeModel.run(.start, project) }
                        .help("Start")
                    Button("Stop", systemImage: "stop.fill") { store.composeModel.run(.stop, project) }
                        .help("Stop")
                    Button("Restart", systemImage: "arrow.clockwise") { store.composeModel.run(.restart, project) }
                        .help("Restart")
                    Button("Pull", systemImage: "arrow.down.circle") { store.composeModel.run(.pull, project) }
                        .help("Pull")
                        .disabled(!project.canRunUp)
                    Spacer()
                    Button("Logs", systemImage: "text.alignleft") { showingLogs = true }
                        .help("Logs")
                    Menu {
                        Button("Validate Configuration (config --quiet)") { validate() }
                            .disabled(!project.canRunUp || validating)
                        Button("Show Merged Configuration") { showingConfig = true }
                            .disabled(!project.canRunUp)
                        Divider()
                        Button("Down (remove containers + networks)…", role: .destructive) { confirmDown() }
                        if isSaved {
                            Button("Remove from List") { store.composeModel.forget(project.name) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .fixedSize()
                    .accessibilityIdentifier("compose.more")
                }
                .disabled(store.operations.isOperationRunning || !ComposeService.isAvailable)
            }
            .padding(16)
            Divider()

            if items.isEmpty {
                ContentUnavailableView("No containers", systemImage: "shippingbox",
                                       description: Text("Click Up to start the project."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(items) {
                    TableColumn("Service") { container in
                        HStack(spacing: 6) {
                            StatusDot(color: container.stateColor)
                            Text(container.composeService ?? container.name)
                        }
                    }
                    TableColumn("Image") { Text($0.image).lineLimit(1) }
                    TableColumn("Status") { Text($0.status).foregroundStyle(.secondary) }
                    TableColumn("Ports") { Text($0.portsDescription).font(.caption.monospacedDigit()) }
                    TableColumn("") { container in
                        Button("View") {
                            store.focusContainerID = container.id
                            store.screen = .containers
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(50)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let container = items.first(where: { $0.id == id }) {
                        if let service = container.composeService, ComposeService.isValidServiceName(service) {
                            Section("Service \(service)") {
                                Button("Restart service") { store.composeModel.run(.restart, service: service, project) }
                                Button(container.isRunning ? "Stop service" : "Start service") {
                                    store.composeModel.run(container.isRunning ? .stop : .start, service: service, project)
                                }
                                Button("Rebuild & Recreate Service…") { confirmRebuild(service) }
                                    .disabled(!project.canRunUp)
                            }
                            .disabled(store.operations.isOperationRunning || !ComposeService.isAvailable)
                        }
                        ContainerActions(container: container)
                    }
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            ComposeLogsSheet(project: project, socketPath: store.socketPath)
        }
        .sheet(isPresented: $showingConfig) {
            InspectSheet(title: String(localized: "docker compose config — \(project.name)")) {
                try await ComposeService.config(project: project, socketPath: store.socketPath)
            }
        }
    }

    private func validate() {
        validating = true
        let socket = store.socketPath
        Task {
            defer { validating = false }
            do {
                if let problem = try await ComposeService.validate(project: project, socketPath: socket) {
                    store.operations.errorMessage = String(localized: "Compose \(project.name): \(problem)")
                } else {
                    store.flash(String(localized: "Compose configuration for \(project.name) is valid"))
                }
            } catch {
                store.operations.errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmRebuild(_ service: String) {
        let ok = Confirm.ask(
            String(localized: "Rebuild service \(service)?"),
            message: String(localized: "Runs `docker compose up -d --build --no-deps --force-recreate \(service)`: rebuilds the image and recreates this service's container. Data inside the container (outside volumes) will be lost."),
            button: String(localized: "Rebuild"),
            destructive: true
        ).confirmed
        if ok { store.composeModel.run(.rebuild, service: service, project) }
    }

    private func confirmDown() {
        let ok = Confirm.destructive(
            String(localized: "docker compose down \(project.name)?"),
            message: String(localized: "Stops and removes all of the project's containers and networks. Named volumes are kept."),
            button: String(localized: "Down")
        )
        if ok { store.composeModel.run(.down, project) }
    }
}

/// `docker compose logs -f` for the whole project or one service. Closing the sheet stops the process.
private struct ComposeLogsSheet: View {
    let project: ComposeProject
    let socketPath: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var service: String?
    @State private var services: [String] = []
    @State private var error: String?
    @State private var filter = ""

    private var displayed: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs — \(project.name)").font(.headline)
                Picker("Service", selection: $service) {
                    Text("All").tag(String?.none)
                    ForEach(services, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Spacer()
                Button("Copy") { Pasteboard.copy(displayed) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 12) }
            CodeTextView(text: displayed, autoScroll: true)
        }
        .frame(minWidth: 760, idealWidth: 800, maxWidth: .infinity, minHeight: 480, idealHeight: 540, maxHeight: .infinity)
        .task {
            let fromContainers = Set(store.composeModel.containers(in: project.name).compactMap(\.composeService))
            services = Array(fromContainers).filter(ComposeService.isValidServiceName).sorted()
        }
        .task(id: service) {
            text = ""
            error = nil
            var pending = ""
            var lastFlush = Date()
            do {
                for try await line in ComposeService.logs(project: project, service: service, tail: 300, socketPath: socketPath) {
                    pending += line + "\n"
                    if Date().timeIntervalSince(lastFlush) > 0.2 {
                        append(pending); pending = ""; lastFlush = .now
                    }
                }
                append(pending)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        if text.utf8.count > 2_000_000 { text = String(text.suffix(1_000_000)) }
    }
}
