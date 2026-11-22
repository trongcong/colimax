import Darwin
import Foundation

/// A single check result. Read-only: checks never change configuration.
struct DiagnosticItem: Identifiable, Hashable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case ok, info, warning, critical
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum Category: String, CaseIterable, Sendable {
        case runtime = "Runtime"
        case appleSilicon = "Apple Silicon"
        case security = "Security"
        case ports = "Port"

        var title: String {
            switch self {
            case .runtime: String(localized: "Runtime")
            case .appleSilicon: String(localized: "Apple Silicon")
            case .security: String(localized: "Security")
            case .ports: String(localized: "Ports")
            }
        }
    }

    let category: Category
    let severity: Severity
    let title: String
    let detail: String
    var recommendation: String?
    /// Related container, used to open its details.
    var containerID: String?

    var id: String { "\(category.rawValue)|\(title)|\(containerID ?? "")|\(detail)" }

    /// Items shown on the Diagnostics screen: optional group filter, optionally without OK items,
    /// most severe first (then by title).
    static func visible(_ items: [DiagnosticItem], category: Category?, hideOK: Bool) -> [DiagnosticItem] {
        items
            .filter { category == nil || $0.category == category }
            .filter { !hideOK || $0.severity != .ok }
            .sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }
}

// MARK: - Runtime

/// Inputs for the runtime checks, gathered up front so the checks themselves stay pure.
struct RuntimeSnapshot: Sendable {
    var colimaPath: String?
    var dockerCLIPath: String?
    var profile: ColimaProfile?
    var config: RuntimeConfig?
    var status: ColimaStatus?
    var socketPath: String
    var socketPermissions: SocketPermissions?
    var pingError: String?
    var dockerContext: DockerContextInfo?
    var hostCPUs: Int
    var hostMemory: Int64
    var hostIsAppleSilicon: Bool
    var appTranslated: Bool
    var vmDiskUsedFraction: Double?
}

struct SocketPermissions: Equatable, Sendable {
    let mode: UInt16
    let ownerUID: UInt32

    static func read(_ path: String) -> SocketPermissions? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketPermissions(mode: UInt16(info.st_mode) & 0o777, ownerUID: info.st_uid)
    }

    var octal: String { String(mode, radix: 8) }
    var accessibleByOthers: Bool { mode & 0o077 != 0 }
}

enum RuntimeDiagnostics {
    static func check(_ s: RuntimeSnapshot, currentUID: UInt32 = getuid()) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        func add(_ severity: DiagnosticItem.Severity, _ title: String, _ detail: String, _ fix: String? = nil, _ category: DiagnosticItem.Category = .runtime) {
            items.append(DiagnosticItem(category: category, severity: severity, title: title, detail: detail, recommendation: fix))
        }

        // CLI
        if let path = s.colimaPath { add(.ok, "colima CLI", path) } else {
            add(.critical, String(localized: "colima not found"), String(localized: "The app needs `colima` to manage the VM."), "brew install colima")
        }
        if let path = s.dockerCLIPath { add(.ok, "docker CLI", path) } else {
            add(.warning, String(localized: "docker CLI not found"), String(localized: "Compose and the Terminal shell need the docker CLI. The other screens use the Docker API directly."), "brew install docker docker-compose")
        }

        guard let profile = s.profile else {
            add(.warning, String(localized: "No profile"), String(localized: "There is no Colima profile yet."), String(localized: "Create a profile in Runtime Settings."))
            return items
        }

        // Endpoint
        if profile.isRunning {
            if let socket = s.status?.dockerSocketPath {
                add(.ok, "Docker endpoint", String(localized: "unix://\(socket) (from `colima status`)"))
            } else if profile.runtime == "docker" {
                add(.info, "Docker endpoint", String(localized: "`colima status` returned no socket; using the default unix://\(s.socketPath)"))
            }
            if let error = s.pingError {
                add(.critical, String(localized: "Docker daemon not responding"), error, String(localized: "Try restarting the VM. If it still fails, check `colima status` and the logs in ~/.colima/_lima."))
            } else if profile.runtime == "docker" {
                add(.ok, "Docker daemon", "/_ping OK")
            }
        } else {
            add(.info, String(localized: "VM not running"), String(localized: "Profile \(profile.name): \(profile.status)"))
        }

        // Socket permissions
        if let perm = s.socketPermissions {
            if perm.ownerUID != currentUID {
                add(.warning, String(localized: "Socket owned by another user"), String(localized: "\(s.socketPath) is owned by uid \(Format.digits(perm.ownerUID))."), nil, .security)
            } else if perm.accessibleByOthers {
                add(.warning, String(localized: "Socket open to group/others"), String(localized: "Permissions \(perm.octal) on \(s.socketPath). Anyone who can read/write the Docker socket has root-equivalent access in the VM."),
                    String(localized: "Permissions should be 600 (owner only). The app does not change them."), .security)
            } else {
                add(.ok, String(localized: "Docker socket permissions"), String(localized: "\(perm.octal), current user only"), nil, .security)
            }
        }

        // docker CLI context
        if let context = s.dockerContext, let endpoint = context.endpoint, profile.isRunning {
            let target = ColimaStatus.unixPath(from: endpoint)
            if target == s.socketPath {
                add(.ok, "docker context", String(localized: "“\(context.name)” points to the selected profile"))
            } else {
                add(.info, String(localized: "docker context differs from profile"), String(localized: "The CLI uses context “\(context.name)” (\(endpoint)). `docker` commands in the terminal will not run on profile \(profile.name)."),
                    String(localized: "ColimaX uses its own DOCKER_HOST, so it is not affected. To switch the CLI: `docker context use colima` (or colima-\(profile.name))."))
            }
        }

        // Config drift
        if let config = s.config {
            items += drift(config: config, profile: profile)
            items += resources(config: config, hostCPUs: s.hostCPUs, hostMemory: s.hostMemory)
            items += virtualization(config: config, isAppleSilicon: s.hostIsAppleSilicon, status: s.status)
        }

        if let used = s.vmDiskUsedFraction, used >= 0.85 {
            add(.warning, String(localized: "VM disk almost full"), String(localized: "\(Format.percent(used * 100)) of the VM disk is used."), String(localized: "Clean up in the Storage screen or increase the disk in Runtime Settings (the disk can only grow)."))
        }

        if s.appTranslated {
            add(.warning, String(localized: "ColimaX is running under Rosetta"), String(localized: "x86_64 app build on an Apple Silicon Mac."), String(localized: "Use the arm64 build."), .appleSilicon)
        }
        return items
    }

    /// Reports when colima.yaml (desired state) differs from the running VM, which needs a restart to apply.
    static func drift(config: RuntimeConfig, profile: ColimaProfile) -> [DiagnosticItem] {
        guard profile.isRunning else { return [] }
        var diffs: [String] = []
        let gib: Double = 1_073_741_824
        if let cpus = profile.cpus, cpus != config.cpus { diffs.append("CPU \(cpus) → \(config.cpus)") }
        if let memory = profile.memory, abs(Double(memory) / gib - config.memoryGiB) >= 0.5 {
            diffs.append("RAM \(Format.decimal((Double(memory) / gib).rounded())) → \(Format.decimal(config.memoryGiB)) GiB")
        }
        if let disk = profile.disk, abs(Double(disk) / gib - Double(config.diskGiB)) >= 1 {
            diffs.append("Disk \(Int((Double(disk) / gib).rounded())) → \(config.diskGiB) GiB")
        }
        if let arch = profile.arch, HostPlatform.normalize(arch) != HostPlatform.normalize(config.arch) {
            diffs.append("Arch \(arch) → \(config.arch)")
        }
        if let runtime = profile.runtime, runtime != config.runtime { diffs.append("Runtime \(runtime) → \(config.runtime)") }
        guard !diffs.isEmpty else {
            return [DiagnosticItem(category: .runtime, severity: .ok, title: String(localized: "Configuration matches"), detail: String(localized: "The VM is running exactly as configured in colima.yaml"))]
        }
        return [DiagnosticItem(
            category: .runtime, severity: .info, title: "Config drift",
            detail: String(localized: "colima.yaml differs from the running VM: \(diffs.joined(separator: ", "))"),
            recommendation: String(localized: "Restart the VM to apply (changing arch/runtime requires recreating the VM).")
        )]
    }

    static func resources(config: RuntimeConfig, hostCPUs: Int, hostMemory: Int64) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        let hostGiB = Double(hostMemory) / 1_073_741_824
        if hostGiB > 0, config.memoryGiB > hostGiB * 0.75 {
            items.append(DiagnosticItem(
                category: .runtime, severity: .warning, title: String(localized: "VM memory too large"),
                detail: String(localized: "The VM is allocated \(Format.decimal(config.memoryGiB)) GiB of the Mac's \(Int(hostGiB)) GiB (> 75%)."),
                recommendation: String(localized: "macOS may start swapping. Consider reducing the VM memory.")
            ))
        }
        if hostCPUs > 1, config.cpus >= hostCPUs {
            items.append(DiagnosticItem(
                category: .runtime, severity: .info, title: String(localized: "VM uses all CPUs"),
                detail: String(localized: "\(config.cpus) / \(hostCPUs) cores."),
                recommendation: String(localized: "Leave at least 1–2 cores for macOS if things feel sluggish.")
            ))
        }
        return items
    }

    static func virtualization(config: RuntimeConfig, isAppleSilicon: Bool, status: ColimaStatus?) -> [DiagnosticItem] {
        guard isAppleSilicon else { return [] }
        var items: [DiagnosticItem] = []
        if config.vmType == "qemu" {
            items.append(DiagnosticItem(
                category: .appleSilicon, severity: .info, title: "VM type qemu",
                detail: String(localized: "On Apple Silicon, vz uses Apple Virtualization.framework and supports virtiofs + Rosetta."),
                recommendation: String(localized: "Consider vmType vz (requires recreating the VM).")
            ))
        }
        if config.vmType == "vz", config.mountType != "virtiofs" {
            items.append(DiagnosticItem(
                category: .appleSilicon, severity: .info, title: String(localized: "Mount \(config.mountType) with vz"),
                detail: String(localized: "With vz, virtiofs is the native mount type of Virtualization.framework."),
                recommendation: String(localized: "Consider mountType virtiofs.")
            ))
        }
        if HostPlatform.normalize(config.arch) == "amd64" {
            items.append(DiagnosticItem(
                category: .appleSilicon, severity: .warning, title: String(localized: "x86_64 VM on Apple Silicon"),
                detail: String(localized: "The whole VM runs under emulation."),
                recommendation: String(localized: "Use an aarch64 VM + Rosetta (vz) to run only the amd64 images that need it.")
            ))
        } else {
            items.append(DiagnosticItem(
                category: .appleSilicon, severity: .ok, title: String(localized: "Native arm64 VM"),
                detail: config.rosetta
                    ? String(localized: "vmType \(config.vmType), mount \(status?.mountType ?? config.mountType), Rosetta on")
                    : String(localized: "vmType \(config.vmType), mount \(status?.mountType ?? config.mountType), Rosetta off")
            ))
        }
        return items
    }
}

// MARK: - Apple Silicon: image

enum ImageArchDiagnostics {
    /// Flags non-arm64 images on an arm64 VM, which run under emulation.
    static func check(
        images: [DockerImage],
        platforms: [String: ImagePlatform],
        containers: [DockerContainer],
        rosettaEnabled: Bool,
        vmArch: String
    ) -> [DiagnosticItem] {
        guard HostPlatform.normalize(vmArch) == "arm64" else { return [] }
        var items: [DiagnosticItem] = []
        let emulator = rosettaEnabled ? "Rosetta" : "QEMU (binfmt)"
        for container in containers {
            guard let imageID = container.imageID, let platform = platforms[imageID],
                  let arch = platform.architecture, !platform.isNativeARM64 else { continue }
            items.append(DiagnosticItem(
                category: .appleSilicon,
                severity: container.isRunning ? .warning : .info,
                title: "\(container.name): image \(arch)",
                detail: String(localized: "\(container.image) is \(platform.description), running via \(emulator) on an arm64 VM."),
                recommendation: rosettaEnabled
                    ? String(localized: "Use a tag/manifest with linux/arm64 if the image supports it (e.g. `--platform linux/arm64`).")
                    : String(localized: "Use a tag/manifest with linux/arm64 if the image supports it (e.g. `--platform linux/arm64`). If amd64 is required, enable Rosetta (vz); it is faster than QEMU."),
                containerID: container.id
            ))
        }
        let usedIDs = Set(containers.compactMap(\.imageID))
        let unusedForeign = images.filter { image in
            guard !usedIDs.contains(image.id), let p = platforms[image.id], p.architecture != nil else { return false }
            return !p.isNativeARM64
        }
        if !unusedForeign.isEmpty {
            items.append(DiagnosticItem(
                category: .appleSilicon, severity: .info, title: String(localized: "Non-arm64 images: \(unusedForeign.count)"),
                detail: unusedForeign.prefix(5).map(\.displayName).joined(separator: ", ") + (unusedForeign.count > 5 ? "…" : ""),
                recommendation: String(localized: "Check the Arch column in the Images screen.")
            ))
        }
        return items
    }
}

// MARK: - Security

enum SecurityAudit {
    static let dangerousCapabilities: Set<String> = [
        "ALL", "SYS_ADMIN", "SYS_MODULE", "SYS_PTRACE", "SYS_RAWIO", "SYS_BOOT", "NET_ADMIN",
        "DAC_READ_SEARCH", "SYS_TIME", "MAC_ADMIN", "BPF", "PERFMON",
    ]

    /// `vmReachableFromNetwork`: the profile has its own IP (colima `--network-address`), so ports bound
    /// to 0.0.0.0 in the VM are reachable from the outside network, not just the Mac's localhost.
    static func check(_ details: [ContainerDetails], vmReachableFromNetwork: Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        for c in details {
            let name = c.displayName
            func add(_ severity: DiagnosticItem.Severity, _ title: String, _ detail: String, _ fix: String?) {
                items.append(DiagnosticItem(category: .security, severity: severity, title: "\(name): \(title)", detail: detail, recommendation: fix, containerID: c.id))
            }
            let host = c.hostConfig
            if host?.privileged == true {
                add(.critical, "privileged", String(localized: "The container has full access to the VM kernel."), String(localized: "Remove `privileged: true` and add only the capabilities you really need."))
            }
            let caps = Set((host?.capAdd ?? []).map { $0.uppercased().replacingOccurrences(of: "CAP_", with: "") })
            let risky = caps.intersection(dangerousCapabilities).sorted()
            if !risky.isEmpty {
                add(.warning, String(localized: "dangerous capability"), "cap_add: " + risky.joined(separator: ", "), String(localized: "Narrow the cap_add list."))
            }
            for mount in c.mounts ?? [] where (mount.source ?? "").hasSuffix("docker.sock") {
                add(.critical, String(localized: "Docker socket mounted"), String(localized: "\(mount.source ?? "") → \(mount.destination ?? ""). The container can control all of Docker (root-equivalent)."), String(localized: "Mount it only when really needed (e.g. Traefik); prefer a read-only proxy."))
            }
            if host?.networkMode == "host" {
                add(.warning, "network host", String(localized: "Shares the network namespace with the VM."), String(localized: "Use a bridge network and publish ports."))
            }
            if host?.pidMode == "host" { add(.warning, "pid host", String(localized: "Can see and affect every process in the VM."), nil) }
            if host?.ipcMode == "host" { add(.warning, "ipc host", String(localized: "Shares the IPC namespace with the VM."), nil) }
            for opt in host?.securityOpt ?? [] where opt.contains("unconfined") {
                add(.warning, String(localized: "protection disabled"), "security_opt: \(opt)", String(localized: "Remove seccomp/apparmor unconfined if not needed."))
            }
            let openPorts = c.declaredHostPorts.filter { $0.hostIP.isEmpty || $0.hostIP == "0.0.0.0" || $0.hostIP == "::" }
            if !openPorts.isEmpty {
                let list = openPorts.map { "\($0.port)→\($0.containerPort)" }.joined(separator: ", ")
                if vmReachableFromNetwork {
                    add(.warning, String(localized: "port open on all interfaces"), String(localized: "\(list) bind 0.0.0.0 and the VM has its own IP: reachable from the outside network."), String(localized: "Bind 127.0.0.1:PORT if only used locally."))
                } else {
                    add(.info, "port bind 0.0.0.0", String(localized: "\(list). Colima forwards them to the Mac's localhost by default."), String(localized: "Bind 127.0.0.1:PORT to make sure they stay local."))
                }
            }
            let secrets = c.environment.filter { $0.isSensitive && !$0.value.isEmpty }.map(\.key)
            if !secrets.isEmpty {
                // List variable names only; never include values in the result.
                add(.info, String(localized: "secret in env"), String(localized: "Variables: \(secrets.joined(separator: ", ")). Anyone with Docker access can read them via inspect."), String(localized: "Use Docker secrets or `*_FILE` files."))
            }
        }
        return items
    }
}

// MARK: - Port conflict

enum PortDiagnostics {
    /// Reports host ports declared by more than one container, and host ports of **stopped** containers
    /// that are already taken (ports of running containers are held by Colima itself).
    /// `isInUse` reports whether a host TCP port is taken (injected for tests).
    static func check(_ details: [ContainerDetails], isInUse: (Int) -> Bool) -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        var owners: [Int: [String]] = [:]
        for c in details {
            for binding in c.declaredHostPorts { owners[binding.port, default: []].append(c.displayName) }
        }
        for (port, names) in owners.sorted(by: { $0.key < $1.key }) where Set(names).count > 1 {
            items.append(DiagnosticItem(
                category: .ports, severity: .warning, title: String(localized: "Port \(Format.digits(port)) declared more than once"),
                detail: String(localized: "Used by: \(Set(names).sorted().joined(separator: ", ")). Only one container can run at a time."),
                recommendation: String(localized: "Change the host port of one container.")
            ))
        }
        for c in details where c.state?.running != true {
            for binding in c.declaredHostPorts where isInUse(binding.port) {
                let runningOwner = details.first { $0.state?.running == true && $0.declaredHostPorts.contains { $0.port == binding.port } }
                items.append(DiagnosticItem(
                    category: .ports, severity: .warning, title: String(localized: "\(c.displayName): port \(Format.digits(binding.port)) is in use"),
                    detail: runningOwner.map { String(localized: "Running container \($0.displayName) holds this port.") } ?? String(localized: "A process on the Mac is using this port; starting the container will fail."),
                    recommendation: String(localized: "Stop the process/container holding the port or change the host port."),
                    containerID: c.id
                ))
            }
        }
        return items
    }
}

enum PortProbe {
    /// Tries to bind TCP 127.0.0.1:port; failing with EADDRINUSE means the port is taken.
    static func isInUse(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result != 0 && errno == EADDRINUSE
    }
}

// MARK: - Docker context (CLI)

struct DockerContextInfo: Equatable, Sendable {
    let name: String
    let endpoint: String?
}

enum DockerContextReader {
    /// The docker CLI's current context: `currentContext` from config.json, endpoint from
    /// `contexts/meta/*/meta.json`. The "default" context is reported as /var/run/docker.sock
    /// (`DOCKER_HOST` is not consulted).
    static func current(dockerConfigDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")) -> DockerContextInfo? {
        struct Config: Decodable { let currentContext: String? }
        struct Meta: Decodable {
            struct Endpoint: Decodable { let Host: String? }
            let Name: String
            let Endpoints: [String: Endpoint]?
        }
        let configURL = dockerConfigDir.appendingPathComponent("config.json")
        let name = (try? JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)))?.currentContext ?? "default"
        if name == "default" { return DockerContextInfo(name: name, endpoint: "unix:///var/run/docker.sock") }
        let metaDir = dockerConfigDir.appendingPathComponent("contexts/meta")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: metaDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data), meta.Name == name else { continue }
            return DockerContextInfo(name: name, endpoint: meta.Endpoints?["docker"]?.Host)
        }
        return DockerContextInfo(name: name, endpoint: nil)
    }
}

// MARK: - Storage

struct StorageReport: Sendable {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let size: Int64
        var detail: String = ""
    }

    var unusedVolumes: [Item] = []
    var danglingImages: [Item] = []
    var unusedImages: [Item] = []
    var stoppedContainers: [Item] = []
    var buildCacheTotal: Int64 = 0
    var buildCacheReclaimable: Int64 = 0

    var unusedVolumesSize: Int64 { unusedVolumes.reduce(0) { $0 + $1.size } }

    /// Names of the ticked volumes that are still unused in this report. A ticked volume that a
    /// container started using since (or that no longer exists) is never removed.
    func unusedVolumeNames(selected: Set<String>) -> [String] {
        unusedVolumes.filter { selected.contains($0.id) }.map(\.name)
    }
    var danglingImagesSize: Int64 { danglingImages.reduce(0) { $0 + $1.size } }
    var unusedImagesSize: Int64 { unusedImages.reduce(0) { $0 + $1.size } }
    var stoppedContainersSize: Int64 { stoppedContainers.reduce(0) { $0 + $1.size } }

    /// Analyzes `/system/df` plus the container list. Image sizes are **estimates**: layers shared
    /// between images are not freed when only one of them is removed.
    static func analyze(_ usage: DiskUsage, containers: [DockerContainer]) -> StorageReport {
        var report = StorageReport()
        let usedImageIDs = Set(containers.compactMap(\.imageID))
        let usedVolumes = Set(containers.flatMap(\.volumeNames))
        for volume in usage.volumes ?? [] {
            let refCount = volume.usageData?.refCount ?? (usedVolumes.contains(volume.name) ? 1 : 0)
            guard refCount == 0, !usedVolumes.contains(volume.name) else { continue }
            report.unusedVolumes.append(Item(
                id: volume.name, name: volume.name, size: max(0, volume.usageData?.size ?? 0),
                detail: volume.composeProject.map { String(localized: "project \($0)") } ?? (volume.isAnonymous ? String(localized: "anonymous") : "")
            ))
        }
        for image in usage.images ?? [] where !usedImageIDs.contains(image.id) && (image.containers ?? 0) <= 0 {
            let item = Item(id: image.id, name: image.displayName, size: image.size)
            if image.isDangling { report.danglingImages.append(item) } else { report.unusedImages.append(item) }
        }
        for container in usage.containers ?? [] where container.state != "running" && container.state != "paused" {
            let name = container.names?.first.map { String($0.drop { $0 == "/" }) } ?? String((container.id ?? "").prefix(12))
            report.stoppedContainers.append(Item(id: container.id ?? name, name: name, size: container.sizeRw ?? 0, detail: container.state ?? ""))
        }
        report.buildCacheTotal = usage.buildCacheSize
        report.buildCacheReclaimable = (usage.buildCache ?? []).filter { $0.inUse != true }.reduce(0) { $0 + $1.size }
        report.unusedVolumes.sort { $0.size > $1.size }
        report.unusedImages.sort { $0.size > $1.size }
        report.danglingImages.sort { $0.size > $1.size }
        return report
    }
}
