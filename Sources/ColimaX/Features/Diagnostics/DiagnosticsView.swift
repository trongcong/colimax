import SwiftUI

/// View model for the Diagnostics screen: gathers data (I/O), then hands it to the pure check functions.
@MainActor
@Observable
final class DiagnosticsModel {
    var items: [DiagnosticItem] = []
    var running = false
    var lastRun: Date?
    /// Latest run. When the `.task(id:)` id changes (VM restart, Docker reconnect), SwiftUI cancels the old
    /// run and starts a new one; only the latest run may write results, so a cancelled run cannot overwrite them.
    private var generation = 0

    func run(store: AppStore) async {
        generation += 1
        let current = generation
        running = true
        defer {
            if generation == current { running = false; lastRun = .now }
        }

        let profile = store.selectedProfile
        let config = ColimaService.readConfig(store.selectedProfileName)
        let socketPath = store.socketPath
        let client = store.docker
        var pingError: String?
        if profile?.isRunning == true, store.supportsDocker {
            if store.runtimeStatus == nil { await store.resolveEndpoint() }
            do {
                try await client.ping(timeout: 5)
            } catch is CancellationError {
                return
            } catch {
                pingError = error.localizedDescription
            }
        }

        let snapshot = RuntimeSnapshot(
            colimaPath: Shell.which("colima"),
            dockerCLIPath: Shell.which("docker"),
            profile: profile,
            config: config,
            status: store.runtimeStatus,
            socketPath: store.socketPath,
            socketPermissions: profile?.isRunning == true ? SocketPermissions.read(socketPath) : nil,
            pingError: pingError,
            dockerContext: store.services.dockerContext(),
            hostCPUs: ProcessInfo.processInfo.processorCount,
            hostMemory: Int64(ProcessInfo.processInfo.physicalMemory),
            hostIsAppleSilicon: HostPlatform.isAppleSilicon,
            appTranslated: HostPlatform.isTranslated,
            vmDiskUsedFraction: store.vmUsage.flatMap { $0.diskTotal > 0 ? Double($0.diskUsed) / Double($0.diskTotal) : nil }
        )
        var result = RuntimeDiagnostics.check(snapshot)

        if pingError == nil, profile?.isRunning == true, store.supportsDocker {
            await store.imagesModel.loadPlatforms()
            result += ImageArchDiagnostics.check(
                images: store.images,
                platforms: store.imagesModel.platforms,
                containers: store.containers,
                rosettaEnabled: config?.rosetta ?? false,
                vmArch: profile?.arch ?? config?.arch ?? "aarch64"
            )
            let details = await Self.loadDetails(store.containers, client: client)
            let reachable = !(store.runtimeStatus?.ipAddress ?? "").isEmpty
            result += SecurityAudit.check(details, vmReachableFromNetwork: reachable)
            let probed = await BlockingIOPortProbe.inUse(ports: Set(details.flatMap { $0.declaredHostPorts.map(\.port) }))
            result += PortDiagnostics.check(details) { probed.contains($0) }
        }
        guard !Task.isCancelled, generation == current else { return }
        items = result
    }

    private static func loadDetails(_ containers: [DockerContainer], client: any DockerEngine) async -> [ContainerDetails] {
        await withTaskGroup(of: ContainerDetails?.self) { group in
            var collected: [ContainerDetails] = []
            var iterator = containers.map(\.id).makeIterator()
            for _ in 0..<min(6, containers.count) {
                if let id = iterator.next() { group.addTask { try? await client.containerDetails(id) } }
            }
            while let next = await group.next() {
                if let next { collected.append(next) }
                if let id = iterator.next() { group.addTask { try? await client.containerDetails(id) } }
            }
            return collected
        }
    }
}

/// Probes ports off the main thread (`bind()` is a short blocking syscall).
enum BlockingIOPortProbe {
    static func inUse(ports: Set<Int>) async -> Set<Int> {
        (try? await BlockingIO.run { Set(ports.filter(PortProbe.isInUse)) }) ?? []
    }
}

struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @State private var model = DiagnosticsModel()
    @State private var category: DiagnosticItem.Category?
    @State private var hideOK = false

    private var visible: [DiagnosticItem] {
        DiagnosticItem.visible(model.items, category: category, hideOK: hideOK)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                summary
                Spacer()
                Picker("Group", selection: $category) {
                    Text("All").tag(DiagnosticItem.Category?.none)
                    ForEach(DiagnosticItem.Category.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .fixedSize()
                Toggle("Hide OK items", isOn: $hideOK)
                Button {
                    Task { await model.run(store: store) }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .help("Check Again")
                .disabled(model.running)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .padding(12)
            Divider()
            if model.running && model.items.isEmpty {
                ProgressView("Checking…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView("No items", systemImage: "checkmark.seal").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { item in
                    DiagnosticRow(item: item) { id in
                        store.focusContainerID = id
                        store.screen = .containers
                    }
                }
            }
        }
        .task(id: "\(store.selectedProfileName)-\(store.isRunning)-\(store.dockerConnected)") {
            await model.run(store: store)
        }
    }

    private var summary: some View {
        let counts = Dictionary(grouping: model.items, by: \.severity).mapValues(\.count)
        return HStack(spacing: 10) {
            if model.running { ProgressView().controlSize(.small) }
            badge(counts[.critical] ?? 0, "xmark.octagon.fill", .red, String(localized: "critical"))
            badge(counts[.warning] ?? 0, "exclamationmark.triangle.fill", .orange, String(localized: "warning"))
            badge(counts[.info] ?? 0, "info.circle.fill", .blue, String(localized: "info"))
            badge(counts[.ok] ?? 0, "checkmark.circle.fill", .green, String(localized: "OK"))
            if let lastRun = model.lastRun {
                Text(lastRun.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ count: Int, _ icon: String, _ color: Color, _ label: String) -> some View {
        Label("\(count)", systemImage: icon)
            .foregroundStyle(count > 0 ? color : .secondary)
            .font(.callout.monospacedDigit())
            .help(Text(verbatim: "\(count) \(label)"))
            .accessibilityLabel(Text(verbatim: "\(count) \(label)"))
    }
}

private struct DiagnosticRow: View {
    let item: DiagnosticItem
    let openContainer: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.callout.weight(.medium))
                    Text(item.category.title).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let fix = item.recommendation {
                    Label(fix, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if let id = item.containerID {
                Button("Show Container") { openContainer(id) }.buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch item.severity {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.severity {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
