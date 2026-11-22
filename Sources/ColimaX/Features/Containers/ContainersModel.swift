import Foundation

/// Container actions, including database dump / restore from the container menu.
@MainActor
final class ContainersModel {
    unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }

    /// `action`: start, stop, restart, pause, unpause, kill.
    @discardableResult
    func perform(_ action: String, on container: DockerContainer) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(container.id) { try await client.containerAction(container.id, action) }
    }

    @discardableResult
    func remove(_ container: DockerContainer, volumes: Bool) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(container.id) { try await client.removeContainer(container.id, force: true, volumes: volumes) }
    }

    func backupDatabase(_ container: DockerContainer, engine: DatabaseEngine, to url: URL) {
        let client = context.docker
        operations.perform(container.id) { [operations] in
            let manifest = try await DatabaseBackup.backup(container: container, engine: engine, to: url, client: client)
            operations.flash(String(localized: "Dumped \(engine.title) from \(container.name) → \(url.lastPathComponent) (\(Format.bytes(manifest.size)))"))
        }
    }

    func restoreDatabase(_ container: DockerContainer, engine: DatabaseEngine, from url: URL) {
        let client = context.docker
        operations.perform(container.id) { [operations] in
            let outcome = try await DatabaseRestore.restore(file: url, into: container, engine: engine, client: client)
            if outcome.warnings.isEmpty {
                operations.flash(String(localized: "Restored \(url.lastPathComponent) → \(container.name)"))
            } else {
                let sample = outcome.warnings.prefix(3).joined(separator: "\n")
                operations.errorMessage = String(localized: "Restore into \(container.name) finished with \(outcome.warnings.count) error(s):\n\(sample)")
            }
        }
    }
}
