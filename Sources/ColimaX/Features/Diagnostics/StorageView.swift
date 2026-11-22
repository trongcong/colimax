import SwiftUI

/// Analyzes Docker disk usage and suggests cleanups. Every delete requires confirmation, and volumes
/// are only removed from the user's explicit selection (never an implicit prune of all volumes).
struct StorageView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedVolumes: Set<String> = []

    private var report: StorageReport? {
        store.diskUsage.map { StorageReport.analyze($0, containers: store.containers) }
    }

    var body: some View {
        Group {
            if let report, let usage = store.diskUsage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        breakdown(usage)
                        recommendations(report)
                        volumes(report)
                        images(report)
                    }
                    .padding(20)
                }
            } else {
                ProgressView("Reading /system/df…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refreshOverview() } }
                    .help("Refresh")
            }
        }
        .task { await store.refreshOverview() }
    }

    private func breakdown(_ usage: DiskUsage) -> some View {
        let total = usage.imagesSize + usage.containersSize + usage.volumesSize + usage.buildCacheSize
        return Card(title: String(localized: "Docker Disk Usage in VM"), systemImage: "internaldrive") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row(String(localized: "Images"), usage.imagesSize, total)
                row(String(localized: "Containers (writable layer)"), usage.containersSize, total)
                row(String(localized: "Volumes"), usage.volumesSize, total)
                row(String(localized: "Build cache"), usage.buildCacheSize, total)
                Divider()
                GridRow {
                    Text("Total").font(.callout.weight(.semibold))
                    Text(Format.bytes(total)).font(.callout.monospacedDigit().weight(.semibold))
                }
            }
            if let vm = store.vmUsage, vm.diskTotal > 0 {
                Text("VM disk: \(Format.bytes(vm.diskUsed)) / \(Format.bytes(vm.diskTotal))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ value: Int64, _ total: Int64) -> some View {
        GridRow {
            Text(title).font(.callout)
            Text(Format.bytes(value)).font(.callout.monospacedDigit())
            ProgressView(value: total > 0 ? Double(value) / Double(total) : 0).frame(width: 160)
        }
    }

    private func recommendations(_ r: StorageReport) -> some View {
        Card(title: String(localized: "Reclaimable"), systemImage: "sparkles") {
            recommendation(
                String(localized: "Build cache"), detail: String(localized: "\(Format.bytes(r.buildCacheReclaimable)) unused / \(Format.bytes(r.buildCacheTotal))"),
                action: String(localized: "Prune Build Cache…"), busyKey: "prune:build", enabled: r.buildCacheReclaimable > 0
            ) {
                if Confirm.destructive(String(localized: "Prune build cache?"), message: String(localized: "Removes unused build cache. The next build will be slower."), button: String(localized: "Prune")) { store.storageModel.pruneBuildCache() }
            }
            recommendation(
                String(localized: "Dangling images"), detail: String(localized: "\(r.danglingImages.count) image(s) · ~\(Format.bytes(r.danglingImagesSize))"),
                action: String(localized: "Prune Dangling…"), busyKey: "prune:images", enabled: !r.danglingImages.isEmpty
            ) {
                if Confirm.destructive(String(localized: "Prune dangling images?"), message: String(localized: "Removes \(r.danglingImages.count) untagged image(s)."), button: String(localized: "Prune")) { store.imagesModel.prune(all: false) }
            }
            recommendation(
                String(localized: "Stopped containers"), detail: String(localized: "\(r.stoppedContainers.count) container(s) · \(Format.bytes(r.stoppedContainersSize)) writable layer"),
                action: String(localized: "Remove Stopped Containers…"), busyKey: "prune:containers", enabled: !r.stoppedContainers.isEmpty
            ) {
                let names = r.stoppedContainers.prefix(10).map(\.name).joined(separator: ", ") + (r.stoppedContainers.count > 10 ? "…" : "")
                if Confirm.destructive(String(localized: "Remove \(r.stoppedContainers.count) stopped container(s)?"), message: String(localized: "\(names). Data in the containers' writable layers will be lost (volumes are kept)."), button: String(localized: "Remove")) {
                    store.storageModel.pruneStoppedContainers()
                }
            }
            Text("Image sizes are estimates: layers shared by several images are only freed when no image uses them anymore.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recommendation(_ title: String, detail: String, action: String, busyKey: String, enabled: Bool, perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.operations.busy.contains(busyKey) { ProgressView().controlSize(.small) }
            Button(action, action: perform).disabled(!enabled || store.operations.busy.contains(busyKey))
        }
    }

    private func volumes(_ r: StorageReport) -> some View {
        Card(title: String(localized: "Volumes Not Attached to Any Container (\(r.unusedVolumes.count) · \(Format.bytes(r.unusedVolumesSize)))"), systemImage: "externaldrive.badge.questionmark") {
            if r.unusedVolumes.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                Text("Volumes not used by any container (including stopped ones). They may still hold important data — back up before deleting.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(r.unusedVolumes) { item in
                    Toggle(isOn: Binding(
                        get: { selectedVolumes.contains(item.id) },
                        set: { if $0 { selectedVolumes.insert(item.id) } else { selectedVolumes.remove(item.id) } }
                    )) {
                        HStack {
                            Text(item.name.count > 40 ? String(item.name.prefix(12)) + "…" : item.name).help(item.name)
                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(Format.bytes(item.size)).font(.callout.monospacedDigit())
                        }
                    }
                }
                HStack {
                    Spacer()
                    if store.operations.busy.contains("remove:volumes") { ProgressView().controlSize(.small) }
                    Button("Delete \(selectedVolumes.count) Selected Volume(s)…", role: .destructive) { confirmRemoveVolumes(r) }
                        .disabled(selectedVolumes.isEmpty || store.operations.busy.contains("remove:volumes"))
                }
            }
        }
    }

    private func images(_ r: StorageReport) -> some View {
        Card(title: String(localized: "Tagged Images Not Used by Any Container (\(r.unusedImages.count) · ~\(Format.bytes(r.unusedImagesSize)))"), systemImage: "opticaldiscdrive") {
            if r.unusedImages.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(r.unusedImages.prefix(15)) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(Format.bytes(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if r.unusedImages.count > 15 { Text("… and \(r.unusedImages.count - 15) more image(s)").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Prune All Unused Images…") {
                        if Confirm.destructive(String(localized: "Prune all unused images?"), message: String(localized: "Removes \(r.unusedImages.count + r.danglingImages.count) image(s) not used by any container. They will have to be pulled again when needed."), button: String(localized: "Prune")) {
                            store.imagesModel.prune(all: true)
                        }
                    }
                    .disabled(store.operations.busy.contains("prune:images"))
                }
            }
        }
    }

    private func confirmRemoveVolumes(_ r: StorageReport) {
        let names = r.unusedVolumeNames(selected: selectedVolumes)
        guard !names.isEmpty else { return }
        let list = names.prefix(10).joined(separator: "\n") + (names.count > 10 ? "\n…" : "")
        if Confirm.destructive(String(localized: "Delete \(names.count) volume(s)?"), message: String(localized: "The data will be lost permanently:\n\(list)"), button: String(localized: "Delete")) {
            store.volumesModel.remove(names: names)
            selectedVolumes.removeAll()
        }
    }
}
