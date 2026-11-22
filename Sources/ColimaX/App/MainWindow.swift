import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, monitoring, diagnostics, containers, compose, images, volumes, networks, storage, backups, topology, proxy, runtime, preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .monitoring: String(localized: "Monitoring")
        case .diagnostics: String(localized: "Diagnostics")
        case .storage: String(localized: "Storage")
        case .containers: String(localized: "Containers")
        case .compose: String(localized: "Compose")
        case .images: String(localized: "Images")
        case .volumes: String(localized: "Volumes")
        case .networks: String(localized: "Networks")
        case .backups: String(localized: "Backups")
        case .topology: String(localized: "Topology")
        case .proxy: String(localized: "Local Domains")
        case .runtime: String(localized: "Runtime Settings")
        case .preferences: String(localized: "Preferences")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .monitoring: "chart.xyaxis.line"
        case .diagnostics: "stethoscope"
        case .storage: "chart.pie"
        case .containers: "shippingbox"
        case .compose: "square.stack.3d.up"
        case .images: "opticaldiscdrive"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .backups: "calendar.badge.clock"
        case .topology: "point.3.connected.trianglepath.dotted"
        case .proxy: "globe"
        case .runtime: "cpu"
        case .preferences: "gearshape"
        }
    }

    static let sections: [(String, [Screen])] = [
        (String(localized: "Overview"), [.dashboard, .monitoring, .diagnostics]),
        ("Docker", [.containers, .compose, .images, .volumes, .networks, .storage]),
        (String(localized: "Tools"), [.backups, .topology, .proxy]),
        (String(localized: "Settings"), [.runtime, .preferences]),
    ]

    /// ⌘1…⌘9 in sidebar order.
    static var shortcutOrder: [Screen] { Array(sections.flatMap(\.1).prefix(9)) }
}

struct MainWindow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            // Don't use ScrollViewReader.scrollTo in the sidebar: SwiftUI clamps the offset to 0, ignoring
            // the titlebar inset AppKit adds, so the top of the list slides under the window buttons.
            List(selection: $store.screen) {
                ForEach(Screen.sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { screen in
                            Label(screen.title, systemImage: screen.icon)
                                .badge(badge(for: screen))
                                .tag(screen)
                        }
                    }
                    // Only 14 items: disable section collapsing to avoid disclosure arrows that appear only on hover.
                    .collapsible(false)
                }
            }
            .sidebarTopEdgeEffect()
            // max 230: minimum window 960 − 230 = 730 ≥ the widest screen's minimum (Containers with its details pane: 721).
            // If the detail needs more width than remains, the window content overflows on both sides and sidebar labels get clipped.
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 230)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            VStack(spacing: 0) {
                if let error = store.operations.errorMessage {
                    Banner(kind: .error, message: error) { store.operations.errorMessage = nil }
                        .padding([.horizontal, .top], 12)
                }
                if let flash = store.operations.flashMessage {
                    Banner(kind: .info, message: flash)
                        .padding([.horizontal, .top], 12)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("flash.message")
                }
                detail(for: store.screen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                OperationPanel()
            }
            .navigationTitle(store.screen.title)
            .toolbar { ProfileToolbar() }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $store.snapshotTarget) { ElasticsearchSnapshotSheet(container: $0) }
        .sheet(isPresented: Binding(get: { store.setupModel.isPresented }, set: { store.setupModel.isPresented = $0 })) { SetupSheet() }
    }

    @ViewBuilder
    private func detail(for screen: Screen) -> some View {
        switch screen {
        case .dashboard: DashboardView()
        case .monitoring: DockerGate { MonitoringView() }
        case .containers: DockerGate { ContainersView() }
        case .compose: DockerGate { ComposeView() }
        case .images: DockerGate { ImagesView() }
        case .volumes: DockerGate { VolumesView() }
        case .networks: DockerGate { NetworksView() }
        case .storage: DockerGate { StorageView() }
        case .backups: BackupsView()
        case .topology: DockerGate { TopologyView() }
        case .proxy: DockerGate { LocalDomainsView() }
        case .diagnostics: DiagnosticsView()
        case .runtime: RuntimeSettingsView()
        case .preferences: PreferencesView()
        }
    }

    private func badge(for screen: Screen) -> Int {
        guard store.isRunning else { return 0 }
        switch screen {
        case .containers: return store.runningCount
        default: return 0
        }
    }
}

private struct SidebarStatus: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: store.operations.isOperationRunning ? .orange : (store.selectedProfile?.statusColor ?? .gray))
            VStack(alignment: .leading, spacing: 1) {
                Text(store.selectedProfileName).font(.callout.weight(.medium))
                Text(store.operations.isOperationRunning ? String(localized: "Processing…") : (store.selectedProfile?.status ?? "—"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRunning {
                Image(systemName: store.dockerConnected ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(store.dockerConnected ? .green : .secondary)
                    .help(store.dockerConnected ? "Receiving Docker events in real time" : "Lost connection to Docker events")
            }
        }
    }
}

struct ProfileToolbar: ToolbarContent {
    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(store.profiles) { profile in
                    Button {
                        store.select(profile.name)
                    } label: {
                        Label("\(profile.name) — \(profile.status)",
                              systemImage: profile.name == store.selectedProfileName ? "checkmark" : "circle")
                    }
                }
            } label: {
                Label(store.selectedProfileName, systemImage: "server.rack")
            }
            .help("Choose Colima profile")

            if store.isRunning {
                Button("Restart", systemImage: "arrow.clockwise") { VMControl.restart(store) }
                    .help("Restart")
                    .disabled(store.operations.isOperationRunning)
                Button("Stop", systemImage: "stop.fill") { VMControl.stop(store) }
                    .accessibilityIdentifier("toolbar.vm.stop")
                    .help("Stop")
                    .disabled(store.operations.isOperationRunning)
            } else {
                Button("Start", systemImage: "play.fill") { store.runtimeModel.startVM() }
                    .help("Start")
                    .disabled(store.operations.isOperationRunning || store.selectedProfile == nil)
            }
        }
    }
}

private extension View {
    /// Fades content scrolled under the title bar (macOS 26+) so text doesn't overlap the window buttons.
    @ViewBuilder
    func sidebarTopEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
