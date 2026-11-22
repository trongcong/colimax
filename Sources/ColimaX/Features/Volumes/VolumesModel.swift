import Foundation

/// Volume actions: create / delete / prune, `.tar` backup and restore with manifest verification.
@MainActor
final class VolumesModel {
    unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }

    @discardableResult
    func create(_ name: String) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform("create:volume") { try await client.createVolume(name: name, labels: [:]) }
    }

    @discardableResult
    func remove(_ volume: DockerVolume) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(volume.name) { try await client.removeVolume(volume.name, force: false) }
    }

    /// Deletes several volumes, reporting the ones that failed.
    @discardableResult
    func remove(names: [String]) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform("remove:volumes") { [context, operations] in
            var failed: [String] = []
            for name in names {
                do { try await client.removeVolume(name, force: false) } catch { failed.append("\(name): \(error.localizedDescription)") }
            }
            await context.refreshOverview()
            if failed.isEmpty {
                operations.flash(String(localized: "Deleted \(names.count) volume(s)"))
            } else {
                operations.errorMessage = String(localized: "Could not delete: \(failed.joined(separator: "; "))")
            }
        }
    }

    func prune(all: Bool) {
        let client = context.docker
        operations.perform("prune:volumes") { [context, operations] in
            let report = try await client.pruneVolumes(all: all, label: nil)
            operations.flash(String(localized: "Freed \(Format.bytes(report.spaceReclaimed ?? 0)) from volumes"))
            await context.refreshOverview()
        }
    }

    func backup(_ volume: DockerVolume, to url: URL) {
        let client = context.docker
        operations.perform(volume.name) { [operations] in
            let manifest = try await VolumeBackup.backup(volume: volume.name, to: url, client: client)
            operations.flash(String(localized: "Backed up \(volume.name) → \(url.lastPathComponent) (\(Format.bytes(manifest.size)), with SHA-256 manifest)"))
        }
    }

    func restore(_ name: String, from url: URL) {
        let client = context.docker
        operations.perform(name) { [context, operations] in
            let verification = try await VolumeBackup.restore(volume: name, from: url, client: client)
            if case .verified = verification {
                operations.flash(String(localized: "Restored \(url.lastPathComponent) → \(name) (manifest matched)"))
            } else {
                operations.flash(String(localized: "Restored \(url.lastPathComponent) → \(name) (no manifest)"))
            }
            await context.refreshOverview()
        }
    }

    /// Verifies a backup file's integrity (doesn't touch Docker).
    func verifyBackup(_ url: URL) {
        operations.perform("verify:\(url.path)") { [operations] in
            let result = try await BackupVerifier.verify(url)
            operations.flash(result.summary)
        }
    }
}
