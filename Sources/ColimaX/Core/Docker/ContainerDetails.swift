import Foundation

/// The subset of `GET /containers/{id}/json` the GUI needs. Every field except `Id` and `Name`
/// is optional so decoding doesn't break when Docker adds / removes fields across API versions.
struct ContainerDetails: Decodable, Sendable {
    struct State: Decodable, Sendable {
        let status: String?
        let running: Bool?
        let paused: Bool?
        let restarting: Bool?
        let oomKilled: Bool?
        let dead: Bool?
        let pid: Int?
        let exitCode: Int?
        let error: String?
        let startedAt: String?
        let finishedAt: String?
        let health: Health?

        enum CodingKeys: String, CodingKey {
            case status = "Status", running = "Running", paused = "Paused", restarting = "Restarting"
            case oomKilled = "OOMKilled", dead = "Dead", pid = "Pid", exitCode = "ExitCode", error = "Error"
            case startedAt = "StartedAt", finishedAt = "FinishedAt", health = "Health"
        }
    }

    struct Health: Decodable, Sendable {
        struct Probe: Decodable, Sendable {
            let start: String?
            let exitCode: Int?
            let output: String?
            enum CodingKeys: String, CodingKey { case start = "Start", exitCode = "ExitCode", output = "Output" }
        }
        let status: String?
        let failingStreak: Int?
        let log: [Probe]?
        enum CodingKeys: String, CodingKey { case status = "Status", failingStreak = "FailingStreak", log = "Log" }
    }

    struct Config: Decodable, Sendable {
        let env: [String]?
        let user: String?
        let image: String?
        let cmd: [String]?
        let entrypoint: [String]?
        let workingDir: String?
        let labels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case env = "Env", user = "User", image = "Image", cmd = "Cmd", entrypoint = "Entrypoint"
            case workingDir = "WorkingDir", labels = "Labels"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            env = try c.decodeIfPresent([String].self, forKey: .env)
            user = try c.decodeIfPresent(String.self, forKey: .user)
            image = try c.decodeIfPresent(String.self, forKey: .image)
            cmd = Self.stringOrArray(c, .cmd)
            entrypoint = Self.stringOrArray(c, .entrypoint)
            workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        }

        /// Older APIs may return Cmd/Entrypoint as a single string.
        private static func stringOrArray(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String]? {
            if let array = try? c.decodeIfPresent([String].self, forKey: key) { return array }
            if let string = try? c.decodeIfPresent(String.self, forKey: key) { return [string] }
            return nil
        }
    }

    struct PortBinding: Decodable, Hashable, Sendable {
        let hostIp: String?
        let hostPort: String?
        enum CodingKeys: String, CodingKey { case hostIp = "HostIp", hostPort = "HostPort" }
    }

    struct RestartPolicy: Decodable, Sendable {
        let name: String?
        let maximumRetryCount: Int?
        enum CodingKeys: String, CodingKey { case name = "Name", maximumRetryCount = "MaximumRetryCount" }
    }

    struct HostConfig: Decodable, Sendable {
        let privileged: Bool?
        let capAdd: [String]?
        let capDrop: [String]?
        let networkMode: String?
        let pidMode: String?
        let ipcMode: String?
        let memory: Int64?
        let memoryReservation: Int64?
        let nanoCpus: Int64?
        let cpuShares: Int64?
        let cpuQuota: Int64?
        let cpuPeriod: Int64?
        let pidsLimit: Int64?
        let readonlyRootfs: Bool?
        let securityOpt: [String]?
        let restartPolicy: RestartPolicy?
        let portBindings: [String: [PortBinding]?]?
        let binds: [String]?

        enum CodingKeys: String, CodingKey {
            case privileged = "Privileged", capAdd = "CapAdd", capDrop = "CapDrop", networkMode = "NetworkMode"
            case pidMode = "PidMode", ipcMode = "IpcMode", memory = "Memory", memoryReservation = "MemoryReservation"
            case nanoCpus = "NanoCpus", cpuShares = "CpuShares", cpuQuota = "CpuQuota", cpuPeriod = "CpuPeriod"
            case pidsLimit = "PidsLimit", readonlyRootfs = "ReadonlyRootfs", securityOpt = "SecurityOpt"
            case restartPolicy = "RestartPolicy", portBindings = "PortBindings", binds = "Binds"
        }
    }

    struct Mount: Decodable, Hashable, Sendable {
        let type: String?
        let name: String?
        let source: String?
        let destination: String?
        let rw: Bool?
        enum CodingKeys: String, CodingKey { case type = "Type", name = "Name", source = "Source", destination = "Destination", rw = "RW" }
    }

    struct Endpoint: Decodable, Sendable {
        let ipAddress: String?
        let gateway: String?
        let macAddress: String?
        let aliases: [String]?
        enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress", gateway = "Gateway", macAddress = "MacAddress", aliases = "Aliases" }
    }

    struct NetworkSettings: Decodable, Sendable {
        let networks: [String: Endpoint]?
        let ports: [String: [PortBinding]?]?
        enum CodingKeys: String, CodingKey { case networks = "Networks", ports = "Ports" }
    }

    let id: String
    let name: String
    let created: String?
    let platform: String?
    let restartCount: Int?
    let state: State?
    let config: Config?
    let hostConfig: HostConfig?
    let mounts: [Mount]?
    let networkSettings: NetworkSettings?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", created = "Created", platform = "Platform", restartCount = "RestartCount"
        case state = "State", config = "Config", hostConfig = "HostConfig", mounts = "Mounts", networkSettings = "NetworkSettings"
    }

    // MARK: Derived

    var displayName: String { String(name.drop { $0 == "/" }) }
    var environment: [EnvVar] { (config?.env ?? []).map(EnvVar.init(raw:)) }
    var oomKilled: Bool { state?.oomKilled ?? false }
    var healthStatus: String? { state?.health?.status }

    /// Resource limits in readable form; nil = unlimited.
    var memoryLimit: Int64? { (hostConfig?.memory ?? 0) > 0 ? hostConfig?.memory : nil }
    var cpuLimit: Double? {
        if let nano = hostConfig?.nanoCpus, nano > 0 { return Double(nano) / 1_000_000_000 }
        if let quota = hostConfig?.cpuQuota, let period = hostConfig?.cpuPeriod, quota > 0, period > 0 {
            return Double(quota) / Double(period)
        }
        return nil
    }
    var pidsLimit: Int64? { (hostConfig?.pidsLimit ?? 0) > 0 ? hostConfig?.pidsLimit : nil }

    /// Declared host ports (available even when the container is stopped, unlike the `/containers/json` list).
    var declaredHostPorts: [(hostIP: String, port: Int, containerPort: String)] {
        var result: [(String, Int, String)] = []
        for (containerPort, bindings) in hostConfig?.portBindings ?? [:] {
            for binding in bindings ?? [] {
                guard let port = binding.hostPort.flatMap(Int.init), port > 0 else { continue }
                result.append((binding.hostIp ?? "", port, containerPort))
            }
        }
        return result.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
    }
}

/// An environment variable `KEY=VALUE`, with detection of sensitive values to mask in the UI.
struct EnvVar: Identifiable, Hashable, Sendable {
    let key: String
    let value: String

    var id: String { key }

    init(raw: String) {
        if let eq = raw.firstIndex(of: "=") {
            key = String(raw[..<eq])
            value = String(raw[raw.index(after: eq)...])
        } else {
            key = raw
            value = ""
        }
    }

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    var isSensitive: Bool { Self.isSensitive(key: key) }

    /// Masked value with a fixed length so the secret's length isn't revealed.
    var maskedValue: String { value.isEmpty ? "" : "••••••••" }

    private static let sensitiveFragments = [
        "PASSWORD", "PASSWD", "SECRET", "TOKEN", "APIKEY", "API_KEY", "PRIVATE_KEY",
        "ACCESS_KEY", "CREDENTIAL", "AUTH", "DSN", "CONNECTION_STRING",
    ]
    private static let sensitiveSuffixes = ["_PASS", "_PWD", "_KEY"]

    static func isSensitive(key: String) -> Bool {
        let upper = key.uppercased()
        if upper == "PWD" || upper == "OLDPWD" { return false } // shell working directory
        if upper.hasSuffix("_FILE") { return false } // path to a secret, not the secret itself
        return sensitiveFragments.contains { upper.contains($0) } || sensitiveSuffixes.contains { upper.hasSuffix($0) }
    }
}

/// `GET /images/{id}/json`: platform fields only.
struct ImagePlatform: Decodable, Equatable, Sendable {
    let id: String
    let architecture: String?
    let os: String?
    let variant: String?

    enum CodingKeys: String, CodingKey { case id = "Id", architecture = "Architecture", os = "Os", variant = "Variant" }

    var description: String {
        [os, architecture, variant].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "/")
    }

    /// Whether the image runs natively on Apple Silicon (arm64).
    var isNativeARM64: Bool { HostPlatform.normalize(architecture ?? "") == "arm64" }
}

enum HostPlatform {
    /// Normalizes architecture names between Docker (`arm64`/`amd64`) and Colima/Lima (`aarch64`/`x86_64`).
    static func normalize(_ arch: String) -> String {
        switch arch.lowercased() {
        case "aarch64", "arm64", "arm64/v8": "arm64"
        case "x86_64", "amd64", "x86-64": "amd64"
        default: arch.lowercased()
        }
    }

    /// Whether the Mac has Apple Silicon (even when the app runs under Rosetta).
    static var isAppleSilicon: Bool { sysctlInt("hw.optional.arm64") == 1 }

    /// Whether the app is running as x86_64 under Rosetta.
    static var isTranslated: Bool { sysctlInt("sysctl.proc_translated") == 1 }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

extension DockerContainer {
    /// Health parsed from the `/containers/json` Status string, e.g. "Up 2 minutes (healthy)".
    var health: String? {
        for value in ["unhealthy", "healthy", "health: starting"] where status.contains("(\(value))") {
            return value == "health: starting" ? "starting" : value
        }
        return nil
    }
}
