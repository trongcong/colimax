import SwiftUI

struct RuntimeSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var original: RuntimeConfig?
    @State private var draft = RuntimeConfig()
    @State private var showCreate = false
    /// Allows picking a smaller disk. Colima cannot shrink a disk in place, so this deletes the VM and its data and recreates it.
    @State private var allowShrink = false

    private var hostCPUs: Int { ProcessInfo.processInfo.processorCount }
    private var hostMemoryGiB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    private var change: RuntimeChange {
        original.map { RuntimeChange.plan(from: $0, to: draft, isRunning: store.isRunning) } ?? .none
    }
    private var changed: Bool { change != .none }
    private var needsRecreate: Bool { change.recreatesVM }

    var body: some View {
        Form {
            Section("Profile") {
                Picker("Profile", selection: Binding(get: { store.selectedProfileName }, set: { store.select($0) })) {
                    ForEach(store.profiles) { Text(verbatim: "\($0.name) — \($0.status)").tag($0.name) }
                }
                HStack {
                    Button("New Profile…", systemImage: "plus") { showCreate = true }
                        .help("New Profile…")
                    Button("Open colima.yaml", systemImage: "doc.text") {
                        NSWorkspace.shared.open(ColimaService.profileDirectory(store.selectedProfileName).appendingPathComponent("colima.yaml"))
                    }
                        .help("Open colima.yaml")
                    Spacer()
                    Button("Delete Profile…", systemImage: "trash", role: .destructive) { confirmDeleteProfile() }
                        .help("Delete Profile…")
                        .accessibilityIdentifier("runtime.deleteProfile")
                        .disabled(store.selectedProfile == nil)
                }
                .disabled(store.operations.isOperationRunning)
            }

            if original == nil {
                Section {
                    Text("Could not read this profile's colima.yaml.").foregroundStyle(.secondary)
                }
            } else {
                RuntimeConfigFields(config: $draft, minDisk: needsRecreate || allowShrink ? 1 : (original?.diskGiB ?? 1), hostCPUs: hostCPUs, hostMemoryGiB: hostMemoryGiB)

                Section {
                    Toggle(isOn: $allowShrink) {
                        Text("Unlock a smaller disk for this change (recreates the VM)")
                        Text("Turns off again when you leave this screen, switch profile or apply.")
                    }
                        .accessibilityIdentifier("runtime.allowShrink")
                        .onChange(of: allowShrink) { _, on in
                            if !on, let original, draft.diskGiB < original.diskGiB { draft.diskGiB = original.diskGiB }
                        }
                    if allowShrink {
                        Text("Colima cannot shrink a disk in place. A smaller disk deletes the VM and all its data (containers, images, volumes), then creates it again. Back up volumes and databases first.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section {
                    if needsRecreate {
                        Label("Changing arch / runtime / VM type requires deleting and recreating the VM.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if changed, store.isRunning {
                        Label("The VM will be stopped and restarted to apply the changes.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Revert") { if let original { draft = original } }
                            .disabled(!changed)
                        Button(needsRecreate ? "Reset VM & Apply…" : "Apply") { apply() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("runtime.apply")
                            .disabled(!changed || store.operations.isOperationRunning)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(store.selectedProfileName)-\(store.operations.isOperationRunning)") { load() }
        .sheet(isPresented: $showCreate) {
            CreateProfileSheet(hostCPUs: hostCPUs, hostMemoryGiB: hostMemoryGiB)
        }
    }

    private func load() {
        guard !store.operations.isOperationRunning else { return }
        original = store.colima.readConfig(store.selectedProfileName)
        if let original { draft = original }
        allowShrink = false
    }

    private func apply() {
        guard let original else { return }
        let name = store.selectedProfileName
        switch change {
        case .none:
            return
        case .shrinkDisk:
            let ok = Confirm.typed(
                String(localized: "Shrink disk of \(name) from \(original.diskGiB) GiB to \(draft.diskGiB) GiB?"),
                message: String(localized: "The VM and ALL its data (containers, images, volumes) will be deleted, then the VM is created again with the new configuration. This cannot be undone."),
                expected: name,
                button: String(localized: "Delete Data & Recreate")
            )
            guard ok else { return }
            allowShrink = false
            store.runtimeModel.applyRuntimeConfig(draft, recreate: true, deleteData: true)
        case .recreate:
            let result = Confirm.ask(
                String(localized: "Reset VM \(name)?"),
                message: String(localized: "The VM will be deleted and recreated with the new configuration (arch \(original.arch)→\(draft.arch), runtime \(original.runtime)→\(draft.runtime), VM \(original.vmType)→\(draft.vmType))."),
                button: String(localized: "Reset"),
                checkbox: String(localized: "Also delete runtime data (containers, images, volumes)")
            )
            guard result.confirmed else { return }
            store.runtimeModel.applyRuntimeConfig(draft, recreate: true, deleteData: result.checkboxOn)
        case .restart:
            let ok = Confirm.ask(
                String(localized: "Restart the VM?"),
                message: String(localized: "Running containers will be stopped while the VM restarts."),
                button: String(localized: "Apply"),
                destructive: false
            ).confirmed
            guard ok else { return }
            store.runtimeModel.applyRuntimeConfig(draft, recreate: false, deleteData: false)
        case .apply:
            store.runtimeModel.applyRuntimeConfig(draft, recreate: false, deleteData: false)
        }
    }

    private func confirmDeleteProfile() {
        let name = store.selectedProfileName
        let result = Confirm.ask(
            String(localized: "Delete profile \(name)?"),
            message: String(localized: "The profile's VM will be deleted. This cannot be undone."),
            button: String(localized: "Delete"),
            checkbox: String(localized: "Also delete runtime data (containers, images, volumes)")
        )
        if result.confirmed { store.runtimeModel.deleteProfile(name, deleteData: result.checkboxOn) }
    }
}

struct RuntimeConfigFields: View {
    @Binding var config: RuntimeConfig
    let minDisk: Int
    let hostCPUs: Int
    let hostMemoryGiB: Double

    var body: some View {
        Section("Resources") {
            PlusMinusStepper(value: $config.cpus, in: 1...max(1, hostCPUs), identifier: "runtime.cpus") {
                LabeledContent("CPU", value: String(localized: "\(config.cpus) / \(hostCPUs) cores"))
            }
            PlusMinusStepper(value: $config.memoryGiB, range: 1...max(1, hostMemoryGiB.rounded(.down)), step: 1) {
                LabeledContent("RAM", value: "\(Format.decimal(config.memoryGiB)) GiB / \(Int(hostMemoryGiB)) GiB")
            }
            PlusMinusStepper(value: $config.diskGiB, in: max(1, minDisk)...2048, step: 10, identifier: "runtime.disk") {
                LabeledContent("Disk", value: "\(config.diskGiB) GiB")
            }
            if minDisk > 1 {
                Text("Disk can only grow, not shrink (minimum \(minDisk) GiB).").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Virtualization") {
            Picker("VM type", selection: $config.vmType) {
                ForEach(RuntimeConfig.vmTypes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Mount type", selection: $config.mountType) {
                ForEach(RuntimeConfig.mountTypes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Arch", selection: $config.arch) {
                ForEach(RuntimeConfig.archs, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("runtime.arch")
            Toggle("Rosetta (faster amd64 images)", isOn: $config.rosetta)
                .disabled(config.vmType != "vz")
            Toggle("Nested virtualization", isOn: $config.nestedVirtualization)
        }
        Section("Runtime") {
            Picker("Container runtime", selection: $config.runtime) {
                ForEach(RuntimeConfig.runtimes, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Kubernetes (k3s)", isOn: $config.kubernetes)
        }
    }
}

private struct CreateProfileSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let hostCPUs: Int
    let hostMemoryGiB: Double
    @State private var name = ""
    @State private var config = RuntimeConfig()

    private var nameError: String? {
        if name.isEmpty { return nil }
        if !ColimaService.isValidProfileName(name) { return String(localized: "Use only letters, digits, '-' and '_' (up to 31 characters)") }
        if store.profiles.contains(where: { $0.name == name }) { return String(localized: "Profile already exists") }
        return nil
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $name, prompt: Text("work"))
                    .accessibilityIdentifier("createProfile.name")
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("createProfile.error")
                }
            }
            RuntimeConfigFields(config: $config, minDisk: 1, hostCPUs: hostCPUs, hostMemoryGiB: hostMemoryGiB)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create & Start") {
                    store.runtimeModel.createProfile(name, config: config)
                    dismiss()
                }
                .accessibilityIdentifier("createProfile.create")
                .disabled(name.isEmpty || nameError != nil || store.operations.isOperationRunning)
            }
        }
    }
}
