import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @State private var config: RuntimeConfig?

    /// Narrowest a card column may get before the layout drops to fewer columns.
    private static let minCardWidth: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                profileCard
                if store.isRunning {
                    overviewCards
                }
            }
            .padding(20)
        }
        .task(id: store.selectedProfileName) {
            config = ColimaService.readConfig(store.selectedProfileName)
        }
        // Sample VM resources (one `colima ssh` per sample) only while the Dashboard is open and
        // its window can be seen: every 15 s, Docker overview every 30 s.
        .task(id: "\(store.selectedProfileName)-\(store.isRunning)") {
            guard store.isRunning else { return }
            await store.refreshOverview()
            var tick = 0
            while !Task.isCancelled {
                if WindowVisibility.isMainWindowVisible {
                    await store.refreshVMUsage()
                    tick += 1
                    if tick % 2 == 0 { await store.refreshOverview() }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var profileCard: some View {
        Card(title: "Colima — \(store.selectedProfileName)", systemImage: "server.rack") {
            HStack(spacing: 10) {
                StatusDot(color: store.operations.isOperationRunning ? .orange : (store.selectedProfile?.statusColor ?? .gray))
                Text(store.operations.isOperationRunning ? (store.operations.operation?.title ?? String(localized: "Processing")) : (store.selectedProfile?.status ?? String(localized: "No profile")))
                    .font(.title3.weight(.semibold))
                Spacer()
                if store.isRunning {
                    Button("Restart", systemImage: "arrow.clockwise") { VMControl.restart(store) }
                        .help("Restart")
                    Button("Stop", systemImage: "stop.fill") { VMControl.stop(store) }
                        .help("Stop")
                } else {
                    Button("Start", systemImage: "play.fill") { store.runtimeModel.startVM() }
                        .help("Start")
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(store.operations.isOperationRunning || store.selectedProfile == nil)

            if let profile = store.selectedProfile {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        spec("CPU", profile.cpus.map { String(localized: "\($0) cores") } ?? "—")
                        spec("RAM", profile.memory.map(Format.bytes) ?? "—")
                        spec(String(localized: "Disk"), profile.disk.map(Format.bytes) ?? "—")
                        spec("Arch", profile.arch ?? "—")
                    }
                    GridRow {
                        spec("Runtime", profile.runtime ?? "—")
                        spec(String(localized: "VM type"), config?.vmType ?? "—")
                        spec(String(localized: "Mount"), config?.mountType ?? "—")
                        spec(String(localized: "Address"), profile.address.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                    }
                }
            }
        }
    }

    private func spec(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
        }
    }

    /// Three cards in 3, 2 + 1 or 1 column(s), whichever fits the width. Not a `LazyVGrid`: an adaptive
    /// lazy grid inserted while a card shows an indeterminate spinner (VM just started, Docker info not
    /// loaded yet) can enter an endless layout pass that hangs the main thread.
    private var overviewCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                resourceCard.frame(minWidth: Self.minCardWidth)
                dockerCard.frame(minWidth: Self.minCardWidth)
                diskUsageCard.frame(minWidth: Self.minCardWidth)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    resourceCard.frame(minWidth: Self.minCardWidth)
                    dockerCard.frame(minWidth: Self.minCardWidth)
                }
                diskUsageCard
            }
            VStack(alignment: .leading, spacing: 16) {
                resourceCard
                dockerCard
                diskUsageCard
            }
        }
    }

    private var resourceCard: some View {
        Card(title: String(localized: "VM Resources"), systemImage: "cpu") {
            let usage = store.vmUsage
            MeterView(
                title: "CPU",
                value: store.vmCPUPercent.map { $0 / 100 },
                detail: usage.map { String(localized: "Load \(String(format: "%.2f", $0.load1)) · \($0.cpuCount) cores") } ?? String(localized: "Measuring…")
            )
            MeterView(
                title: "RAM",
                value: usage.flatMap { $0.memTotal > 0 ? Double($0.memUsed) / Double($0.memTotal) : nil },
                detail: usage.map { "\(Format.bytes($0.memUsed)) / \(Format.bytes($0.memTotal))" } ?? String(localized: "Measuring…"),
                tint: .purple
            )
            MeterView(
                title: String(localized: "Disk"),
                value: usage.flatMap { $0.diskTotal > 0 ? Double($0.diskUsed) / Double($0.diskTotal) : nil },
                detail: usage.map { "\(Format.bytes($0.diskUsed)) / \(Format.bytes($0.diskTotal))" } ?? String(localized: "Measuring…"),
                tint: .teal
            )
        }
    }

    private var dockerCard: some View {
        Card(title: "Docker", systemImage: "shippingbox") {
            if let info = store.info {
                KeyValueRow(key: "Engine", value: info.serverVersion)
                KeyValueRow(key: "OS", value: info.operatingSystem)
                KeyValueRow(key: "Kernel", value: info.kernelVersion)
                KeyValueRow(key: String(localized: "Containers"), value: String(localized: "\(info.containersRunning) running · \(info.containersPaused) paused · \(info.containersStopped) stopped"))
                KeyValueRow(key: String(localized: "Images"), value: "\(store.images.count)")
                KeyValueRow(key: String(localized: "Volumes"), value: "\(store.volumes.count)")
                KeyValueRow(key: String(localized: "Networks"), value: "\(store.networks.count)")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private var diskUsageCard: some View {
        Card(title: String(localized: "Docker Disk Usage"), systemImage: "internaldrive") {
            if let usage = store.diskUsage {
                KeyValueRow(key: String(localized: "Images"), value: Format.bytes(usage.imagesSize))
                KeyValueRow(key: String(localized: "Containers"), value: Format.bytes(usage.containersSize))
                KeyValueRow(key: String(localized: "Volumes"), value: Format.bytes(usage.volumesSize))
                KeyValueRow(key: String(localized: "Build cache"), value: Format.bytes(usage.buildCacheSize))
                Divider()
                KeyValueRow(key: String(localized: "Total"), value: Format.bytes(usage.imagesSize + usage.containersSize + usage.volumesSize + usage.buildCacheSize))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}
