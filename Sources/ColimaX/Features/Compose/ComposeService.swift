import Foundation

/// A compose project, discovered from container labels or added manually by the user.
struct ComposeProject: Identifiable, Hashable, Codable, Sendable {
    let name: String
    var workingDir: String?
    var configFiles: [String]

    var id: String { name }
    var canRunUp: Bool { !configFiles.isEmpty }

    /// Project name per compose rules: lowercase letters, digits, `-`, `_`.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    static func defaultName(for directory: URL) -> String {
        let lowered = directory.lastPathComponent.lowercased()
        let cleaned = lowered.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return name.isEmpty ? "project" : name
    }
}

/// Runs `docker compose` via Process (argument array, no shell) with `DOCKER_HOST` pointing at the
/// given Colima profile's socket.
enum ComposeService {
    enum Command: String, CaseIterable, Sendable {
        case up, down, start, stop, restart, pull

        var arguments: [String] {
            switch self {
            case .up: ["up", "-d", "--remove-orphans"]
            case .down: ["down", "--remove-orphans"]
            case .start: ["start"]
            case .stop: ["stop"]
            case .restart: ["restart"]
            case .pull: ["pull"]
            }
        }

        var title: String {
            switch self {
            case .up: String(localized: "Up")
            case .down: String(localized: "Down")
            case .start: String(localized: "Start")
            case .stop: String(localized: "Stop")
            case .restart: String(localized: "Restart")
            case .pull: String(localized: "Pull")
            }
        }
    }

    /// Actions on a single service of a project.
    enum ServiceCommand: String, CaseIterable, Sendable {
        case start, stop, restart, rebuild

        func arguments(_ service: String) -> [String] {
            switch self {
            case .start: ["start", service]
            case .stop: ["stop", service]
            case .restart: ["restart", service]
            // Build and recreate only this service; leave its dependencies alone.
            case .rebuild: ["up", "-d", "--build", "--no-deps", "--force-recreate", service]
            }
        }

        var title: String {
            switch self {
            case .start: String(localized: "Start")
            case .stop: String(localized: "Stop")
            case .restart: String(localized: "Restart")
            case .rebuild: String(localized: "Rebuild")
            }
        }
    }

    static var isAvailable: Bool { Shell.which("docker") != nil }

    /// Validates a compose service name (from container labels) before passing it as a CLI argument.
    static func isValidServiceName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    static func baseArguments(_ project: ComposeProject) -> [String] {
        var args = ["compose", "--project-name", project.name]
        if let dir = project.workingDir { args += ["--project-directory", dir] }
        for file in project.configFiles { args += ["--file", file] }
        return args
    }

    static func environment(socketPath: String) -> [String: String] {
        ["DOCKER_HOST": "unix://\(socketPath)"]
    }

    /// Declared compose files that no longer exist on disk.
    static func missingFiles(_ project: ComposeProject) -> [String] {
        project.configFiles.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    static func run(_ command: Command, project: ComposeProject, socketPath: String) -> AsyncThrowingStream<String, Error> {
        stream(command.arguments, project: project, socketPath: socketPath)
    }

    static func run(_ command: ServiceCommand, service: String, project: ComposeProject, socketPath: String) -> AsyncThrowingStream<String, Error> {
        guard isValidServiceName(service) else {
            return AsyncThrowingStream { $0.finish(throwing: ShellError.failed(String(localized: "Invalid service name: \(service)"))) }
        }
        return stream(command.arguments(service), project: project, socketPath: socketPath)
    }

    /// `docker compose logs -f`; streams until cancelled.
    static func logs(project: ComposeProject, service: String?, tail: Int, socketPath: String) -> AsyncThrowingStream<String, Error> {
        var args = ["logs", "--follow", "--no-color", "--tail", String(max(0, tail))]
        if let service {
            guard isValidServiceName(service) else {
                return AsyncThrowingStream { $0.finish(throwing: ShellError.failed(String(localized: "Invalid service name: \(service)"))) }
            }
            args.append(service)
        }
        return stream(args, project: project, socketPath: socketPath)
    }

    /// `docker compose config`: the merged configuration with variables interpolated.
    static func config(project: ComposeProject, socketPath: String) async throws -> String {
        let result = try await Shell.run("docker", baseArguments(project) + ["config"], env: environment(socketPath: socketPath), timeout: 60)
        guard result.ok else { throw ShellError.failed(result.stderr.trimmed.isEmpty ? String(localized: "docker compose config failed") : result.stderr.trimmed) }
        return result.stdout
    }

    /// `docker compose config --quiet`: nil if valid, otherwise the error message (also reports missing files).
    static func validate(project: ComposeProject, socketPath: String) async throws -> String? {
        let missing = missingFiles(project)
        if !missing.isEmpty { return String(localized: "File not found: \(missing.joined(separator: ", "))") }
        let result = try await Shell.run("docker", baseArguments(project) + ["config", "--quiet"], env: environment(socketPath: socketPath), timeout: 60)
        return result.ok ? nil : (result.stderr.trimmed.isEmpty ? String(localized: "Invalid configuration (exit \(Format.digits(result.status)))") : result.stderr.trimmed)
    }

    /// `docker compose config --services`.
    static func services(project: ComposeProject, socketPath: String) async throws -> [String] {
        let result = try await Shell.run("docker", baseArguments(project) + ["config", "--services"], env: environment(socketPath: socketPath), timeout: 60)
        guard result.ok else { throw ShellError.failed(result.stderr.trimmed) }
        return result.stdout.lines.map(\.trimmed).filter(isValidServiceName).sorted()
    }

    private static func stream(_ arguments: [String], project: ComposeProject, socketPath: String) -> AsyncThrowingStream<String, Error> {
        let missing = missingFiles(project)
        guard missing.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: ShellError.failed(String(localized: "Compose file no longer exists: \(missing.joined(separator: ", "))"))) }
        }
        return Shell.stream("docker", baseArguments(project) + arguments, env: environment(socketPath: socketPath))
    }
}

/// Finds compose files in a directory using Docker Compose's lookup order.
/// Detection only: never starts the project.
enum ComposeDiscovery {
    static let primaryNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let overrideNames = ["compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml"]

    struct Result: Equatable, Sendable {
        let directory: URL
        let files: [URL]
        let envFile: URL?
    }

    static func scan(_ directory: URL) -> Result? {
        let fm = FileManager.default
        func existing(_ names: [String]) -> URL? {
            names.lazy.map { directory.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        }
        guard let primary = existing(primaryNames) else { return nil }
        var files = [primary]
        if let override = existing(overrideNames) { files.append(override) }
        let env = directory.appendingPathComponent(".env")
        return Result(directory: directory, files: files, envFile: fm.fileExists(atPath: env.path) ? env : nil)
    }
}
