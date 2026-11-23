import Foundation

/// Status of the external tools ColimaX depends on (G26).
struct PrerequisiteReport: Equatable, Sendable {
    var brewPath: String?
    var colimaPath: String?
    var dockerPath: String?
    /// `docker compose version` succeeded.
    var composeAvailable: Bool
    /// Directory holding the Homebrew-installed `docker-compose` plugin (the docker CLI may not pick it up yet).
    var composePluginDirectory: String?

    var hasBrew: Bool { brewPath != nil }

    /// All tools needed for every screen to work are present.
    var isComplete: Bool { colimaPath != nil && dockerPath != nil && composeAvailable }

    /// Missing Homebrew formulae, in a fixed order.
    var missingFormulae: [String] {
        var list: [String] = []
        if colimaPath == nil { list.append("colima") }
        if dockerPath == nil { list.append("docker") }
        if !composeAvailable && composePluginDirectory == nil { list.append("docker-compose") }
        return list
    }

    /// The compose plugin and the docker CLI are installed, but `docker compose` does not work yet:
    /// the plugin directory must be added to the docker CLI's `cliPluginsExtraDirs`.
    var needsComposePluginConfig: Bool {
        dockerPath != nil && !composeAvailable && composePluginDirectory != nil
    }
}

enum PrerequisiteError: LocalizedError {
    case invalidDockerConfig

    var errorDescription: String? {
        switch self {
        case .invalidDockerConfig:
            String(localized: "The docker CLI config file is not a JSON object. Fix or remove it, then try again.")
        }
    }
}

/// Checks for and installs external tools via Homebrew.
/// Never installs Homebrew itself: its installer needs admin rights (sudo) and runs code downloaded
/// from the network, so the app only shows the command for the user to run in Terminal.
enum Prerequisites {
    /// The only formulae the app is allowed to install. `docker-credential-helper` replaces Docker
    /// Desktop's credential helper when switching to Colima (G27).
    static let allowedFormulae: [String] = ["colima", "docker", "docker-compose", "docker-credential-helper"]

    /// Official Homebrew install command (https://brew.sh).
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    static let homebrewURL = URL(string: "https://brew.sh")!

    static func check() async -> PrerequisiteReport {
        let brew = Shell.which("brew")
        let docker = Shell.which("docker")
        var compose = false
        if docker != nil, let result = try? await Shell.run("docker", ["compose", "version"], timeout: 15) {
            compose = result.ok
        }
        return PrerequisiteReport(
            brewPath: brew,
            colimaPath: Shell.which("colima"),
            dockerPath: docker,
            composeAvailable: compose,
            composePluginDirectory: composePluginDirectory(brewPath: brew)
        )
    }

    /// Homebrew prefixes: the one derived from the `brew` path (`<prefix>/bin/brew`), then the default prefixes.
    static func homebrewPrefixes(brewPath: String?) -> [String] {
        var prefixes: [String] = []
        if let brewPath {
            prefixes.append(URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path)
        }
        for fallback in ["/opt/homebrew", "/usr/local"] where !prefixes.contains(fallback) {
            prefixes.append(fallback)
        }
        return prefixes
    }

    static func composePluginDirectory(
        brewPath: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for prefix in homebrewPrefixes(brewPath: brewPath) {
            let directory = "\(prefix)/lib/docker/cli-plugins"
            if isExecutable("\(directory)/docker-compose") { return directory }
        }
        return nil
    }

    /// `brew install <formulae>`; only formulae listed in `allowedFormulae` are accepted.
    static func install(_ formulae: [String]) -> AsyncThrowingStream<String, Error> {
        Shell.stream("brew", installArguments(formulae), env: ["HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"])
    }

    /// Arguments for `brew`: drops unknown formulae and duplicates, keeping `allowedFormulae` order.
    static func installArguments(_ formulae: [String]) -> [String] {
        ["install"] + allowedFormulae.filter(formulae.contains)
    }

    // MARK: - Compose plugin

    /// The docker CLI config directory: `$DOCKER_CONFIG` (if absolute) or `~/.docker`.
    static var dockerConfigDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["DOCKER_CONFIG"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker", isDirectory: true)
    }

    /// Adds `directory` to `cliPluginsExtraDirs`, preserving all other keys. Pure, for testing.
    static func addingPluginDirectory(_ directory: String, to config: Data?) throws -> Data {
        try DockerConfigFile.editing(config) { object in
            var dirs = (object["cliPluginsExtraDirs"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !dirs.contains(directory) { dirs.append(directory) }
            object["cliPluginsExtraDirs"] = dirs
        }
    }

    /// Writes the compose plugin directory into the docker CLI config.
    /// Saves a copy of the previous file (`config.json.colimax-backup`) before overwriting it.
    static func configureComposePlugin(directory: String, configDirectory: URL = dockerConfigDirectory) throws {
        try DockerConfigFile.update(in: configDirectory) { try addingPluginDirectory(directory, to: $0) }
    }
}
