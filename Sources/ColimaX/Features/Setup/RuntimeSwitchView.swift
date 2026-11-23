import SwiftUI

/// Setup Assistant section for switching from OrbStack / Docker Desktop to Colima (G27).
/// Every change asks for confirmation first; `/var/run/docker.sock` is only explained.
struct RuntimeSwitchSection: View {
    @Environment(AppStore.self) private var store
    let report: RuntimeSwitchReport
    let onError: (String?) -> Void

    private var model: SetupModel { store.setupModel }
    private var configPath: String { Prerequisites.dockerConfigDirectory.appendingPathComponent("config.json").path }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch from other Docker runtimes").font(.headline)
                if !report.installed.isEmpty {
                    Text("Found: \(installedSummary)").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                contextRow
                if report.usesDesktopCredentials { Divider(); credentialsRow }
                if !report.brokenPlugins.isEmpty { Divider(); pluginsRow }
                ForEach(report.runningRuntimes) { installed in Divider(); quitRow(installed.runtime) }
                if let owner = report.cliOwner { Divider(); cliRow(owner) }
                if showsSocketRow { Divider(); socketRow }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.runtimes")
    }

    private var installedSummary: String {
        report.installed.map { installed in
            installed.isRunning
                ? String(localized: "\(installed.runtime.displayName) (running)")
                : installed.runtime.displayName
        }
        .joined(separator: ", ")
    }

    private var showsSocketRow: Bool {
        !report.defaultSocketTargetsProfile && (report.defaultSocketOwner != nil || !report.installed.isEmpty)
    }

    private func ownerName(_ owner: OtherDockerRuntime?, context: String) -> String {
        owner?.displayName ?? "“\(context)”"
    }

    // MARK: Rows

    @ViewBuilder
    private var contextRow: some View {
        let current = report.currentContext
        if report.dockerCLIPath == nil {
            StepRow(id: "context", state: .info, title: String(localized: "docker CLI not installed"),
                    detail: String(localized: "Install it above; ColimaX itself does not need the docker context."))
        } else if report.currentContextTargetsProfile {
            StepRow(id: "context", state: .ok, title: String(localized: "The docker CLI uses Colima"),
                    detail: String(localized: "Context “\(current.name)” points to profile \(report.profile)."),
                    button: model.previousContext.map { String(localized: "Switch Back to “\($0)”") }) {
                confirmSwitchBack()
            }
        } else if let target = report.colimaContext {
            StepRow(id: "context", state: .warning,
                    title: String(localized: "The docker CLI uses \(ownerName(report.currentContextOwner, context: current.name))"),
                    detail: String(localized: "Context “\(current.name)” (\(current.endpoint ?? "?")). `docker` commands in Terminal and IDEs do not reach Colima."),
                    button: String(localized: "Switch to Colima"), prominent: true) {
                confirmSwitch(to: target.name, from: current.name)
            }
        } else {
            StepRow(id: "context", state: .warning,
                    title: String(localized: "The docker CLI uses \(ownerName(report.currentContextOwner, context: current.name))"),
                    detail: String(localized: "Start profile \(report.profile) once: Colima then creates its docker context, and you can switch to it here."))
        }
    }

    private var credentialsRow: some View {
        StepRow(id: "credentials", state: report.credentialsBroken ? .error : .warning,
                title: String(localized: "Registry logins use Docker Desktop’s credential helper"),
                detail: report.credentialsBroken
                    ? String(localized: "`docker login` and `docker pull` fail: docker-credential-desktop is not installed.")
                    : String(localized: "They stop working once Docker Desktop is uninstalled."),
                button: report.keychainHelperInstalled
                    ? String(localized: "Use macOS Keychain")
                    : String(localized: "Install docker-credential-helper")) {
            if report.keychainHelperInstalled { confirmCredentials() } else { confirmInstallHelper() }
        }
    }

    private var pluginsRow: some View {
        StepRow(id: "plugins", state: .warning, title: String(localized: "Broken docker CLI plugins"),
                detail: String(localized: "\(report.brokenPlugins.map(\.name).joined(separator: ", ")) point to files that no longer exist, which hides working plugins (e.g. docker compose)."),
                button: String(localized: "Move Aside")) {
            confirmMovePlugins()
        }
    }

    private func quitRow(_ runtime: OtherDockerRuntime) -> some View {
        StepRow(id: "running.\(runtime.rawValue)", state: .info, title: String(localized: "\(runtime.displayName) is running"),
                detail: runtime.resetsContextOnStart
                    ? String(localized: "Two VMs use twice the memory and fight over published ports. \(runtime.displayName) also switches the docker context back to itself every time it starts.")
                    : String(localized: "Two VMs use twice the memory and fight over published ports. \(runtime.displayName) may also switch the docker context back when it starts."),
                button: String(localized: "Quit \(runtime.displayName)")) {
            confirmQuit(runtime)
        }
    }

    private func cliRow(_ owner: OtherDockerRuntime) -> some View {
        StepRow(id: "cli", state: .info, title: String(localized: "The docker CLI comes from \(owner.displayName)"),
                detail: String(localized: "\(report.dockerCLIPath ?? "") disappears if you uninstall \(owner.displayName). Install the Homebrew docker formula first (`brew install docker`)."))
    }

    private var socketRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            StepRow(id: "socket", state: .info,
                    title: report.defaultSocketTarget == nil
                        ? String(localized: "/var/run/docker.sock does not exist")
                        : String(localized: "/var/run/docker.sock goes to \(report.defaultSocketOwner?.displayName ?? report.defaultSocketTarget ?? "")"),
                    detail: String(localized: "Tools that ignore the docker context (Testcontainers, some IDEs and SDKs) use this path. Changing it needs administrator rights, so ColimaX only shows the commands. macOS clears /var/run at restart, and OrbStack / Docker Desktop point it back to themselves when they start, so the link must be created again."))
            VStack(alignment: .leading, spacing: 4) {
                CopyableCommand(command: report.linkDefaultSocketCommand, id: "linkSocket")
                Text("Or, without sudo, add this to your shell profile (~/.zshrc):").font(.caption).foregroundStyle(.secondary)
                CopyableCommand(command: report.dockerHostExport, id: "dockerHost")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: Actions

    private func run(_ change: @escaping @MainActor () async throws -> Void) {
        onError(nil)
        Task {
            do { try await change() } catch { onError(error.localizedDescription) }
        }
    }

    private func confirmSwitch(to target: String, from current: String) {
        guard Confirm.ask(
            String(localized: "Switch the docker CLI to Colima?"),
            message: String(localized: "ColimaX will set currentContext to “\(target)” in \(configPath). Other settings are kept, and the current file is saved as config.json.colimax-backup. You can switch back to “\(current)” here."),
            button: String(localized: "Switch"),
            destructive: false
        ).confirmed else { return }
        run { try await model.switchContextToColima() }
    }

    private func confirmSwitchBack() {
        guard let previous = model.previousContext, Confirm.ask(
            String(localized: "Switch the docker CLI back to “\(previous)”?"),
            message: String(localized: "`docker` commands in Terminal will no longer run on Colima. ColimaX itself is not affected."),
            button: String(localized: "Switch Back"),
            destructive: false
        ).confirmed else { return }
        run { try await model.switchContextBack() }
    }

    private func confirmCredentials() {
        guard Confirm.ask(
            String(localized: "Use the macOS Keychain for registry logins?"),
            message: String(localized: "ColimaX will replace “desktop” with “osxkeychain” in credsStore / credHelpers of \(configPath). The current file is saved as config.json.colimax-backup. If a registry asks for credentials, run `docker login` again."),
            button: String(localized: "Use Keychain"),
            destructive: false
        ).confirmed else { return }
        run { try await model.replaceDesktopCredentials() }
    }

    private func confirmInstallHelper() {
        guard Confirm.ask(
            String(localized: "Install with Homebrew?"),
            message: String(localized: "ColimaX will run: brew install docker-credential-helper\nThen click Use macOS Keychain."),
            button: String(localized: "Install"),
            destructive: false
        ).confirmed else { return }
        onError(nil)
        model.install(["docker-credential-helper"])
    }

    private func confirmMovePlugins() {
        let backup = Prerequisites.dockerConfigDirectory.appendingPathComponent("colimax-backup/cli-plugins").path
        guard Confirm.ask(
            String(localized: "Move broken plugins aside?"),
            message: String(localized: "ColimaX will move \(report.brokenPlugins.map(\.name).joined(separator: ", ")) to \(backup). Nothing is deleted."),
            button: String(localized: "Move Aside"),
            destructive: false
        ).confirmed else { return }
        run { try await model.moveBrokenPlugins() }
    }

    private func confirmQuit(_ runtime: OtherDockerRuntime) {
        guard Confirm.ask(
            String(localized: "Quit \(runtime.displayName)?"),
            message: String(localized: "Containers running in \(runtime.displayName) stop. Its images, volumes and settings are kept, and you can open it again at any time."),
            button: String(localized: "Quit \(runtime.displayName)")
        ).confirmed else { return }
        run {
            if !(await model.quit(runtime)) {
                onError(String(localized: "\(runtime.displayName) is still running. Quit it from its menu bar icon."))
            }
        }
    }
}

private struct StepRow: View {
    enum State: String { case ok, info, warning, error }

    let id: String
    let state: State
    let title: String
    let detail: String
    var button: String?
    var prominent = false
    var action: () -> Void = {}

    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.callout.weight(.medium))
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button {
                Group {
                    if prominent {
                        Button(button, action: action).buttonStyle(.borderedProminent)
                    } else {
                        Button(button, action: action)
                    }
                }
                .disabled(store.setupModel.isSwitching || store.operations.isOperationRunning)
                .accessibilityIdentifier("setup.runtime.\(id).action")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.runtime.\(id).\(state.rawValue)")
    }
}

private struct CopyableCommand: View {
    let command: String
    let id: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy") { Pasteboard.copy(command) }
                .accessibilityIdentifier("setup.runtime.\(id).copy")
        }
    }
}
