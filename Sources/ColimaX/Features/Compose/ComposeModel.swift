import Foundation
import Observation

/// Compose projects (from container labels plus directories the user added) and their commands.
@MainActor
@Observable
final class ComposeModel {
    private static let defaultsKey = "composeProjects"

    /// Projects added from a directory; kept so they show up even when no container exists.
    var savedProjects: [ComposeProject] {
        didSet {
            if let data = try? JSONEncoder().encode(savedProjects) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    @ObservationIgnored unowned let context: any DockerContext

    init(context: any DockerContext) {
        self.context = context
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([ComposeProject].self, from: data) {
            savedProjects = saved
        } else {
            savedProjects = []
        }
    }

    /// Projects detected from container labels, merged with the saved ones, sorted by name.
    var projects: [ComposeProject] {
        Self.merge(containers: context.containers, saved: savedProjects)
    }

    static func merge(containers: [DockerContainer], saved: [ComposeProject]) -> [ComposeProject] {
        var result: [String: ComposeProject] = [:]
        for container in containers {
            guard let name = container.composeProject else { continue }
            var project = result[name] ?? ComposeProject(name: name, workingDir: nil, configFiles: [])
            if project.workingDir == nil { project.workingDir = container.composeWorkingDir }
            if project.configFiles.isEmpty { project.configFiles = container.composeConfigFiles }
            result[name] = project
        }
        for saved in saved {
            if var existing = result[saved.name] {
                if existing.configFiles.isEmpty { existing.configFiles = saved.configFiles }
                if existing.workingDir == nil { existing.workingDir = saved.workingDir }
                result[saved.name] = existing
            } else {
                result[saved.name] = saved
            }
        }
        return result.values.sorted { $0.name < $1.name }
    }

    func containers(in project: String) -> [DockerContainer] {
        context.containers.filter { $0.composeProject == project }.sorted { $0.name < $1.name }
    }

    func run(_ command: ComposeService.Command, _ project: ComposeProject) {
        let stream = ComposeService.run(command, project: project, socketPath: context.socketPath)
        let operations = context.operations
        operations.launch { await operations.runOperation("docker compose \(command.rawValue) — \(project.name)", stream) }
    }

    func run(_ command: ComposeService.ServiceCommand, service: String, _ project: ComposeProject) {
        let stream = ComposeService.run(command, service: service, project: project, socketPath: context.socketPath)
        let operations = context.operations
        operations.launch { await operations.runOperation("docker compose \(command.rawValue) \(service) — \(project.name)", stream) }
    }

    func add(_ project: ComposeProject) {
        savedProjects.removeAll { $0.name == project.name }
        savedProjects.append(project)
    }

    func forget(_ name: String) {
        savedProjects.removeAll { $0.name == name }
    }
}
