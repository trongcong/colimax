import SwiftUI

struct NetworksView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\DockerNetwork.name)]
    @State private var showCreate = false
    @State private var inspecting: DockerNetwork?
    @State private var managing: DockerNetwork?

    private func members(_ network: DockerNetwork) -> [DockerContainer] {
        store.containers.filter { $0.networkNames.contains(network.name) }
    }

    private var selected: DockerNetwork? { store.networks.first { $0.id == selection } }

    var body: some View {
        Table(store.networks.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { network in
                HStack(spacing: 6) {
                    if store.operations.busy.contains(network.id) { ProgressView().controlSize(.mini) }
                    Text(network.name)
                    if network.isBuiltIn {
                        Text("default").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Driver", value: \.driver)
                .width(min: 60, ideal: 80)
            TableColumn("Subnet") { Text($0.subnets.isEmpty ? "—" : $0.subnets).font(.caption.monospaced()) }
            TableColumn("Internal") { Text(($0.internal ?? false) ? "Yes" : "—") }
                .width(min: 50, ideal: 60)
            TableColumn("Container") { network in
                let names = members(network).map(\.name)
                Text(names.isEmpty ? "—" : names.joined(separator: ", ")).lineLimit(1)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let network = store.networks.first(where: { $0.id == id }) {
                Button("Inspect") { inspecting = network }
                if network.name != "host", network.name != "none" {
                    Button("Containers in Network…") { managing = network }
                }
                Button("Copy ID") { Pasteboard.copy(network.id) }
                if !network.isBuiltIn {
                    Divider()
                    Button("Delete…", role: .destructive) { confirmRemove(network) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Create", systemImage: "plus") { showCreate = true }
                    .help("Create")
                Button("Inspect", systemImage: "info.circle") { inspecting = selected }
                    .help("Inspect")
                    .disabled(selected == nil)
                Button("Container", systemImage: "point.3.connected.trianglepath.dotted") { managing = selected }
                    .disabled(selected == nil || selected?.name == "host" || selected?.name == "none")
                    .help("Connect / disconnect containers from the network")
                Button("Delete", systemImage: "trash") { if let selected { confirmRemove(selected) } }
                    .help("Delete")
                    .disabled(selected == nil || selected?.isBuiltIn == true)
                Button("Prune", systemImage: "sparkles") { confirmPrune() }
                    .help("Prune")
                    .disabled(store.operations.busy.contains("prune:networks"))
            }
        }
        .sheet(isPresented: $showCreate) { CreateNetworkSheet() }
        .sheet(item: $managing) { network in NetworkMembersSheet(networkID: network.id) }
        .sheet(item: $inspecting) { network in
            InspectSheet(title: network.name) { try await store.docker.inspectNetwork(network.id) }
        }
    }

    private func confirmRemove(_ network: DockerNetwork) {
        guard !network.isBuiltIn else { return }
        let attached = members(network)
        guard attached.isEmpty else {
            store.operations.errorMessage = String(localized: "The network still has containers: \(attached.map(\.name).joined(separator: ", ")).")
            return
        }
        if Confirm.destructive(String(localized: "Delete network \(network.name)?"), message: String(localized: "This cannot be undone."), button: String(localized: "Delete")) {
            store.networksModel.remove(network)
        }
    }

    private func confirmPrune() {
        if Confirm.destructive(String(localized: "Prune unused networks?"), message: String(localized: "Removes every user-created network that has no containers."), button: String(localized: "Prune")) {
            store.networksModel.prune()
        }
    }
}

private struct CreateNetworkSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "bridge"
    @State private var subnet = ""
    @State private var gateway = ""
    @State private var isInternal = false

    private var nameValid: Bool { name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil }
    private var subnetValid: Bool { subnet.isEmpty || subnet.range(of: #"^[0-9a-fA-F:.]+/[0-9]{1,3}$"#, options: .regularExpression) != nil }
    private var gatewayValid: Bool { gateway.isEmpty || (!subnet.isEmpty && gateway.range(of: #"^[0-9a-fA-F:.]+$"#, options: .regularExpression) != nil) }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("my-network"))
                .accessibilityIdentifier("network.name")
            Picker("Driver", selection: $driver) {
                ForEach(["bridge", "macvlan", "ipvlan"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Subnet (optional)", text: $subnet, prompt: Text("172.30.0.0/16"))
                .accessibilityIdentifier("network.subnet")
            if !subnetValid {
                Text("Subnet must be CIDR, e.g. 172.30.0.0/16").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("network.subnetError")
            }
            TextField("Gateway (optional)", text: $gateway, prompt: Text("172.30.0.1"))
                .accessibilityIdentifier("network.gateway")
                .disabled(subnet.isEmpty)
            Toggle("Internal (no Internet access)", isOn: $isInternal)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    store.networksModel.create(
                        name: name,
                        driver: driver,
                        subnet: subnet.isEmpty ? nil : subnet,
                        gateway: gateway.isEmpty ? nil : gateway,
                        isInternal: isInternal
                    )
                    dismiss()
                }
                .disabled(!nameValid || !subnetValid || !gatewayValid)
                .accessibilityIdentifier("network.create")
            }
        }
    }
}

/// Connects / disconnects containers to / from a network.
private struct NetworkMembersSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let networkID: String
    @State private var candidate: String?

    private var network: DockerNetwork? { store.networks.first { $0.id == networkID } }
    private var members: [DockerContainer] {
        guard let network else { return [] }
        return store.containers.filter { $0.networkNames.contains(network.name) }.sorted { $0.name < $1.name }
    }
    private var others: [DockerContainer] {
        guard let network else { return [] }
        return store.containers.filter { !$0.networkNames.contains(network.name) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Network \(network?.name ?? "")").font(.headline)
                if store.operations.busy.contains(networkID) { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            List {
                Section("Connected (\(members.count))") {
                    if members.isEmpty { Text("No containers yet").foregroundStyle(.secondary) }
                    ForEach(members) { container in
                        HStack {
                            StatusDot(color: container.stateColor)
                            Text(container.name)
                            Spacer()
                            if let network, let ip = container.networkSettings?.networks?[network.name]?.ipAddress, !ip.isEmpty {
                                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Button("Disconnect") { confirmDisconnect(container) }
                                .disabled(store.operations.busy.contains(networkID))
                        }
                    }
                }
                Section("Connect a Container") {
                    HStack {
                        Picker("Container", selection: $candidate) {
                            Text("Choose a container").tag(String?.none)
                            ForEach(others) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("Connect") {
                            if let network, let container = others.first(where: { $0.id == candidate }) {
                                store.networksModel.connect(container, to: network)
                                candidate = nil
                            }
                        }
                        .disabled(candidate == nil || store.operations.busy.contains(networkID))
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
    }

    private func confirmDisconnect(_ container: DockerContainer) {
        guard let network else { return }
        let ok = Confirm.ask(
            String(localized: "Disconnect \(container.name) from \(network.name)?"),
            message: String(localized: "The container will lose connectivity to other containers in this network until it is reconnected."),
            button: String(localized: "Disconnect"),
            destructive: false
        ).confirmed
        if ok { store.networksModel.disconnect(container, from: network) }
    }
}
