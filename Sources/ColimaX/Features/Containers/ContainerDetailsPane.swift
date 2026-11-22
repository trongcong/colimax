import SwiftUI

/// The container Info tab: live state (restarts, OOM, health), resource limits, networks, mounts,
/// environment variables (secrets masked) and labels.
struct ContainerDetailsPane: View {
    let container: DockerContainer
    let client: any DockerEngine

    @State private var details: ContainerDetails?
    @State private var error: String?
    @State private var revealSecrets = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    Banner(kind: .error, message: error)
                }
                general
                if let details {
                    stateSection(details)
                    resourcesSection(details)
                    networkSection(details)
                    mountsSection(details)
                    envSection(details)
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                labelsSection
            }
            .padding(12)
        }
        .task(id: "\(container.id)-\(container.state)-\(container.status)") {
            do {
                details = try await client.containerDetails(container.id)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 6) {
            KeyValueRow(key: "ID", value: container.shortID)
            KeyValueRow(key: "Image", value: container.image)
            KeyValueRow(key: String(localized: "Command"), value: container.command ?? "—")
            KeyValueRow(key: String(localized: "Created"), value: container.createdDate.formatted(date: .abbreviated, time: .standard))
            KeyValueRow(key: "Ports", value: container.portsDescription.isEmpty ? "—" : container.portsDescription)
            if let project = container.composeProject {
                KeyValueRow(key: "Compose", value: "\(project) / \(container.composeService ?? "—")")
            }
        }
    }

    @ViewBuilder
    private func stateSection(_ d: ContainerDetails) -> some View {
        section(String(localized: "State")) {
            KeyValueRow(key: String(localized: "State"), value: "\(container.state) — \(container.status)")
            KeyValueRow(key: String(localized: "Restart count"), value: "\(d.restartCount ?? 0)")
            if let policy = d.hostConfig?.restartPolicy?.name, !policy.isEmpty {
                let maxRetries = d.hostConfig?.restartPolicy?.maximumRetryCount ?? 0
                KeyValueRow(key: String(localized: "Restart policy"),
                            value: maxRetries > 0 ? String(localized: "\(policy) (max \(maxRetries))") : policy)
            }
            if container.state != "running", let code = d.state?.exitCode {
                KeyValueRow(key: String(localized: "Exit code"), value: "\(code)")
            }
            if d.oomKilled {
                Label("Killed for running out of memory (OOMKilled). Raise the container's memory limit or the VM's RAM.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if let message = d.state?.error, !message.isEmpty {
                KeyValueRow(key: String(localized: "Error"), value: message)
            }
            if let started = Format.date(iso: d.state?.startedAt) {
                KeyValueRow(key: String(localized: "Started"), value: started.formatted(date: .abbreviated, time: .standard))
            }
            if container.state != "running", let finished = Format.date(iso: d.state?.finishedAt) {
                KeyValueRow(key: String(localized: "Finished"), value: finished.formatted(date: .abbreviated, time: .standard))
            }
            if let health = d.state?.health {
                let status = health.status ?? "—"
                let streak = health.failingStreak ?? 0
                KeyValueRow(key: String(localized: "Health"),
                            value: streak > 0 ? String(localized: "\(status) · \(streak) consecutive failures") : status)
                if let last = health.log?.last, let output = last.output?.trimmed, !output.isEmpty {
                    KeyValueRow(key: String(localized: "Last probe"), value: "exit \(last.exitCode ?? -1): \(String(output.prefix(300)))")
                }
            }
        }
    }

    @ViewBuilder
    private func resourcesSection(_ d: ContainerDetails) -> some View {
        section(String(localized: "Resource Limits")) {
            KeyValueRow(key: String(localized: "Memory"), value: d.memoryLimit.map(Format.bytes) ?? String(localized: "Unlimited (up to the VM's RAM)"))
            KeyValueRow(key: "CPU", value: d.cpuLimit.map { String(localized: "\(Format.decimal($0)) cores") } ?? String(localized: "Unlimited"))
            KeyValueRow(key: "PIDs", value: d.pidsLimit.map(String.init) ?? String(localized: "Unlimited"))
            if d.hostConfig?.readonlyRootfs == true { KeyValueRow(key: "Rootfs", value: "read-only") }
            if let platform = d.platform { KeyValueRow(key: String(localized: "Platform"), value: platform) }
        }
    }

    @ViewBuilder
    private func networkSection(_ d: ContainerDetails) -> some View {
        let networks = d.networkSettings?.networks ?? [:]
        if !networks.isEmpty {
            section(String(localized: "Network")) {
                ForEach(networks.keys.sorted(), id: \.self) { name in
                    let endpoint = networks[name]
                    KeyValueRow(key: name, value: [
                        endpoint?.ipAddress.flatMap { $0.isEmpty ? nil : "IP \($0)" },
                        endpoint?.gateway.flatMap { $0.isEmpty ? nil : "GW \($0)" },
                        (endpoint?.aliases ?? []).isEmpty ? nil : "alias " + (endpoint?.aliases ?? []).joined(separator: ", "),
                    ].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                }
            }
        }
    }

    @ViewBuilder
    private func mountsSection(_ d: ContainerDetails) -> some View {
        let mounts = d.mounts ?? []
        if !mounts.isEmpty {
            section(String(localized: "Mounts")) {
                ForEach(mounts, id: \.self) { mount in
                    KeyValueRow(
                        key: mount.destination ?? "—",
                        value: "\(mount.type ?? "") \(mount.name ?? mount.source ?? "")" + (mount.rw == false ? " (ro)" : "")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func envSection(_ d: ContainerDetails) -> some View {
        let env = d.environment
        if !env.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Environment Variables").font(.subheadline.weight(.medium))
                    Spacer()
                    if env.contains(where: \.isSensitive) {
                        Toggle("Show Secrets", isOn: $revealSecrets)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .help("Values whose names look like passwords/tokens are masked by default")
                            .accessibilityIdentifier("env.showSecrets")
                    }
                }
                ForEach(env) { variable in
                    HStack(alignment: .firstTextBaseline) {
                        Text(variable.key).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                            .accessibilityIdentifier("env.key.\(variable.key)")
                        Text(variable.isSensitive && !revealSecrets ? variable.maskedValue : variable.value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("env.value.\(variable.key)")
                        if variable.isSensitive {
                            Image(systemName: "key.fill").foregroundStyle(.orange).help("Sensitive value")
                        }
                    }
                    .font(.callout.monospaced())
                    .contextMenu {
                        Button("Copy Name") { Pasteboard.copy(variable.key) }
                        if !variable.isSensitive || revealSecrets {
                            Button("Copy KEY=VALUE") { Pasteboard.copy("\(variable.key)=\(variable.value)") }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var labelsSection: some View {
        if let labels = container.labels, !labels.isEmpty {
            section(String(localized: "Labels")) {
                ForEach(labels.keys.sorted(), id: \.self) { key in
                    KeyValueRow(key: key, value: labels[key] ?? "")
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(title).font(.subheadline.weight(.medium))
            content()
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
