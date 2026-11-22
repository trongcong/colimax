import Foundation

/// Disk cleanup actions on the Storage screen (G13). Image and volume cleanup reuse `ImagesModel` /
/// `VolumesModel`.
@MainActor
final class StorageModel {
    unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }

    func pruneBuildCache() {
        let client = context.docker
        operations.perform("prune:build") { [context, operations] in
            let report = try await client.pruneBuildCache()
            operations.flash(String(localized: "Freed \(Format.bytes(report.spaceReclaimed ?? 0)) of build cache"))
            await context.refreshOverview()
        }
    }

    func pruneStoppedContainers() {
        let client = context.docker
        operations.perform("prune:containers") { [context, operations] in
            let report = try await client.pruneStoppedContainers()
            operations.flash(String(localized: "Removed stopped containers, freed \(Format.bytes(report.spaceReclaimed ?? 0))"))
            await context.refreshOverview()
        }
    }
}
