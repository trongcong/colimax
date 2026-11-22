import SwiftUI

/// `*.localhost` local domains through a Caddy reverse proxy (G23).
struct LocalDomainsView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var selection: UUID?

    private var proxy: ProxyStore { store.proxy }

    var body: some View {
        @Bindable var proxy = proxy
        VStack(spacing: 0) {
            if let error = proxy.error {
                Banner(kind: .error, message: error) { proxy.error = nil }.padding([.horizontal, .top], 12)
            }
            if !proxy.skipped.isEmpty {
                Banner(kind: .error, message: String(localized: "Skipped routes:") + "\n" + proxy.skipped.joined(separator: "\n")).padding([.horizontal, .top], 12)
            }
            Form {
                Section {
                    HStack {
                        StatusDot(color: proxy.isRunning ? .green : .gray)
                        Text(statusText)
                        Spacer()
                        if proxy.busy { ProgressView().controlSize(.small) }
                        if proxy.isRunning {
                            Button("Reload") { Task { await proxy.apply() } }
                            Button("Stop") { Task { await proxy.stop() } }
                        } else {
                            Button("Start Proxy") { Task { await proxy.start() } }.buttonStyle(.borderedProminent)
                        }
                        if proxy.status?.exists == true {
                            Button("Remove…") { confirmRemove() }
                        }
                    }
                    .disabled(proxy.busy)
                } header: {
                    Text("Proxy")
                } footer: {
                    Text("Runs \(LocalProxy.image) as container “\(LocalProxy.containerName)” on the VM host network, listening only on 127.0.0.1 (Colima forwards it to this Mac). It reaches containers by IP, so it never joins your networks. Browsers resolve *.localhost without any DNS change.")
                }

                Section("Settings") {
                    Toggle("HTTPS with Caddy local certificates", isOn: $proxy.settings.https)
                    HStack {
                        TextField("HTTP port", value: $proxy.settings.httpPort, format: .number.grouping(.never))
                        TextField("HTTPS port", value: $proxy.settings.httpsPort, format: .number.grouping(.never))
                    }
                    Text("Changes apply on Reload. Ports are on this Mac’s localhost; ports below 1024 may be refused by Colima’s port forwarder on some setups — use 8080 / 8443 then.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if proxy.routes.isEmpty {
                        Text("No domains yet.").foregroundStyle(.secondary)
                    }
                    ForEach(proxy.routes) { route in
                        HStack {
                            if let url = URL(string: proxy.settings.url(for: route)) {
                                Link(proxy.settings.url(for: route), destination: url)
                            }
                            Spacer()
                            Text(verbatim: "→ \(route.container):\(route.port)").foregroundStyle(.secondary)
                            Button {
                                Task { await proxy.remove(route.id) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove domain")
                        }
                    }
                    Button("Add Domain…") { adding = true }
                } header: {
                    Text("Domains")
                }

                Section {
                    Button("Trust Caddy Local CA…") { confirmTrust() }
                        .disabled(!proxy.isRunning || proxy.busy || !proxy.settings.https)
                    Button("Remove Trust") { Task { await proxy.untrustCertificate() } }
                        .disabled(proxy.busy)
                } header: {
                    Text("HTTPS Certificate")
                } footer: {
                    Text("Optional. Without it browsers show a certificate warning. Trusting adds Caddy’s root CA to your login keychain; macOS asks for your password. The CA private key stays in the Docker volume “\(LocalProxy.dataVolume)” — anyone who can read that volume can issue certificates your Mac trusts.")
                }
            }
            .formStyle(.grouped)
        }
        .task { await proxy.refresh() }
        .sheet(isPresented: $adding) { AddRouteSheet { route in Task { await proxy.add(route) } } }
    }

    private var statusText: String {
        guard let status = proxy.status else { return String(localized: "Checking…") }
        if status.running { return String(localized: "Running") }
        return status.exists ? String(localized: "Stopped") : String(localized: "Not created")
    }

    private func confirmRemove() {
        let ok = Confirm.destructive(String(localized: "Remove proxy container?"),
                                     message: String(localized: "Domains stop working until the proxy is started again. The CA volume “\(LocalProxy.dataVolume)” is kept."),
                                     button: String(localized: "Remove"))
        if ok { Task { await proxy.remove() } }
    }

    private func confirmTrust() {
        let ok = Confirm.ask(
            String(localized: "Trust the Caddy local CA?"),
            message: String(localized: "Its root certificate is added to your login keychain and trusted for SSL. Certificates it issues for *.localhost will be accepted by Safari and Chrome. You can undo this with Remove Trust or in Keychain Access."),
            button: String(localized: "Trust"),
            destructive: false
        ).confirmed
        if ok { Task { await proxy.trustCertificate() } }
    }
}

private struct AddRouteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onAdd: (ProxyRoute) -> Void

    @State private var subdomain = ""
    @State private var container = ""
    @State private var port = 80

    private var candidates: [DockerContainer] {
        store.containers.filter { $0.labels?[LocalProxy.label] == nil }.sorted { $0.name < $1.name }
    }

    private var ports: [Int] {
        let selected = candidates.first { $0.name == container }
        return Array(Set((selected?.ports ?? []).filter { $0.type == "tcp" }.map(\.privatePort))).sorted()
    }

    private var route: ProxyRoute { ProxyRoute(subdomain: subdomain.lowercased(), container: container, port: port) }

    var body: some View {
        Form {
            TextField("Domain", text: $subdomain, prompt: Text(verbatim: "myapp"))
            Text(verbatim: "\(subdomain.isEmpty ? "myapp" : subdomain.lowercased()).localhost")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Container", selection: $container) {
                Text("Choose…").tag("")
                ForEach(candidates) { Text($0.name).tag($0.name) }
            }
            HStack {
                TextField("Container port", value: $port, format: .number.grouping(.never))
                if !ports.isEmpty {
                    Picker("", selection: $port) {
                        ForEach(ports, id: \.self) { Text(verbatim: Format.digits($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            if !subdomain.isEmpty, !ProxyRoute.isValidSubdomain(subdomain.lowercased()) {
                Text("Use lowercase letters, digits and '-', separated by dots.").font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .navigationTitle("Add Local Domain")
        .onChange(of: container) { _, _ in if let first = ports.first { port = first } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { onAdd(route); dismiss() }.disabled(!route.isValid)
            }
        }
    }
}
