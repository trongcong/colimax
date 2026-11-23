import AppKit
import Foundation

// Switching from OrbStack / Docker Desktop to Colima (G27): finds the other runtime, points the docker
// CLI context at the selected Colima profile (with undo), replaces Docker Desktop's credential store,
// moves aside broken CLI plugin links and offers to quit the other app. `/var/run/docker.sock` needs
// sudo, so it is only explained, never changed. Every change needs the user's confirmation.

/// A Docker runtime that is often installed next to Colima.
enum OtherDockerRuntime: String, CaseIterable, Sendable, Identifiable {
    case orbStack
    case dockerDesktop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orbStack: "OrbStack"
        case .dockerDesktop: "Docker Desktop"
        }
    }

    /// Main app bundle ID (source: the Homebrew casks `orbstack` / `docker-desktop`, `uninstall quit:`).
    var bundleIdentifier: String {
        switch self {
        case .orbStack: "dev.kdrag0n.MacVirt"
        case .dockerDesktop: "com.docker.docker"
        }
    }

    /// Every process to ask to quit; Docker Desktop also runs an Electron dashboard.
    var quitBundleIdentifiers: [String] {
        switch self {
        case .orbStack: ["dev.kdrag0n.MacVirt"]
        case .dockerDesktop: ["com.docker.docker", "com.electron.dockerdesktop"]
        }
    }

    /// Per-user CLI directories this runtime adds to the shell PATH (not to a GUI app's PATH):
    /// OrbStack `~/.orbstack/bin`, Docker Desktop `~/.docker/bin` (its default since 4.89).
    var userBinDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .orbStack: return "\(home)/.orbstack/bin"
        case .dockerDesktop: return "\(home)/.docker/bin"
        }
    }

    /// Docker Desktop resets the context to `desktop-linux` on every start (documented); OrbStack's
    /// docs only say its context "is automatically used".
    var resetsContextOnStart: Bool { self == .dockerDesktop }

    /// Path fragments of files this runtime owns: its socket, its app bundle, its CLI tools, and its
    /// group container / sandbox container (where a socket link may finally lead).
    var pathMarkers: [String] {
        switch self {
        case .orbStack: ["/.orbstack/", "/OrbStack.app/", ".dev.orbstack/"]
        case .dockerDesktop: ["/.docker/run/", "/Docker.app/", "/com.docker.docker/", "/group.com.docker/"]
        }
    }

    /// The runtime that owns a path (socket, binary, plugin), if any.
    static func owner(ofPath path: String?) -> OtherDockerRuntime? {
        guard let path else { return nil }
        return allCases.first { runtime in runtime.pathMarkers.contains { path.contains($0) } }
    }
}

struct InstalledRuntime: Equatable, Sendable, Identifiable {
    let runtime: OtherDockerRuntime
    let appPath: String
    var isRunning: Bool
    var id: String { runtime.id }
}

/// A docker CLI plugin in `<docker config>/cli-plugins` that is a symbolic link.
struct PluginLink: Equatable, Sendable {
    let path: String
    let destination: String
    let destinationExists: Bool
    var name: String { (path as NSString).lastPathComponent }
}

/// What this Mac's Docker setup looks like from the selected Colima profile's point of view.
/// Raw facts are gathered by `LiveRuntimeSwitcher.inspect`; everything else is derived, so tests
/// build reports directly.
struct RuntimeSwitchReport: Equatable, Sendable {
    var profile: String
    /// Docker socket of the selected profile (plain path).
    var profileSocket: String
    var installed: [InstalledRuntime] = []
    /// docker CLI path with symbolic links resolved; nil when the CLI is not installed.
    var dockerCLIPath: String?
    /// `currentContext` in the docker CLI config; nil means "default".
    var currentContextName: String?
    var contexts: [DockerContextInfo] = []
    var credsStore: String?
    /// Registries in `credHelpers` that use Docker Desktop's helper.
    var desktopCredHelperRegistries: [String] = []
    /// `docker-credential-osxkeychain` exists and does not belong to OrbStack / Docker Desktop (both
    /// ship one that disappears with the app).
    var keychainHelperInstalled: Bool = false
    var desktopHelperInstalled: Bool = false
    var plugins: [PluginLink] = []
    /// Where `/var/run/docker.sock` points (the link's own destination); nil when it does not exist.
    var defaultSocketTarget: String?

    static let defaultSocket = "/var/run/docker.sock"

    // MARK: Docker CLI context

    var currentContext: DockerContextInfo {
        let name = currentContextName ?? "default"
        if name == "default" { return DockerContextInfo(name: name, endpoint: "unix://\(Self.defaultSocket)") }
        return contexts.first { $0.name == name } ?? DockerContextInfo(name: name, endpoint: nil)
    }

    /// Socket the docker CLI really talks to (the "default" context follows `/var/run/docker.sock`).
    var currentContextSocket: String? {
        if (currentContextName ?? "default") == "default" { return defaultSocketTarget }
        return currentContext.endpoint.flatMap(ColimaStatus.unixPath(from:))
    }

    var currentContextTargetsProfile: Bool { currentContextSocket == profileSocket }

    var currentContextOwner: OtherDockerRuntime? { OtherDockerRuntime.owner(ofPath: currentContextSocket) }

    /// The context that points at the profile socket; Colima names it `colima` / `colima-<profile>`.
    var colimaContext: DockerContextInfo? {
        let matching = contexts.filter { $0.endpoint.flatMap(ColimaStatus.unixPath(from:)) == profileSocket }
        let conventional = profile == "default" ? "colima" : "colima-\(profile)"
        return matching.first { $0.name == conventional } ?? matching.first
    }

    var needsContextSwitch: Bool { dockerCLIPath != nil && !currentContextTargetsProfile && colimaContext != nil }

    /// The CLI points elsewhere and Colima has not created its context yet (the profile never ran).
    var colimaContextMissing: Bool { dockerCLIPath != nil && !currentContextTargetsProfile && colimaContext == nil }

    // MARK: Credentials, plugins, CLI

    var usesDesktopCredentials: Bool { credsStore == "desktop" || !desktopCredHelperRegistries.isEmpty }

    /// `docker login` / `pull` fail with "docker-credential-desktop not found".
    var credentialsBroken: Bool { usesDesktopCredentials && !desktopHelperInstalled }

    var brokenPlugins: [PluginLink] { plugins.filter { !$0.destinationExists } }

    var cliOwner: OtherDockerRuntime? { OtherDockerRuntime.owner(ofPath: dockerCLIPath) }

    // MARK: /var/run/docker.sock

    var defaultSocketTargetsProfile: Bool { defaultSocketTarget == profileSocket }
    var defaultSocketOwner: OtherDockerRuntime? { OtherDockerRuntime.owner(ofPath: defaultSocketTarget) }

    // MARK: Summary

    var runningRuntimes: [InstalledRuntime] { installed.filter(\.isRunning) }

    /// Something in this report is worth showing in the Setup Assistant.
    var isRelevant: Bool {
        !installed.isEmpty || needsContextSwitch || usesDesktopCredentials || !brokenPlugins.isEmpty
            || currentContextOwner != nil || defaultSocketOwner != nil || cliOwner != nil
    }

    /// Worth opening the Setup Assistant at launch: another runtime is installed or still wired in,
    /// and the docker CLI does not work with Colima yet.
    var needsAttention: Bool {
        guard !installed.isEmpty || currentContextOwner != nil || cliOwner != nil else { return false }
        return needsContextSwitch || credentialsBroken || !brokenPlugins.isEmpty
    }

    // MARK: Commands for the user (sudo / shell profile)

    var linkDefaultSocketCommand: String {
        "sudo ln -sf \(ShellQuote.single(profileSocket)) \(Self.defaultSocket)"
    }

    var dockerHostExport: String {
        "export DOCKER_HOST=\(ShellQuote.single("unix://" + profileSocket))"
    }
}

enum ShellQuote {
    /// Single-quotes a value for sh: ' → '\''
    static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Config edits (pure)

enum RuntimeSwitch {
    /// Sets `currentContext`; "default" removes the key, as `docker context use default` does.
    static func settingContext(_ name: String, in config: Data?) throws -> Data {
        try DockerConfigFile.editing(config) { object in
            if name == "default" { object.removeValue(forKey: "currentContext") } else { object["currentContext"] = name }
        }
    }

    /// Replaces Docker Desktop's credential helper (`desktop`) with the macOS Keychain helper (`osxkeychain`)
    /// in `credsStore` and `credHelpers`. Stored logins stay in the Keychain; other keys are kept.
    static func replacingDesktopCredentials(in config: Data?) throws -> Data {
        try DockerConfigFile.editing(config) { object in
            if object["credsStore"] as? String == "desktop" { object["credsStore"] = "osxkeychain" }
            if var helpers = object["credHelpers"] as? [String: Any] {
                for (registry, helper) in helpers where helper as? String == "desktop" { helpers[registry] = "osxkeychain" }
                object["credHelpers"] = helpers
            }
        }
    }

    /// Facts read from the docker CLI config (`config.json`).
    static func parseConfig(_ data: Data?) -> (currentContext: String?, credsStore: String?, desktopRegistries: [String]) {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, []) }
        let helpers = (object["credHelpers"] as? [String: Any]) ?? [:]
        let desktop = helpers.filter { $0.value as? String == "desktop" }.map(\.key).sorted()
        return (object["currentContext"] as? String, object["credsStore"] as? String, desktop)
    }
}

/// Reads and rewrites the docker CLI's `config.json`, keeping every key ColimaX does not touch.
enum DockerConfigFile {
    static let backupName = "config.json.colimax-backup"

    /// Applies `transform` to the JSON object in `config` (missing or blank = empty object). Pure, for testing.
    static func editing(_ config: Data?, _ transform: (inout [String: Any]) -> Void) throws -> Data {
        var object: [String: Any] = [:]
        if let config, !config.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else {
                throw PrerequisiteError.invalidDockerConfig
            }
            object = parsed
        }
        transform(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Rewrites `<directory>/config.json` atomically (0600). The previous file is saved as
    /// `config.json.colimax-backup` first.
    static func update(in directory: URL, _ edit: (Data?) throws -> Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configURL = directory.appendingPathComponent("config.json")
        let existing = fm.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : nil
        let updated = try edit(existing)
        if let existing {
            try AtomicFile.write(existing, to: directory.appendingPathComponent(backupName))
        }
        try AtomicFile.write(updated, to: configURL)
    }
}

// MARK: - Service

enum RuntimeSwitchError: LocalizedError {
    case unknownContext(String)

    var errorDescription: String? {
        switch self {
        case .unknownContext(let name):
            String(localized: "The docker context “\(name)” does not exist.")
        }
    }
}

/// Reads and changes the Docker setup on this Mac. Live: `LiveRuntimeSwitcher`; tests and UI fixtures use fakes.
protocol RuntimeSwitching: Sendable {
    /// nil when there is nothing to inspect (fakes without data).
    func inspect(profile: String, socketPath: String) async -> RuntimeSwitchReport?
    /// Makes `name` the docker CLI's current context.
    func useContext(_ name: String) async throws
    func replaceDesktopCredentials() async throws
    /// Moves plugin links out of `cli-plugins` into `colimax-backup/cli-plugins`; returns the new paths.
    func moveAside(plugins: [String]) async throws -> [String]
    /// Asks the app to quit; true when it exited within a few seconds.
    func quit(_ runtime: OtherDockerRuntime) async -> Bool
}

/// For services that never look at the real Mac (unit tests).
struct NoRuntimeSwitching: RuntimeSwitching {
    func inspect(profile: String, socketPath: String) async -> RuntimeSwitchReport? { nil }
    func useContext(_ name: String) async throws {}
    func replaceDesktopCredentials() async throws {}
    func moveAside(plugins: [String]) async throws -> [String] { [] }
    func quit(_ runtime: OtherDockerRuntime) async -> Bool { true }
}

struct LiveRuntimeSwitcher: RuntimeSwitching {
    /// nil: `Prerequisites.dockerConfigDirectory` (`$DOCKER_CONFIG` or `~/.docker`).
    var configDirectory: URL?

    private var directory: URL { configDirectory ?? Prerequisites.dockerConfigDirectory }

    func inspect(profile: String, socketPath: String) async -> RuntimeSwitchReport? {
        let directory = directory
        let installed = await MainActor.run { Self.installedRuntimes() }
        return try? await BlockingIO.run {
            let config = RuntimeSwitch.parseConfig(try? Data(contentsOf: directory.appendingPathComponent("config.json")))
            return RuntimeSwitchReport(
                profile: profile,
                profileSocket: socketPath,
                installed: installed,
                dockerCLIPath: Self.findTool("docker").map(Self.resolved),
                currentContextName: config.currentContext,
                contexts: DockerContextReader.all(dockerConfigDir: directory),
                credsStore: config.credsStore,
                desktopCredHelperRegistries: config.desktopRegistries,
                keychainHelperInstalled: Self.findTool("docker-credential-osxkeychain")
                    .map { OtherDockerRuntime.owner(ofPath: Self.resolved($0)) == nil } ?? false,
                desktopHelperInstalled: Self.findTool("docker-credential-desktop") != nil,
                plugins: Self.pluginLinks(in: directory.appendingPathComponent("cli-plugins")),
                defaultSocketTarget: Self.socketTarget(RuntimeSwitchReport.defaultSocket)
            )
        }
    }

    func useContext(_ name: String) async throws {
        let directory = directory
        try await BlockingIO.run {
            if name != "default", !DockerContextReader.all(dockerConfigDir: directory).contains(where: { $0.name == name }) {
                throw RuntimeSwitchError.unknownContext(name)
            }
            try DockerConfigFile.update(in: directory) { try RuntimeSwitch.settingContext(name, in: $0) }
        }
    }

    func replaceDesktopCredentials() async throws {
        let directory = directory
        try await BlockingIO.run {
            try DockerConfigFile.update(in: directory) { try RuntimeSwitch.replacingDesktopCredentials(in: $0) }
        }
    }

    func moveAside(plugins: [String]) async throws -> [String] {
        let directory = directory
        return try await BlockingIO.run {
            let fm = FileManager.default
            let pluginDirectory = directory.appendingPathComponent("cli-plugins").standardizedFileURL.path
            let backup = directory.appendingPathComponent("colimax-backup/cli-plugins", isDirectory: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var moved: [String] = []
            for path in plugins {
                let source = URL(fileURLWithPath: path).standardizedFileURL
                // Only links directly inside cli-plugins that are still dangling (fileExists follows the link).
                guard source.deletingLastPathComponent().path == pluginDirectory,
                      (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil,
                      !fm.fileExists(atPath: source.path) else { continue }
                var target = backup.appendingPathComponent(source.lastPathComponent)
                if (try? fm.attributesOfItem(atPath: target.path)) != nil {
                    target = backup.appendingPathComponent("\(source.lastPathComponent)-\(UUID().uuidString.prefix(8))")
                }
                try fm.moveItem(at: source, to: target)
                moved.append(target.path)
            }
            return moved
        }
    }

    func quit(_ runtime: OtherDockerRuntime) async -> Bool {
        let ids = runtime.quitBundleIdentifiers
        let apps = await MainActor.run {
            let apps = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            for app in apps { app.terminate() }
            return apps.count
        }
        guard apps > 0 else { return true }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            let running = await MainActor.run {
                ids.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
            }
            if !running { return true }
        }
        return false
    }

    // MARK: Helpers

    @MainActor
    private static func installedRuntimes() -> [InstalledRuntime] {
        OtherDockerRuntime.allCases.compactMap { runtime in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: runtime.bundleIdentifier) else { return nil }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: runtime.bundleIdentifier).isEmpty
            return InstalledRuntime(runtime: runtime, appPath: url.path, isRunning: running)
        }
    }

    /// A tool on the app's search path, else in OrbStack's / Docker Desktop's per-user bin directory:
    /// a GUI app does not inherit the shell PATH, where those directories are added.
    static func findTool(_ name: String, extraDirectories: [String] = OtherDockerRuntime.allCases.map(\.userBinDirectory)) -> String? {
        if let path = Shell.which(name) { return path }
        return extraDirectories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Path with every symbolic link resolved (the path itself when it is not a link).
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Where a socket path points: the link's own destination, not resolved further (OrbStack's and
    /// Docker Desktop's sockets may themselves be links into their containers, which would hide the
    /// `~/.orbstack` / `~/.docker/run` path and break the comparison with the profile socket); kept even
    /// when it no longer exists (the other runtime quit). The path itself for a real file; nil when absent.
    static func socketTarget(_ path: String) -> String? {
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: path) {
            return destination.hasPrefix("/") ? destination : (path as NSString).deletingLastPathComponent + "/" + destination
        }
        return fm.fileExists(atPath: path) ? path : nil
    }

    static func pluginLinks(in directory: URL) -> [PluginLink] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("docker-") }.sorted()
        return names.compactMap { name in
            let path = directory.appendingPathComponent(name).path
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: path) else { return nil }
            let absolute = destination.hasPrefix("/") ? destination : directory.appendingPathComponent(destination).path
            return PluginLink(path: path, destination: absolute, destinationExists: fm.fileExists(atPath: absolute))
        }
    }
}
