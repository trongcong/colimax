import Foundation

/// Network-to-container graph data (G22). Pure and testable.
struct NetworkTopology: Equatable, Sendable {
    struct Edge: Hashable, Sendable {
        let network: String
        let container: String
    }

    struct ContainerNode: Hashable, Sendable {
        let id: String
        let name: String
        let group: String?
        let running: Bool
    }

    let networks: [String]
    let containers: [ContainerNode]
    let edges: Set<Edge>

    /// Built-in networks; hidden when no container uses them, to keep the graph compact.
    static let builtinNetworks: Set<String> = ["bridge", "host", "none"]

    static func build(containers: [DockerContainer], networks: [DockerNetwork], includeStopped: Bool) -> NetworkTopology {
        let chosen = containers.filter { includeStopped || $0.isRunning }
        var edges = Set<Edge>()
        for container in chosen {
            for network in container.networkNames { edges.insert(Edge(network: network, container: container.id)) }
        }
        let used = Set(edges.map(\.network))
        let names = Set(networks.map(\.name)).union(used)
            .filter { used.contains($0) || !builtinNetworks.contains($0) }
        let nodes = chosen
            .map { ContainerNode(id: $0.id, name: $0.name, group: $0.composeProject, running: $0.isRunning) }
            .sorted { ($0.group ?? "~", $0.name) < ($1.group ?? "~", $1.name) }
        return NetworkTopology(networks: names.sorted(), containers: nodes, edges: edges)
    }
}

/// The `depends_on` graph of a compose project, read from `docker compose config --format json`.
struct ComposeDependencyGraph: Equatable, Sendable {
    /// Service -> the services it depends on.
    let dependencies: [String: [String]]

    var services: [String] { dependencies.keys.sorted() }

    /// `depends_on` may be a list of names or an object `{service: {condition: ...}}`.
    static func parse(configJSON data: Data) throws -> ComposeDependencyGraph {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShellError.failed(String(localized: "Unexpected compose config output"))
        }
        let services = root["services"] as? [String: Any] ?? [:]
        var result: [String: [String]] = [:]
        for (name, value) in services {
            let service = value as? [String: Any] ?? [:]
            var deps: [String] = []
            if let list = service["depends_on"] as? [String] { deps = list }
            if let map = service["depends_on"] as? [String: Any] { deps = Array(map.keys) }
            result[name] = deps.filter { services[$0] != nil }.sorted()
        }
        return ComposeDependencyGraph(dependencies: result)
    }

    /// Level of each service: 0 = no dependencies; otherwise 1 + the highest level among its dependencies.
    /// Cycles (an invalid config) are broken by treating a back edge's target as level 0.
    func levels() -> [String: Int] {
        var memo: [String: Int] = [:]
        func level(_ service: String, _ visiting: Set<String>) -> Int {
            if let known = memo[service] { return known }
            if visiting.contains(service) { return 0 }
            let deps = dependencies[service] ?? []
            let value = deps.isEmpty ? 0 : 1 + (deps.map { level($0, visiting.union([service])) }.max() ?? 0)
            memo[service] = value
            return value
        }
        for service in services { _ = level(service, []) }
        return memo
    }

    /// Whether the dependencies contain a cycle (compose refuses to run such a project).
    var hasCycle: Bool {
        var state: [String: Int] = [:] // 1 = visiting, 2 = done
        func visit(_ node: String) -> Bool {
            if state[node] == 1 { return true }
            if state[node] == 2 { return false }
            state[node] = 1
            for dep in dependencies[node] ?? [] where visit(dep) { return true }
            state[node] = 2
            return false
        }
        return services.contains { visit($0) }
    }
}

extension ComposeService {
    static func dependencyGraph(project: ComposeProject, socketPath: String) async throws -> ComposeDependencyGraph {
        let result = try await Shell.run("docker", baseArguments(project) + ["config", "--format", "json"],
                                         env: environment(socketPath: socketPath), timeout: 60)
        guard result.ok else { throw ShellError.failed(result.stderr.trimmed.isEmpty ? String(localized: "docker compose config failed") : result.stderr.trimmed) }
        return try ComposeDependencyGraph.parse(configJSON: Data(result.stdout.utf8))
    }
}
