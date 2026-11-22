import Foundation

/// Network actions: create / delete / prune, connect and disconnect containers (G14).
@MainActor
final class NetworksModel {
    unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
    }

    private var operations: OperationCenter { context.operations }

    @discardableResult
    func create(name: String, driver: String, subnet: String?, gateway: String?, isInternal: Bool) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform("create:network") {
            try await client.createNetwork(name: name, driver: driver, subnet: subnet, gateway: gateway, isInternal: isInternal, labels: [:])
        }
    }

    @discardableResult
    func remove(_ network: DockerNetwork) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(network.id) { try await client.removeNetwork(network.id) }
    }

    @discardableResult
    func connect(_ container: DockerContainer, to network: DockerNetwork) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(network.id) { [operations] in
            try await client.connect(network: network.id, container: container.id)
            operations.flash(String(localized: "Connected \(container.name) to \(network.name)"))
        }
    }

    @discardableResult
    func disconnect(_ container: DockerContainer, from network: DockerNetwork) -> Task<Void, Never>? {
        let client = context.docker
        return operations.perform(network.id) { [operations] in
            try await client.disconnect(network: network.id, container: container.id)
            operations.flash(String(localized: "Disconnected \(container.name) from \(network.name)"))
        }
    }

    func prune() {
        let client = context.docker
        operations.perform("prune:networks") { [operations] in
            try await client.pruneNetworks(label: nil)
            operations.flash(String(localized: "Removed unused networks"))
        }
    }
}
