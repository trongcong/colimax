import SwiftUI

struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\DockerImage.created, order: .reverse)]
    @State private var showPull = false
    @State private var inspecting: DockerImage?
    @State private var scanning: DockerImage?

    private func usage(_ image: DockerImage) -> Int {
        store.containers.filter { $0.imageID == image.id }.count
    }

    private var filtered: [DockerImage] {
        store.images
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.shortID.contains(search) }
            .sorted(using: sortOrder)
    }

    private var selected: DockerImage? { store.images.first { $0.id == selection } }

    var body: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Image", value: \.displayName) { image in
                HStack(spacing: 6) {
                    if store.operations.busy.contains(image.id) { ProgressView().controlSize(.mini) }
                    Text(image.displayName).foregroundStyle(image.isDangling ? .secondary : .primary)
                    if image.tags.count > 1 {
                        Text("+\(image.tags.count - 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("ID") { Text($0.shortID).font(.caption.monospaced()) }
                .width(min: 90, ideal: 110)
            TableColumn("Arch") { image in
                if let platform = store.imagesModel.platforms[image.id] {
                    HStack(spacing: 4) {
                        Text(platform.architecture ?? "—").font(.caption.monospaced())
                        if HostPlatform.isAppleSilicon, platform.architecture != nil, !platform.isNativeARM64 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Not arm64: runs under emulation (Rosetta/QEMU) on Apple Silicon")
                                .accessibilityLabel(Text("Not arm64: runs under emulation (Rosetta/QEMU) on Apple Silicon"))
                                .accessibilityIdentifier("image.archWarning")
                        }
                    }
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 80)
            TableColumn("Size", value: \.size) { Text(Format.bytes($0.size)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("Created", value: \.created) { Text(Format.relative($0.createdDate)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 100)
            TableColumn("In Use") { image in
                let count = usage(image)
                Text(count == 0 ? "—" : "\(count) containers").foregroundStyle(count == 0 ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let image = store.images.first(where: { $0.id == id }) {
                Button("Inspect") { inspecting = image }
                Button("Scan for Vulnerabilities…") { scanning = image }
                ForEach(image.tags, id: \.self) { tag in
                    Button("Copy \(tag)") { Pasteboard.copy(tag) }
                }
                Divider()
                Button("Remove…", role: .destructive) { confirmRemove(image) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search images")
        .toolbar {
            ToolbarItemGroup {
                Button("Pull", systemImage: "arrow.down.circle") { showPull = true }
                    .help("Pull")
                    .disabled(store.operations.isOperationRunning)
                Button("Inspect", systemImage: "info.circle") { inspecting = selected }
                    .help("Inspect")
                    .disabled(selected == nil)
                Button("Scan", systemImage: "shield.lefthalf.filled") { scanning = selected }
                    .disabled(selected == nil)
                    .help("Scan for vulnerabilities with Trivy / Docker Scout")
                Button("Remove", systemImage: "trash") { if let selected { confirmRemove(selected) } }
                    .help("Remove")
                    .disabled(selected == nil)
                Menu {
                    Button("Prune Dangling Images…") { confirmPrune(all: false) }
                    Button("Prune All Unused Images…") { confirmPrune(all: true) }
                } label: {
                    Label("Prune", systemImage: "sparkles")
                }
                .help("Prune")
                .accessibilityIdentifier("images.prune")
                .disabled(store.operations.busy.contains("prune:images"))
            }
        }
        .task(id: store.images.map(\.id).joined()) { await store.imagesModel.loadPlatforms() }
        .sheet(isPresented: $showPull) { PullSheet() }
        .sheet(item: $scanning) { VulnerabilityScanSheet(image: $0) }
        .sheet(item: $inspecting) { image in
            InspectSheet(title: image.displayName) { try await store.docker.inspectImage(image.id) }
        }
    }

    private func confirmRemove(_ image: DockerImage) {
        let used = usage(image)
        let result = Confirm.ask(
            String(localized: "Remove image \(image.displayName)?"),
            message: used > 0 ? String(localized: "The image is used by \(used) containers.") : String(localized: "The image will be removed from the VM."),
            button: String(localized: "Remove"),
            checkbox: String(localized: "Force (remove even if in use / has multiple tags)")
        )
        if result.confirmed { store.imagesModel.remove(image, force: result.checkboxOn) }
    }

    private func confirmPrune(all: Bool) {
        let ok = Confirm.destructive(
            all ? String(localized: "Prune all unused images?") : String(localized: "Prune dangling images?"),
            message: all
                ? String(localized: "Removes every image not used by any container (including tagged ones). This cannot be undone.")
                : String(localized: "Removes untagged images (<none>). This cannot be undone."),
            button: String(localized: "Prune")
        )
        if ok { store.imagesModel.prune(all: all) }
    }
}

private struct PullSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""

    private var isValid: Bool {
        ImageReference.isValid(reference.trimmed)
    }

    var body: some View {
        Form {
            TextField("Image", text: $reference, prompt: Text(verbatim: "nginx:latest, ghcr.io/org/app:1.0"))
                .accessibilityIdentifier("pull.reference")
                .onSubmit(pull)
            Text("Progress is shown in the panel at the bottom of the window.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pull", action: pull).disabled(!isValid).accessibilityIdentifier("pull.confirm")
            }
        }
    }

    private func pull() {
        guard isValid else { return }
        store.imagesModel.pull(reference.trimmed)
        dismiss()
    }
}
