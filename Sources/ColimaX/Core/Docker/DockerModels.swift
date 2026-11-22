import Foundation

// Models mapping the Docker Engine API (PascalCase) to camelCase via CodingKeys.
// `ContainerStats` is the exception: it keeps the API's snake_case field names.

struct DockerContainer: Decodable, Identifiable, Hashable, Sendable {
    struct Port: Decodable, Hashable, Sendable {
        let privatePort: Int
        let publicPort: Int?
        let ip: String?
        let type: String
        enum CodingKeys: String, CodingKey { case privatePort = "PrivatePort", publicPort = "PublicPort", ip = "IP", type = "Type" }
    }

    struct Mount: Decodable, Hashable, Sendable {
        let type: String?
        let name: String?
        let source: String?
        let destination: String?
        enum CodingKeys: String, CodingKey { case type = "Type", name = "Name", source = "Source", destination = "Destination" }
    }

    struct NetworkSettings: Decodable, Hashable, Sendable {
        let networks: [String: EndpointSettings]?
        enum CodingKeys: String, CodingKey { case networks = "Networks" }
    }

    struct EndpointSettings: Decodable, Hashable, Sendable {
        let ipAddress: String?
        enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress" }
    }

    let id: String
    let names: [String]
    let image: String
    let imageID: String?
    let command: String?
    let created: Int
    let state: String
    let status: String
    let ports: [Port]?
    let labels: [String: String]?
    let mounts: [Mount]?
    let networkSettings: NetworkSettings?

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", imageID = "ImageID", command = "Command"
        case created = "Created", state = "State", status = "Status", ports = "Ports", labels = "Labels"
        case mounts = "Mounts", networkSettings = "NetworkSettings"
    }

    var name: String { names.first.map { String($0.drop { $0 == "/" }) } ?? shortID }
    var shortID: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "running" }
    var isPaused: Bool { state == "paused" }
    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }

    var composeProject: String? { labels?["com.docker.compose.project"] }
    var composeService: String? { labels?["com.docker.compose.service"] }
    var composeWorkingDir: String? { labels?["com.docker.compose.project.working_dir"] }
    var composeConfigFiles: [String] {
        labels?["com.docker.compose.project.config_files"]?
            .split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty } ?? []
    }

    var publishedPorts: [Int] { Array(Set((ports ?? []).compactMap(\.publicPort))).sorted() }
    var portsDescription: String {
        let mapped = Set((ports ?? []).map { port in
            port.publicPort.map { "\($0)→\(port.privatePort)/\(port.type)" } ?? "\(port.privatePort)/\(port.type)"
        })
        return mapped.sorted().joined(separator: ", ")
    }
    var volumeNames: [String] { (mounts ?? []).filter { $0.type == "volume" }.compactMap(\.name) }
    var networkNames: [String] { Array(networkSettings?.networks?.keys ?? [:].keys).sorted() }
}

struct DockerImage: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?
    let created: Int
    let size: Int64
    /// Number of containers using the image (only in `/system/df`; `-1` = not computed).
    let containers: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id", repoTags = "RepoTags", repoDigests = "RepoDigests", created = "Created", size = "Size"
        case containers = "Containers"
    }

    var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    var tags: [String] { (repoTags ?? []).filter { $0 != "<none>:<none>" } }
    var displayName: String { tags.first ?? repoDigests?.first?.components(separatedBy: "@").first.map { "\($0)@<digest>" } ?? "<none>" }
    var isDangling: Bool { tags.isEmpty }
    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
}

struct DockerVolume: Decodable, Identifiable, Hashable, Sendable {
    struct UsageData: Decodable, Hashable, Sendable {
        let size: Int64
        let refCount: Int
        enum CodingKeys: String, CodingKey { case size = "Size", refCount = "RefCount" }
    }

    let name: String
    let driver: String
    let mountpoint: String
    let createdAt: String?
    let labels: [String: String]?
    let usageData: UsageData?

    enum CodingKeys: String, CodingKey {
        case name = "Name", driver = "Driver", mountpoint = "Mountpoint", createdAt = "CreatedAt"
        case labels = "Labels", usageData = "UsageData"
    }

    var id: String { name }
    var composeProject: String? { labels?["com.docker.compose.project"] }
    /// Automatically created volume (the name is a 64-character hex hash).
    var isAnonymous: Bool { name.count == 64 && name.allSatisfy(\.isHexDigit) }
}

struct VolumeList: Decodable, Sendable {
    let volumes: [DockerVolume]?
    enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
}

struct DockerNetwork: Decodable, Identifiable, Hashable, Sendable {
    struct IPAM: Decodable, Hashable, Sendable {
        struct Config: Decodable, Hashable, Sendable {
            let subnet: String?
            let gateway: String?
            enum CodingKeys: String, CodingKey { case subnet = "Subnet", gateway = "Gateway" }
        }
        let config: [Config]?
        enum CodingKeys: String, CodingKey { case config = "Config" }
    }

    let id: String
    let name: String
    let driver: String
    let scope: String
    let created: String?
    let `internal`: Bool?
    let ipam: IPAM?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", driver = "Driver", scope = "Scope", created = "Created"
        case `internal` = "Internal", ipam = "IPAM", labels = "Labels"
    }

    var shortID: String { String(id.prefix(12)) }
    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
    var subnets: String { (ipam?.config ?? []).compactMap(\.subnet).joined(separator: ", ") }
}

struct DockerInfo: Decodable, Sendable {
    let containers: Int
    let containersRunning: Int
    let containersPaused: Int
    let containersStopped: Int
    let images: Int
    let serverVersion: String
    let operatingSystem: String
    let kernelVersion: String
    let architecture: String
    let ncpu: Int
    let memTotal: Int64

    enum CodingKeys: String, CodingKey {
        case containers = "Containers", containersRunning = "ContainersRunning", containersPaused = "ContainersPaused"
        case containersStopped = "ContainersStopped", images = "Images", serverVersion = "ServerVersion"
        case operatingSystem = "OperatingSystem", kernelVersion = "KernelVersion", architecture = "Architecture"
        case ncpu = "NCPU", memTotal = "MemTotal"
    }
}

struct DiskUsage: Decodable, Sendable {
    struct ContainerUsage: Decodable, Sendable {
        let id: String?
        let names: [String]?
        let state: String?
        let sizeRw: Int64?
        enum CodingKeys: String, CodingKey { case id = "Id", names = "Names", state = "State", sizeRw = "SizeRw" }
    }
    struct BuildCache: Decodable, Sendable {
        let size: Int64
        let inUse: Bool?
        enum CodingKeys: String, CodingKey { case size = "Size", inUse = "InUse" }
    }

    let layersSize: Int64?
    let images: [DockerImage]?
    let containers: [ContainerUsage]?
    let volumes: [DockerVolume]?
    let buildCache: [BuildCache]?

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize", images = "Images", containers = "Containers", volumes = "Volumes", buildCache = "BuildCache"
    }

    var imagesSize: Int64 { layersSize ?? (images ?? []).reduce(0) { $0 + $1.size } }
    var containersSize: Int64 { (containers ?? []).reduce(0) { $0 + ($1.sizeRw ?? 0) } }
    var volumesSize: Int64 { (volumes ?? []).reduce(0) { $0 + max(0, $1.usageData?.size ?? 0) } }
    var buildCacheSize: Int64 { (buildCache ?? []).reduce(0) { $0 + $1.size } }
}

struct DockerEvent: Decodable, Sendable {
    struct Actor: Decodable, Sendable {
        let id: String?
        let attributes: [String: String]?
        enum CodingKeys: String, CodingKey { case id = "ID", attributes = "Attributes" }
    }

    let type: String
    let action: String
    let actor: Actor?

    enum CodingKeys: String, CodingKey { case type = "Type", action = "Action", actor = "Actor" }
}

struct PullProgress: Decodable, Sendable {
    let status: String?
    let id: String?
    let progress: String?
    let error: String?
}

struct PruneReport: Decodable, Sendable {
    let spaceReclaimed: Int64?
    enum CodingKeys: String, CodingKey { case spaceReclaimed = "SpaceReclaimed" }
}

struct ContainerStats: Decodable, Sendable {
    struct CPUStats: Decodable, Sendable {
        struct Usage: Decodable, Sendable { let total_usage: UInt64 }
        let cpu_usage: Usage
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }
    struct MemoryStats: Decodable, Sendable {
        let usage: Int64?
        let limit: Int64?
        let stats: [String: Int64]?
    }
    struct NetworkStats: Decodable, Sendable {
        let rx_bytes: Int64
        let tx_bytes: Int64
    }
    struct BlkioStats: Decodable, Sendable {
        struct Entry: Decodable, Sendable { let op: String; let value: Int64 }
        let io_service_bytes_recursive: [Entry]?
    }

    let cpu_stats: CPUStats
    let precpu_stats: CPUStats
    let memory_stats: MemoryStats
    let networks: [String: NetworkStats]?
    let blkio_stats: BlkioStats?

    /// Same formula as `docker stats`.
    var cpuPercent: Double {
        let cpuDelta = Double(cpu_stats.cpu_usage.total_usage) - Double(precpu_stats.cpu_usage.total_usage)
        let systemDelta = Double(cpu_stats.system_cpu_usage ?? 0) - Double(precpu_stats.system_cpu_usage ?? 0)
        guard cpuDelta > 0, systemDelta > 0 else { return 0 }
        return cpuDelta / systemDelta * Double(cpu_stats.online_cpus ?? 1) * 100
    }

    /// Actual memory in use = usage − page cache (cgroup v2: inactive_file; v1: total_inactive_file).
    var memoryUsed: Int64 {
        let usage = memory_stats.usage ?? 0
        let cache = memory_stats.stats?["inactive_file"] ?? memory_stats.stats?["total_inactive_file"] ?? 0
        return max(0, usage - cache)
    }
    var memoryLimit: Int64 { memory_stats.limit ?? 0 }
    var networkRx: Int64 { (networks ?? [:]).values.reduce(0) { $0 + $1.rx_bytes } }
    var networkTx: Int64 { (networks ?? [:]).values.reduce(0) { $0 + $1.tx_bytes } }
    var blockRead: Int64 { (blkio_stats?.io_service_bytes_recursive ?? []).filter { $0.op.lowercased() == "read" }.reduce(0) { $0 + $1.value } }
    var blockWrite: Int64 { (blkio_stats?.io_service_bytes_recursive ?? []).filter { $0.op.lowercased() == "write" }.reduce(0) { $0 + $1.value } }
}

/// Validates image references before pulling / passing them as CLI arguments (pure, unit-testable).
enum ImageReference {
    /// `nginx`, `nginx:1.27`, `ghcr.io/org/app:1.0`, `app@sha256:…` (max 512 characters). Rejects whitespace,
    /// shell characters, and strings starting with `-` (which a CLI would parse as an option).
    static func isValid(_ reference: String) -> Bool {
        reference.count <= 512
            && reference.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$"#, options: .regularExpression) != nil
    }
}
