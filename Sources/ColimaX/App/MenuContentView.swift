import AppKit
import SwiftUI

/// Menu bar popover: quick controls for the VM and containers.
struct MenuContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)

            if let error = store.operations.errorMessage {
                Banner(kind: .error, message: error)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()
            containerList
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color: store.operations.isOperationRunning ? .orange : (store.selectedProfile?.statusColor ?? .gray))
                Menu {
                    ForEach(store.profiles) { profile in
                        Button {
                            store.select(profile.name)
                        } label: {
                            if profile.name == store.selectedProfileName {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    Text(store.selectedProfileName).font(.headline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if store.operations.isOperationRunning {
                    ProgressView().controlSize(.small)
                    Text(store.operations.operation?.lines.last ?? String(localized: "Processing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .trailing)
                } else {
                    Text(store.selectedProfile?.status ?? String(localized: "No profile"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let profile = store.selectedProfile, !profile.summary.isEmpty {
                Text(profile.summary).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if store.isRunning {
                    Button("Stop", systemImage: "stop.fill") { VMControl.stop(store) }
                        .help("Stop")
                    Button("Restart", systemImage: "arrow.clockwise") { VMControl.restart(store) }
                        .help("Restart")
                } else {
                    Button("Start", systemImage: "play.fill") { store.runtimeModel.startVM() }
                        .help("Start")
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .disabled(store.operations.isOperationRunning || store.selectedProfile == nil)
        }
    }

    @ViewBuilder
    private var containerList: some View {
        if !store.isRunning {
            placeholder(String(localized: "VM is not running"), systemImage: "moon.zzz")
        } else if !store.supportsDocker {
            placeholder(String(localized: "Runtime \(store.selectedProfile?.runtime ?? "") is not supported"), systemImage: "exclamationmark.triangle")
        } else if store.containers.isEmpty {
            placeholder(String(localized: "No containers yet"), systemImage: "shippingbox")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.containers.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }) { container in
                        MenuContainerRow(container: container) { openMain(focus: container.id) }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
        }
    }

    private var footer: some View {
        HStack {
            if store.isRunning {
                Text("\(store.runningCount)/\(store.containers.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open ColimaX") { openMain(focus: nil) }
                .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2)
            Text(text).font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func openMain(focus: String?) {
        if let focus {
            store.focusContainerID = focus
            store.screen = .containers
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuContainerRow: View {
    @Environment(AppStore.self) private var store
    let container: DockerContainer
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: container.stateColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.callout).lineLimit(1)
                Text(container.image).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if store.operations.busy.contains(container.id) {
                ProgressView().controlSize(.small)
            } else if hovering {
                HStack(spacing: 2) {
                    if container.isRunning {
                        if let port = container.publishedPorts.first {
                            icon("safari", String(localized: "Open localhost:\(Format.digits(port))")) {
                                if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                            }
                        }
                        icon("doc.text", String(localized: "Logs & Details"), action: onOpen)
                        icon("arrow.clockwise", String(localized: "Restart")) { store.containersModel.perform("restart", on: container) }
                        icon("stop.fill", String(localized: "Stop")) { store.containersModel.perform("stop", on: container) }
                    } else {
                        icon("doc.text", String(localized: "Logs & Details"), action: onOpen)
                        icon("play.fill", String(localized: "Start")) { store.containersModel.perform("start", on: container) }
                    }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(container.publishedPorts.prefix(2), id: \.self) { port in
                        Text(verbatim: ":\(port)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(container.status)
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
