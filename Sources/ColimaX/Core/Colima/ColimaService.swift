import Foundation

struct ColimaProfile: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let status: String
    let arch: String?
    let cpus: Int?
    let memory: Int64?
    let disk: Int64?
    let runtime: String?
    let address: String?

    var id: String { name }
    var isRunning: Bool { status.lowercased() == "running" }

    var summary: String {
        var parts: [String] = []
        if let cpus { parts.append("\(cpus) CPU") }
        if let memory { parts.append(Format.bytes(memory)) }
        if let disk { parts.append(Format.bytes(disk) + " disk") }
        if let runtime { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }
}

/// Runtime configuration of a profile (the subset of colima.yaml the GUI can edit).
struct RuntimeConfig: Equatable, Sendable {
    var cpus = 2
    var memoryGiB = 2.0
    var diskGiB = 100
    var arch = "aarch64"
    var runtime = "docker"
    var vmType = "vz"
    var mountType = "virtiofs"
    var rosetta = false
    var kubernetes = false
    var nestedVirtualization = false

    static let archs = ["aarch64", "x86_64"]
    static let runtimes = ["docker", "containerd", "incus"]
    static let vmTypes = ["vz", "qemu", "krunkit"]
    static let mountTypes = ["virtiofs", "sshfs", "9p"]

    /// Whether any changed field can only be applied by recreating the VM (colima delete + start).
    func requiresRecreate(from old: RuntimeConfig) -> Bool {
        arch != old.arch || runtime != old.runtime || vmType != old.vmType
    }

    /// `colima start` arguments. Values are fixed options or numbers, not free-form text, and are passed as argv.
    var startArguments: [String] {
        var args = [
            "--cpus", String(cpus),
            "--memory", Format.decimal(memoryGiB),
            "--disk", String(diskGiB),
            "--arch", arch,
            "--runtime", runtime,
            "--vm-type", vmType,
            "--mount-type", mountType,
            "--kubernetes=\(kubernetes)",
            "--nested-virtualization=\(nestedVirtualization)",
        ]
        if vmType == "vz" { args.append("--vz-rosetta=\(rosetta)") }
        return args
    }
}

/// Output of `colima status --profile X --json` (fields verified against the colima 0.10 binary).
struct ColimaStatus: Decodable, Equatable, Sendable {
    let displayName: String?
    let driver: String?
    let arch: String?
    let runtime: String?
    let mountType: String?
    let dockerSocket: String?
    let containerdSocket: String?
    let ipAddress: String?
    let kubernetes: Bool?
    let cpu: Int?
    let memory: Int64?
    let disk: Int64?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name", driver, arch, runtime, mountType = "mount_type"
        case dockerSocket = "docker_socket", containerdSocket = "containerd_socket"
        case ipAddress = "ip_address", kubernetes, cpu, memory, disk
    }

    /// File path of the Docker socket (without the `unix://` prefix). Nil if it isn't a unix socket.
    var dockerSocketPath: String? { dockerSocket.flatMap(Self.unixPath(from:)) }

    static func unixPath(from uri: String) -> String? {
        let value = uri.trimmed
        if value.hasPrefix("unix://") {
            let path = String(value.dropFirst("unix://".count))
            return path.hasPrefix("/") ? path : nil
        }
        return value.hasPrefix("/") ? value : nil
    }
}

enum ColimaService {
    /// `colima list --json` prints one JSON object per profile per line (NDJSON).
    static func listProfiles() async throws -> [ColimaProfile] {
        let result = try await Shell.run("colima", ["list", "--json"], timeout: 30)
        guard result.ok else {
            throw ShellError.failed(ColimaLog.errorMessage(in: result.stderr.lines) ?? String(localized: "colima list failed"))
        }
        let decoder = JSONDecoder()
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(ColimaProfile.self, from: Data($0.utf8)) }
    }

    /// Detailed status of a running profile (actual Docker endpoint, driver, IP…).
    static func status(_ profile: String) async throws -> ColimaStatus {
        let result = try await Shell.run("colima", ["status", "--profile", profile, "--json"], timeout: 20)
        guard result.ok else {
            throw ShellError.failed(ColimaLog.errorMessage(in: result.stderr.lines) ?? String(localized: "colima status failed"))
        }
        return try JSONDecoder().decode(ColimaStatus.self, from: Data(result.stdout.utf8))
    }

    /// Docker socket for a profile: prefers the value colima reports, else the default convention.
    static func resolveDockerSocket(_ profile: String, status: ColimaStatus?) -> String {
        status?.dockerSocketPath ?? dockerSocket(profile)
    }

    // MARK: - Lifecycle (output is streamed to show progress)

    static func start(_ profile: String, config: RuntimeConfig? = nil) -> AsyncThrowingStream<String, Error> {
        Shell.stream("colima", ["start", "--profile", profile] + (config?.startArguments ?? []))
    }

    static func stop(_ profile: String, force: Bool = false) -> AsyncThrowingStream<String, Error> {
        Shell.stream("colima", ["stop", "--profile", profile] + (force ? ["--force"] : []))
    }

    static func restart(_ profile: String) -> AsyncThrowingStream<String, Error> {
        Shell.stream("colima", ["restart", "--profile", profile])
    }

    /// Deletes the VM. `deleteData` also removes the runtime's containers, images and volumes.
    static func delete(_ profile: String, deleteData: Bool) -> AsyncThrowingStream<String, Error> {
        Shell.stream("colima", ["delete", "--profile", profile, "--force"] + (deleteData ? ["--data"] : []))
    }

    // MARK: - Profile name

    /// Allows only characters safe for directory and Lima instance names (max 31 characters).
    static func isValidProfileName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$"#, options: .regularExpression) != nil
    }

    // MARK: - Paths

    static var colimaHome: URL {
        if let custom = ProcessInfo.processInfo.environment["COLIMA_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".colima")
    }

    static func profileDirectory(_ profile: String) -> URL {
        colimaHome.appendingPathComponent(profile)
    }

    /// Colima's default socket location; only a fallback when `colima status` reports no endpoint.
    static func dockerSocket(_ profile: String) -> String {
        profileDirectory(profile).appendingPathComponent("docker.sock").path
    }

    /// Lima's directory (`$COLIMA_HOME/_lima`). Instances live inside it as `colima` (default profile)
    /// or `colima-<profile>` (other profiles).
    static var limaDirectory: URL { colimaHome.appendingPathComponent("_lima") }

    // MARK: - Config

    /// Reads the keys the GUI needs from the profile's colima.yaml.
    static func readConfig(_ profile: String) -> RuntimeConfig? {
        let url = profileDirectory(profile).appendingPathComponent("colima.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseConfig(text)
    }

    /// Parses the needed keys from colima.yaml (pure, testable with fixtures). Handles the flat YAML colima
    /// generates: top-level keys plus one level of nesting (e.g. `kubernetes.enabled`).
    static func parseConfig(_ text: String) -> RuntimeConfig {
        var values: [String: String] = [:]
        var section: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmed.hasPrefix("#") || line.trimmed.isEmpty { continue }
            let indented = line.first == " "
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmed
            var value = line[line.index(after: colon)...].trimmed
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmed }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !indented {
                section = value.isEmpty ? key : nil
                values[key] = value
            } else if let section, line.hasPrefix("  "), !line.hasPrefix("   ") {
                values["\(section).\(key)"] = value
            }
        }

        var config = RuntimeConfig()
        if let v = values["cpu"].flatMap(Int.init) { config.cpus = v }
        if let v = values["memory"].flatMap(Double.init) { config.memoryGiB = v }
        if let v = values["disk"].flatMap(Int.init) { config.diskGiB = v }
        if let v = values["arch"], !v.isEmpty { config.arch = v }
        if let v = values["runtime"], !v.isEmpty { config.runtime = v }
        if let v = values["vmType"], !v.isEmpty { config.vmType = v }
        if let v = values["mountType"], !v.isEmpty { config.mountType = v }
        config.rosetta = values["rosetta"] == "true"
        config.kubernetes = values["kubernetes.enabled"] == "true"
        config.nestedVirtualization = values["nestedVirtualization"] == "true"
        return config
    }

    // MARK: - VM usage

    /// Reads actual resource usage inside the VM via `colima ssh`. The command is constant, with no user input.
    static func vmUsage(_ profile: String) async throws -> VMUsage {
        let script = "head -1 /proc/stat; echo ---; cat /proc/meminfo; echo ---; cat /proc/loadavg; echo ---; nproc; echo ---; df -kP /var/lib/docker 2>/dev/null || df -kP /"
        let result = try await Shell.run("colima", ["ssh", "--profile", profile, "--", "sh", "-c", script], timeout: 15)
        guard result.ok else {
            throw ShellError.failed(ColimaLog.errorMessage(in: result.stderr.lines) ?? String(localized: "colima ssh failed"))
        }
        return VMUsage.parse(result.stdout)
    }
}

struct VMUsage: Sendable {
    var cpuTotalTicks: UInt64 = 0
    var cpuIdleTicks: UInt64 = 0
    var memTotal: Int64 = 0
    var memAvailable: Int64 = 0
    var load1: Double = 0
    var cpuCount = 1
    var diskTotal: Int64 = 0
    var diskUsed: Int64 = 0

    var memUsed: Int64 { memTotal - memAvailable }

    /// CPU % between two /proc/stat readings.
    func cpuPercent(since previous: VMUsage?) -> Double? {
        guard let previous, cpuTotalTicks > previous.cpuTotalTicks else { return nil }
        let total = Double(cpuTotalTicks - previous.cpuTotalTicks)
        let idle = Double(cpuIdleTicks &- previous.cpuIdleTicks)
        return max(0, min(100, (1 - idle / total) * 100))
    }

    static func parse(_ text: String) -> VMUsage {
        var usage = VMUsage()
        let sections = text.components(separatedBy: "---\n")
        if let stat = sections.first {
            let fields = stat.split(separator: " ").dropFirst().compactMap { UInt64($0.trimmed) }
            usage.cpuTotalTicks = fields.reduce(0, +)
            // idle + iowait
            usage.cpuIdleTicks = (fields.count > 3 ? fields[3] : 0) + (fields.count > 4 ? fields[4] : 0)
        }
        if sections.count > 1 {
            for line in sections[1].split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let kb = Int64(parts[1]) else { continue }
                if parts[0] == "MemTotal:" { usage.memTotal = kb * 1024 }
                if parts[0] == "MemAvailable:" { usage.memAvailable = kb * 1024 }
            }
        }
        if sections.count > 2 {
            usage.load1 = Double(sections[2].split(separator: " ").first ?? "") ?? 0
        }
        if sections.count > 3 {
            usage.cpuCount = Int(sections[3].trimmed) ?? 1
        }
        if sections.count > 4 {
            let lines = sections[4].split(separator: "\n")
            if lines.count >= 2 {
                let cols = lines[1].split(separator: " ", omittingEmptySubsequences: true)
                if cols.count >= 3 {
                    usage.diskTotal = (Int64(cols[1]) ?? 0) * 1024
                    usage.diskUsed = (Int64(cols[2]) ?? 0) * 1024
                }
            }
        }
        return usage
    }
}

extension String {
    var lines: [String] { split(whereSeparator: \.isNewline).map(String.init) }
}
