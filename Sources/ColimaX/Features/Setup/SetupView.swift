import SwiftUI

/// Setup assistant (G26): checks for Homebrew, colima, the docker CLI and the compose plugin,
/// installs missing tools via `brew install` after user confirmation, and starts the first profile.
struct SetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var localError: String?
    @State private var showAtLaunch = !UserDefaults.standard.bool(forKey: SetupModel.hideAtLaunchKey)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let report = store.setupModel.prerequisites {
                VStack(spacing: 0) {
                    ToolRow(name: "Homebrew", detail: String(localized: "Package manager used to install the tools below"),
                            path: report.brewPath, state: report.hasBrew ? .ok : .missing)
                    Divider()
                    ToolRow(name: "Colima", detail: String(localized: "Runs the Linux VM and the container runtime (required)"),
                            path: report.colimaPath, state: report.colimaPath != nil ? .ok : .missing)
                    Divider()
                    ToolRow(name: "Docker CLI", detail: String(localized: "Used by the Compose screen and the Terminal shell"),
                            path: report.dockerPath, state: report.dockerPath != nil ? .ok : .missing)
                    Divider()
                    ToolRow(name: "Docker Compose", detail: String(localized: "docker compose plugin, used by the Compose screen"),
                            path: report.composePluginDirectory,
                            state: report.composeAvailable ? .ok : (report.needsComposePluginConfig ? .needsSetup : .missing))
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                actions(report)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Checking installed tools…") }
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let error = localError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            operationLog
            footer
        }
        .padding(20)
        .frame(width: 600)
        .task { if store.setupModel.prerequisites == nil { await recheck() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up ColimaX").font(.title2.weight(.semibold))
                Text("ColimaX manages Colima and Docker installed on this Mac. It installs them with Homebrew only after you confirm.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func actions(_ report: PrerequisiteReport) -> some View {
        let missing = report.missingFormulae
        if !missing.isEmpty && !report.hasBrew {
            VStack(alignment: .leading, spacing: 8) {
                Text("Homebrew is not installed").font(.headline)
                Text("Install Homebrew in Terminal with the command below. It asks for your administrator password. Then come back and click Check Again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    Text(Prerequisites.homebrewInstallCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") { Pasteboard.copy(Prerequisites.homebrewInstallCommand) }
                        .accessibilityIdentifier("setup.copyBrewCommand")
                }
                Link("Homebrew installation guide (brew.sh)", destination: Prerequisites.homebrewURL)
            }
        } else if !missing.isEmpty {
            HStack {
                Text("Missing: \(missing.joined(separator: ", "))").foregroundStyle(.secondary)
                Spacer()
                Button("Install with Homebrew") { confirmInstall(missing) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.operations.isOperationRunning)
            }
        } else if report.needsComposePluginConfig, let directory = report.composePluginDirectory {
            HStack {
                Text("The Compose plugin is installed but the docker CLI does not load it yet.").foregroundStyle(.secondary)
                Spacer()
                Button("Configure Plugin") { confirmPluginConfig(directory) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.operations.isOperationRunning)
            }
        } else if report.colimaPath != nil, store.profilesLoaded, store.profiles.isEmpty {
            HStack {
                Text("Everything is installed. Start the first Colima VM (profile default) to begin.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Colima") { store.runtimeModel.startVM() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.operations.isOperationRunning)
            }
        } else if report.isComplete {
            Label("All tools are installed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("setup.allInstalled")
        }
    }

    @ViewBuilder
    private var operationLog: some View {
        if let operation = store.operations.operation {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    switch operation.status {
                    case .running: ProgressView().controlSize(.small)
                    case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(operation.title).font(.callout.weight(.medium))
                        .accessibilityIdentifier("setup.operation.title")
                    Spacer()
                    if operation.isRunning {
                        Button("Cancel", role: .cancel) { store.operations.cancelOperation() }
                    }
                }
                CodeTextView(text: operation.lines.joined(separator: "\n"), autoScroll: true)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Show this assistant at launch when tools are missing", isOn: $showAtLaunch)
                .accessibilityIdentifier("setup.showAtLaunch")
                .onChange(of: showAtLaunch) { _, on in
                    UserDefaults.standard.set(!on, forKey: SetupModel.hideAtLaunchKey)
                }
            Spacer()
            Button("Check Again") { Task { await recheck() } }
                .disabled(checking || store.operations.isOperationRunning)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func recheck() async {
        checking = true
        localError = nil
        await store.setupModel.check()
        await store.refreshProfiles()
        checking = false
    }

    private func confirmInstall(_ formulae: [String]) {
        let command = "brew install " + formulae.joined(separator: " ")
        let ok = Confirm.ask(
            String(localized: "Install with Homebrew?"),
            message: String(localized: "ColimaX will run: \(command)\nHomebrew downloads the packages from the internet. This can take a few minutes."),
            button: String(localized: "Install"),
            destructive: false
        ).confirmed
        guard ok else { return }
        localError = nil
        store.setupModel.install(formulae)
    }

    private func confirmPluginConfig(_ directory: String) {
        let configPath = Prerequisites.dockerConfigDirectory.appendingPathComponent("config.json").path
        let ok = Confirm.ask(
            String(localized: "Configure the Compose plugin?"),
            message: String(localized: "ColimaX will add \(directory) to cliPluginsExtraDirs in \(configPath). Other settings are kept, and the current file is saved as config.json.colimax-backup."),
            button: String(localized: "Configure"),
            destructive: false
        ).confirmed
        guard ok else { return }
        do {
            try Prerequisites.configureComposePlugin(directory: directory)
            Task { await recheck() }
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct ToolRow: View {
    enum State { case ok, missing, needsSetup }

    let name: String
    let detail: String
    let path: String?
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .needsSetup: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .ok:
                Text(verbatim: path ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            case .missing:
                Text("Not installed").font(.caption).foregroundStyle(.secondary)
            case .needsSetup:
                Text("Needs configuration").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // UI tests read the state from the identifier, e.g. `setup.tool.Docker CLI.missing`.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.tool.\(name).\(state)")
    }
}
