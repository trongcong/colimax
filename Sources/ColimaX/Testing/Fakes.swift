#if COLIMAX_UI_TESTING
import Foundation

// In-memory Colima and Docker Engine fakes. Compiled only with `-D COLIMAX_UI_TESTING`: unit tests
// (`scripts/run-tests.sh`) and the UI-test app (`scripts/ui-tests.sh`) use them; release builds don't
// contain them.

/// Errors returned by the fakes.
struct FakeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Colima

final class FakeColima: ColimaControlling, @unchecked Sendable {
    struct State {
        var profiles: [ColimaProfile] = []
        /// Every call, e.g. "start default", "stop default", "delete dev data".
        var calls: [String] = []
        /// When set, lifecycle streams fail with this message.
        var failLifecycle: String?
        var listError: String?
        var vmUsage = VMUsage()
        /// When set, lifecycle streams print their first line and then never finish (until cancelled):
        /// a long `colima start` for cancel / quit tests.
        var hangLifecycle = false
        /// Demo fixtures: busy fraction of the VM CPU. Each `vmUsage` call advances the /proc/stat
        /// counters so the Dashboard can compute a CPU % between two readings.
        var vmLoad: Double?
        /// Answer of `status`; the call fails when nil (the app then falls back to the default socket).
        var status: ColimaStatus?
        /// Answer of `readConfig` (colima.yaml).
        var config = RuntimeConfig()
    }

    let state: Locked<State>

    init(profiles: [ColimaProfile] = []) {
        state = Locked(State(profiles: profiles))
    }

    var calls: [String] { state.current.calls }

    func listProfiles() async throws -> [ColimaProfile] {
        try state.withLock { s in
            s.calls.append("list")
            if let error = s.listError { throw FakeError(message: error) }
            return s.profiles
        }
    }

    func status(_ profile: String) async throws -> ColimaStatus {
        guard let status = state.current.status else { throw FakeError(message: "status not available in the fake") }
        return status
    }

    func start(_ profile: String, config: RuntimeConfig?) -> AsyncThrowingStream<String, Error> {
        lifecycle("start \(profile)") { s in
            if let index = s.profiles.firstIndex(where: { $0.name == profile }) {
                s.profiles[index] = s.profiles[index].with(status: "Running")
            } else {
                s.profiles.append(FakeColima.profile(profile, running: true))
            }
        }
    }

    func stop(_ profile: String) -> AsyncThrowingStream<String, Error> {
        lifecycle("stop \(profile)") { s in
            if let index = s.profiles.firstIndex(where: { $0.name == profile }) {
                s.profiles[index] = s.profiles[index].with(status: "Stopped")
            }
        }
    }

    func restart(_ profile: String) -> AsyncThrowingStream<String, Error> {
        lifecycle("restart \(profile)") { _ in }
    }

    func delete(_ profile: String, deleteData: Bool) -> AsyncThrowingStream<String, Error> {
        lifecycle("delete \(profile)\(deleteData ? " data" : "")") { s in
            s.profiles.removeAll { $0.name == profile }
        }
    }

    func vmUsage(_ profile: String) async throws -> VMUsage {
        state.withLock { s in
            if let load = s.vmLoad {
                let ticks: UInt64 = 400 * UInt64(max(1, s.vmUsage.cpuCount))
                let jitter = Double.random(in: -0.04...0.04)
                s.vmUsage.cpuTotalTicks += ticks
                s.vmUsage.cpuIdleTicks += UInt64(Double(ticks) * (1 - min(0.95, max(0.02, load + jitter))))
            }
            return s.vmUsage
        }
    }

    func readConfig(_ profile: String) -> RuntimeConfig? { state.current.config }

    private func lifecycle(_ call: String, _ apply: @escaping @Sendable (inout State) -> Void) -> AsyncThrowingStream<String, Error> {
        let state = state
        return AsyncThrowingStream { continuation in
            let (failure, hang): (String?, Bool) = state.withLock { s in
                s.calls.append(call)
                return (s.failLifecycle, s.hangLifecycle)
            }
            continuation.yield("time=\"now\" level=info msg=\"\(call)\"")
            if hang { return }
            if let failure {
                continuation.finish(throwing: FakeError(message: failure))
            } else {
                state.withLock(apply)
                continuation.finish()
            }
        }
    }

    static func profile(_ name: String, running: Bool, runtime: String = "docker") -> ColimaProfile {
        decode(ColimaProfile.self, [
            "name": name, "status": running ? "Running" : "Stopped", "arch": "aarch64",
            "cpus": 4, "memory": 8 << 30, "disk": 100 << 30, "runtime": runtime,
        ])
    }
}

private extension ColimaProfile {
    func with(status: String) -> ColimaProfile {
        var object: [String: Any] = ["name": name, "status": status]
        object["arch"] = arch
        object["cpus"] = cpus
        object["memory"] = memory
        object["disk"] = disk
        object["runtime"] = runtime
        return decode(ColimaProfile.self, object)
    }
}

// MARK: - Docker

final class FakeDocker: DockerEngine, @unchecked Sendable {
    struct State {
        var containers: [DockerContainer] = []
        var images: [DockerImage] = []
        var volumes: [DockerVolume] = []
        var networks: [DockerNetwork] = []
        /// Inspect details by container ID (`containerDetails`).
        var details: [String: ContainerDetails] = [:]
        /// Every mutating call, e.g. "remove container c1 volumes=false", "action c1 stop".
        var calls: [String] = []
        /// Endpoints that fail: "containers", "images", "volumes", "networks", "removeContainer", …
        var failing: [String: String] = [:]
        var eventContinuations: [UUID: AsyncThrowingStream<DockerEvent, Error>.Continuation] = [:]
        /// Volume binds of containers created through `createContainer` (`volume:/path[:ro]`).
        var binds: [String: [String]] = [:]
        /// Tar content of each volume, as seen through a helper container mounting it at /volume.
        var volumeArchives: [String: Data] = [:]
        /// Files written into containers: "containerID:/dir/name" → content (`uploadAsTar`) or
        /// "containerID:/path" → tar (`uploadArchive` on a container without a volume bind).
        var uploads: [String: Data] = [:]
        /// Archives readable with `archiveData` / `downloadArchive`: "containerID:/path" → tar.
        var archives: [String: Data] = [:]
        /// Answers `exec` / `execToFile`: (container ID, argv) → (stdout, stderr, exit code).
        var execHandler: @Sendable (String, [String]) -> (stdout: Data, stderr: Data, exitCode: Int) = { _, _ in (Data(), Data(), 0) }
        var pendingExecs: [String: (container: String, argv: [String])] = [:]
        var execExitCodes: [String: Int] = [:]
        var nextID = 1
        /// Image architecture by image ID (`imagePlatform`); arm64 when absent.
        var architectures: [String: String] = [:]
        /// What `info()` reports about the engine.
        var engine = FakeEngineInfo()
        /// Returned by `diskUsage()` when set; an empty report otherwise.
        var diskUsage: DiskUsage?
        /// Log text by container ID (`logStream`); two placeholder lines when absent.
        var logs: [String: String] = [:]
        /// Demo fixtures: resource use by container ID. Containers listed here stream a new stats sample
        /// every second; the others stream nothing.
        var load: [String: FakeLoad] = [:]
    }

    let state: Locked<State>

    init(containers: [DockerContainer] = [], images: [DockerImage] = [], volumes: [DockerVolume] = [],
         networks: [DockerNetwork] = [], details: [String: ContainerDetails] = [:]) {
        state = Locked(State(containers: containers, images: images, volumes: volumes, networks: networks, details: details))
    }

    var calls: [String] { state.current.calls }

    func fail(_ endpoint: String, _ message: String?) {
        state.withLock { $0.failing[endpoint] = message }
    }

    /// Sends an event to every open `events()` stream.
    func emit(_ type: String, _ action: String, id: String, attributes: [String: String] = [:]) {
        let event = DockerEvent(type: type, action: action, actor: .init(id: id, attributes: attributes))
        for continuation in state.withLock({ Array($0.eventContinuations.values) }) { continuation.yield(event) }
    }

    private func check(_ endpoint: String) throws {
        if let message = state.withLock({ $0.failing[endpoint] }) { throw FakeError(message: message) }
    }

    private func record(_ endpoint: String, _ call: String, _ body: (inout State) throws -> Void = { _ in }) throws {
        try check(endpoint)
        try state.withLock { s in
            s.calls.append(call)
            try body(&s)
        }
    }

    // System

    func ping(timeout: Int) async throws { try check("ping") }

    func info() async throws -> DockerInfo {
        try check("info")
        return state.withLock { s in
            decode(DockerInfo.self, [
                "Containers": s.containers.count, "ContainersRunning": s.containers.filter(\.isRunning).count,
                "ContainersPaused": 0, "ContainersStopped": s.containers.filter { !$0.isRunning }.count,
                "Images": s.images.count, "ServerVersion": s.engine.serverVersion, "OperatingSystem": s.engine.operatingSystem,
                "KernelVersion": s.engine.kernelVersion, "Architecture": "aarch64", "NCPU": s.engine.cpus, "MemTotal": s.engine.memory,
            ])
        }
    }

    func diskUsage() async throws -> DiskUsage {
        try check("diskUsage")
        if let usage = state.withLock({ $0.diskUsage }) { return usage }
        return decode(DiskUsage.self, ["LayersSize": 0, "Images": [], "Containers": [], "Volumes": [], "BuildCache": []])
    }

    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        let state = state
        let id = UUID()
        return AsyncThrowingStream { continuation in
            state.withLock { $0.eventContinuations[id] = continuation }
            continuation.onTermination = { _ in state.withLock { _ = $0.eventContinuations.removeValue(forKey: id) } }
        }
    }

    // Containers

    func containers() async throws -> [DockerContainer] {
        try check("containers")
        return state.current.containers
    }

    func containerAction(_ id: String, _ action: String) async throws {
        try record("containerAction", "action \(id) \(action)") { s in
            guard let index = s.containers.firstIndex(where: { $0.id == id }) else { throw FakeError(message: "No such container: \(id)") }
            let newState: String
            switch action {
            case "start", "restart", "unpause": newState = "running"
            case "pause": newState = "paused"
            default: newState = "exited"
            }
            s.containers[index] = s.containers[index].with(state: newState)
        }
        emit("container", action, id: id)
    }

    func removeContainer(_ id: String, force: Bool, volumes: Bool) async throws {
        try record("removeContainer", "remove container \(id) volumes=\(volumes)") { s in
            guard s.containers.contains(where: { $0.id == id }) else { throw FakeError(message: "No such container: \(id)") }
            s.containers.removeAll { $0.id == id }
        }
        emit("container", "destroy", id: id)
    }

    func inspectContainer(_ id: String) async throws -> String { "{\n  \"Id\": \"\(id)\"\n}" }

    func containerDetails(_ id: String) async throws -> ContainerDetails {
        try check("containerDetails")
        guard let details = state.withLock({ $0.details[id] }) else { throw FakeError(message: "No such container: \(id)") }
        return details
    }

    func isTTY(_ id: String) async throws -> Bool { false }

    func logStream(_ id: String, tail: Int, follow: Bool, timestamps: Bool) -> AsyncThrowingStream<Data, Error> {
        let text = state.withLock { $0.logs[id] } ?? "fake log line 1\nfake log line 2\n"
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8))
            if !follow { continuation.finish() }
        }
    }

    func statsStream(_ id: String) -> AsyncThrowingStream<ContainerStats, Error> {
        guard let load = state.withLock({ $0.load[id] }) else { return AsyncThrowingStream { _ in } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    continuation.yield(load.sample(tick: tick))
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stats(_ id: String) async throws -> ContainerStats {
        if let load = state.withLock({ $0.load[id] }) { return load.sample(tick: Int(Date().timeIntervalSince1970)) }
        return decode(ContainerStats.self, [
            "cpu_stats": ["cpu_usage": ["total_usage": 2_000], "system_cpu_usage": 10_000, "online_cpus": 4],
            "precpu_stats": ["cpu_usage": ["total_usage": 1_000], "system_cpu_usage": 5_000, "online_cpus": 4],
            "memory_stats": ["usage": 100 << 20, "limit": 1 << 30],
        ])
    }

    func exec(_ id: String, command: String, timeout: Int) async throws -> (output: String, exitCode: Int) {
        try await exec(id, argv: ["sh", "-c", command], timeout: timeout)
    }

    func exec(_ id: String, argv: [String], timeout: Int) async throws -> (output: String, exitCode: Int) {
        try record("exec", "exec \(id) \(argv.joined(separator: " "))")
        let result = state.withLock { $0.execHandler }(id, argv)
        return (String(decoding: result.stdout + result.stderr, as: UTF8.self), result.exitCode)
    }

    func createExec(_ id: String, command: [String]) async throws -> String {
        try record("exec", "exec \(id) \(command.joined(separator: " "))")
        return state.withLock { s in
            let execID = "exec-\(s.nextID)"
            s.nextID += 1
            s.pendingExecs[execID] = (id, command)
            return execID
        }
    }

    func execExitCode(_ execID: String) async throws -> Int? {
        state.withLock { $0.execExitCodes[execID] }
    }

    func execToFile(_ execID: String, to destination: URL, timeout: Int,
                    onStderr: @escaping @Sendable (Data) -> Void) async throws -> DockerClient.FileTransfer {
        try check("execToFile")
        guard let pending = state.withLock({ $0.pendingExecs.removeValue(forKey: execID) }) else {
            throw FakeError(message: "No such exec: \(execID)")
        }
        let result = state.withLock { $0.execHandler }(pending.container, pending.argv)
        state.withLock { $0.execExitCodes[execID] = result.exitCode }
        if !result.stderr.isEmpty { onStderr(result.stderr) }
        return try await Self.write(result.stdout, to: destination)
    }

    func createContainer<Body: Encodable & Sendable>(name: String?, body: Body) async throws -> String {
        try check("createContainer")
        let config = try JSONDecoder().decode(FakeCreateConfig.self, from: JSONEncoder().encode(body))
        let id = state.withLock { s -> String in
            let id = "fake-\(s.nextID)"
            s.nextID += 1
            s.calls.append("create container \(name ?? id) image=\(config.Image)")
            s.containers.append(FakeDocker.container(id, name: name ?? id, image: config.Image, state: "created", labels: config.Labels ?? [:]))
            s.binds[id] = config.HostConfig?.Binds ?? []
            return id
        }
        emit("container", "create", id: id)
        return id
    }

    // Archives

    /// Volume mounted at `mountPoint` in a helper container, if any.
    private func volume(of container: String, at mountPoint: String) -> String? {
        state.withLock { s in
            (s.binds[container] ?? []).lazy.map { $0.split(separator: ":").map(String.init) }
                .first { $0.count >= 2 && $0[1] == mountPoint }?.first
        }
    }

    func downloadArchive(container id: String, path: String, to destination: URL, timeout: Int) async throws -> DockerClient.FileTransfer {
        try record("downloadArchive", "download \(id):\(path)")
        let data: Data
        if path == "/volume", let volume = volume(of: id, at: "/volume") {
            data = state.withLock { $0.volumeArchives[volume] } ?? Self.tar([("volume/README", Data("empty fake volume\n".utf8))])
        } else if let archive = state.withLock({ $0.archives["\(id):\(path)"] }) {
            data = archive
        } else {
            throw FakeError(message: "Could not find the file \(path) in container \(id)")
        }
        return try await Self.write(data, to: destination)
    }

    func archiveData(container id: String, path: String) async throws -> Data {
        try check("archiveData")
        guard let archive = state.withLock({ $0.archives["\(id):\(path)"] }) else {
            throw FakeError(message: "Could not find the file \(path) in container \(id)")
        }
        return archive
    }

    func uploadArchive(container id: String, path: String, tarFile: URL, timeout: Int) async throws {
        let data = try Data(contentsOf: tarFile)
        let volume = path == "/" ? volume(of: id, at: "/volume") : nil
        try record("uploadArchive", "upload \(id):\(path)") { s in
            if let volume { s.volumeArchives[volume] = data } else { s.uploads["\(id):\(path)"] = data }
        }
    }

    func uploadAsTar(container id: String, directory: String, file: URL, entryName: String, mode: Int, timeout: Int) async throws {
        let data = try Data(contentsOf: file)
        try record("uploadAsTar", "upload \(id):\(directory)/\(entryName)") { s in
            s.uploads["\(id):\(directory)/\(entryName)"] = data
        }
    }

    private static func write(_ data: Data, to destination: URL) async throws -> DockerClient.FileTransfer {
        // Same guarantee as `DockerClient.receiveToFile`: write a temp file next to the destination, then
        // install it, so a failure never leaves a partial file in place of an existing one.
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).fake-\(UUID().uuidString.prefix(8))")
        try data.write(to: temp)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        return try await FileHasher.hash(file: destination)
    }

    /// A ustar archive with the given file entries.
    static func tar(_ entries: [(name: String, content: Data?)]) -> Data {
        var archive = Data()
        for entry in entries {
            let content = entry.content ?? Data()
            archive.append(header(path: entry.name, size: content.count))
            archive.append(content)
            archive.append(Data(count: Int(TarWriter.paddedSize(Int64(content.count))) - content.count))
        }
        archive.append(Data(count: 1024))
        return archive
    }

    /// ustar header for a path (TarWriter only accepts bare names): name patched in, checksum recomputed.
    private static func header(path: String, size: Int) -> Data {
        var block = [UInt8]((try? TarWriter.header(name: "placeholder", size: Int64(size))) ?? Data(count: 512))
        for index in 0..<100 { block[index] = 0 }
        for (index, byte) in path.utf8.prefix(100).enumerated() { block[index] = byte }
        for index in 148..<156 { block[index] = 0x20 }
        let checksum = String(block.reduce(0) { $0 + Int($1) }, radix: 8)
        for (index, byte) in (String(repeating: "0", count: max(0, 6 - checksum.count)) + checksum).utf8.enumerated() { block[148 + index] = byte }
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    func pruneStoppedContainers() async throws -> PruneReport {
        try record("pruneStoppedContainers", "prune containers") { s in s.containers.removeAll { !$0.isRunning } }
        return PruneReport.fake
    }

    // Images

    func images() async throws -> [DockerImage] {
        try check("images")
        return state.current.images
    }

    func removeImage(_ id: String, force: Bool) async throws {
        try record("removeImage", "remove image \(id) force=\(force)") { s in s.images.removeAll { $0.id == id } }
        emit("image", "delete", id: id)
    }

    func inspectImage(_ id: String) async throws -> String { "{}" }

    func imagePlatform(_ id: String) async throws -> ImagePlatform {
        decode(ImagePlatform.self, ["Id": id, "Architecture": state.withLock { $0.architectures[id] } ?? "arm64", "Os": "linux"])
    }

    func pull(_ reference: String) -> AsyncThrowingStream<PullProgress, Error> {
        let state = state
        return AsyncThrowingStream { continuation in
            state.withLock { $0.calls.append("pull \(reference)") }
            continuation.yield(decode(PullProgress.self, ["status": "Pulling from library/\(reference)", "id": "latest"]))
            continuation.yield(decode(PullProgress.self, ["status": "Download complete", "id": "layer1"]))
            continuation.finish()
        }
    }

    func pruneImages(all: Bool) async throws -> PruneReport {
        try record("pruneImages", "prune images all=\(all)")
        return PruneReport.fake
    }

    func pruneBuildCache() async throws -> PruneReport {
        try record("pruneBuildCache", "prune build cache")
        return PruneReport.fake
    }

    func imageExists(_ reference: String) async -> Bool {
        state.withLock { s in s.images.contains { $0.id == reference || $0.tags.contains(reference) } }
    }

    // Volumes

    func volumes() async throws -> [DockerVolume] {
        try check("volumes")
        return state.current.volumes
    }

    func createVolume(name: String, labels: [String: String]) async throws {
        try record("createVolume", "create volume \(name)") { s in s.volumes.append(FakeDocker.volume(name)) }
        emit("volume", "create", id: name)
    }

    func removeVolume(_ name: String, force: Bool) async throws {
        try record("removeVolume", "remove volume \(name)") { s in
            guard s.volumes.contains(where: { $0.name == name }) else { throw FakeError(message: "No such volume: \(name)") }
            s.volumes.removeAll { $0.name == name }
        }
        emit("volume", "destroy", id: name)
    }

    func inspectVolume(_ name: String) async throws -> String { "{}" }

    func pruneVolumes(all: Bool, label: String?) async throws -> PruneReport {
        try record("pruneVolumes", "prune volumes all=\(all)")
        return PruneReport.fake
    }

    // Networks

    func networks() async throws -> [DockerNetwork] {
        try check("networks")
        return state.current.networks
    }

    func createNetwork(name: String, driver: String, subnet: String?, gateway: String?, isInternal: Bool,
                       labels: [String: String]) async throws {
        try record("createNetwork", "create network \(name)") { s in s.networks.append(FakeDocker.network(name)) }
        emit("network", "create", id: name)
    }

    func removeNetwork(_ id: String) async throws {
        try record("removeNetwork", "remove network \(id)") { s in s.networks.removeAll { $0.id == id } }
        emit("network", "destroy", id: id)
    }

    func inspectNetwork(_ id: String) async throws -> String { "{}" }

    func connect(network: String, container: String) async throws {
        try record("connect", "connect \(container) \(network)")
    }

    func disconnect(network: String, container: String) async throws {
        try record("disconnect", "disconnect \(container) \(network)")
    }

    func pruneNetworks(label: String?) async throws {
        try record("pruneNetworks", "prune networks")
    }

    // MARK: Model builders (Docker API JSON shapes)

    static func container(_ id: String, name: String, image: String = "nginx:latest", state: String = "running",
                          labels: [String: String] = [:]) -> DockerContainer {
        decode(DockerContainer.self, [
            "Id": id, "Names": ["/\(name)"], "Image": image, "Created": 1_700_000_000,
            "State": state, "Status": state == "running" ? "Up 5 minutes" : "Exited (0) 1 minute ago",
            "Labels": labels,
        ])
    }

    static func image(_ id: String, tag: String) -> DockerImage {
        decode(DockerImage.self, ["Id": id, "RepoTags": [tag], "Created": 1_700_000_000, "Size": 50 << 20])
    }

    static func volume(_ name: String) -> DockerVolume {
        decode(DockerVolume.self, ["Name": name, "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/\(name)/_data"])
    }

    static func network(_ name: String) -> DockerNetwork {
        decode(DockerNetwork.self, ["Id": "net-\(name)", "Name": name, "Driver": "bridge", "Scope": "local"])
    }

    static func details(_ id: String, name: String, env: [String]) -> ContainerDetails {
        decode(ContainerDetails.self, [
            "Id": id, "Name": "/\(name)", "RestartCount": 0,
            "State": ["Status": "running", "Running": true, "ExitCode": 0, "OOMKilled": false],
            "Config": ["Env": env, "Image": "postgres:16"],
        ])
    }
}

/// The fields of a `POST /containers/create` body the fake understands.
private struct FakeCreateConfig: Decodable {
    struct Host: Decodable { let Binds: [String]? }
    let Image: String
    let Labels: [String: String]?
    let HostConfig: Host?
}

private extension DockerContainer {
    func with(state newState: String) -> DockerContainer {
        FakeDocker.container(id, name: name, image: image, state: newState, labels: labels ?? [:])
    }
}

/// Engine facts reported by `FakeDocker.info()`.
struct FakeEngineInfo: Sendable {
    var serverVersion = "fake"
    var operatingSystem = "Fake Linux"
    var kernelVersion = "6.0"
    var cpus = 4
    var memory: Int64 = 8 << 30
}

/// Resource use of one demo container. `sample(tick:)` wanders around these values so charts move.
struct FakeLoad: Sendable {
    /// CPU in `docker stats` terms (100 = one core).
    var cpu: Double
    var memory: Int64
    var memoryLimit: Int64 = 8 << 30
    /// Network and block I/O growth per second, in bytes.
    var network: Int64 = 0
    var disk: Int64 = 0

    func sample(tick: Int) -> ContainerStats {
        let t = Double(tick)
        let phase = Double((memory >> 20) % 97)
        let wave = 1 + 0.35 * sin((t + phase) / 7) + 0.15 * sin((t + phase) / 2.3) + Double.random(in: -0.08...0.08)
        let percent = max(0.05, cpu * wave)
        let cpus = 4.0, system: UInt64 = 1_000_000_000
        let base = UInt64(t) * system
        let used = UInt64(percent / 100 / cpus * Double(system))
        let elapsed = Int64(max(1, tick))
        return decode(ContainerStats.self, [
            "cpu_stats": ["cpu_usage": ["total_usage": base + used], "system_cpu_usage": base + system, "online_cpus": Int(cpus)],
            "precpu_stats": ["cpu_usage": ["total_usage": base], "system_cpu_usage": base, "online_cpus": Int(cpus)],
            "memory_stats": ["usage": Int64(Double(memory) * (1 + 0.04 * sin((t + phase) / 11))), "limit": memoryLimit],
            "networks": ["eth0": ["rx_bytes": network * elapsed * 3 + 52_000_000, "tx_bytes": network * elapsed + 18_000_000]],
            "blkio_stats": ["io_service_bytes_recursive": [
                ["op": "read", "value": disk * elapsed + 210_000_000], ["op": "write", "value": disk * elapsed / 2 + 64_000_000],
            ]],
        ])
    }
}

private extension PruneReport {
    static var fake: PruneReport { decode(PruneReport.self, ["SpaceReclaimed": 1 << 20]) }
}

/// Builds a model from a JSON-like dictionary (the fakes use the real Decodable shapes).
func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(T.self, from: data)
}

// MARK: - UI-test fixtures

/// Variants of the UI-test fixtures, chosen with `COLIMAX_UI_TEST_SCENARIO` (default `standard`).
enum UITestScenario: String {
    case standard
    /// Profile `default` exists but is stopped.
    case vmStopped = "vm-stopped"
    /// VM operations never finish until cancelled (cancel / quit confirmations).
    case slowOperation = "slow-op"
    /// Setup Assistant: nothing installed, not even Homebrew.
    case noHomebrew = "no-brew"
    /// Setup Assistant: Homebrew and colima installed, docker CLI + compose missing; installing succeeds.
    case missingTools = "missing-tools"
    /// Setup Assistant: compose plugin installed but not in the docker CLI config (`$DOCKER_CONFIG`).
    case composePlugin = "compose-plugin"
    /// Every tool installed, no Colima profile yet.
    case noProfile = "no-profile"
    /// Standard fixtures plus an Elasticsearch container whose cluster has no `path.repo`.
    case elasticsearch
    /// A realistic workload for screenshots of the landing page (`scripts/site-screenshots.sh`):
    /// two Compose projects, moving resource charts, disk usage and a few audit findings.
    case demo

    static var current: UITestScenario {
        ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_SCENARIO"].flatMap(UITestScenario.init(rawValue:)) ?? .standard
    }
}

/// Data and services for the UI-test app (`COLIMAX_UI_TEST_FIXTURES=1`): one running profile with a
/// web container, a database container with secrets in its environment, and a stopped worker.
enum UITestFixtures {
    static let databasePassword = "fixture-password-123"
    static let composeProject = "shop"
    static let pluginDirectory = "/opt/homebrew/lib/docker/cli-plugins"
    static let elasticsearchImage = "docker.elastic.co/elasticsearch/elasticsearch:8.15.3"

    private static func composeLabels(_ service: String) -> [String: String] {
        ["com.docker.compose.project": composeProject, "com.docker.compose.service": service,
         "com.docker.compose.project.working_dir": "/tmp/colimax-fixture-shop",
         "com.docker.compose.project.config_files": "/tmp/colimax-fixture-shop/compose.yaml"]
    }

    static func services(scenario: UITestScenario = .current) -> AppServices {
        if scenario == .demo { return DemoFixtures.services(prerequisites: prerequisites(for: .standard)) }
        let profiles: [ColimaProfile] = switch scenario {
        case .noProfile: []
        case .vmStopped: [FakeColima.profile("default", running: false)]
        default: [FakeColima.profile("default", running: true)]
        }
        let colima = FakeColima(profiles: profiles)
        if scenario == .slowOperation { colima.state.withLock { $0.hangLifecycle = true } }

        var containers = [
            FakeDocker.container("c-web", name: "web", image: "nginx:latest", labels: composeLabels("web")),
            FakeDocker.container("c-db", name: "db", image: "postgres:16", labels: composeLabels("db")),
            FakeDocker.container("c-worker", name: "worker", image: "busybox:latest", state: "exited"),
        ]
        if scenario == .elasticsearch {
            containers.append(FakeDocker.container("c-search", name: "search", image: elasticsearchImage))
        }
        let docker = FakeDocker(
            containers: containers,
            images: [
                FakeDocker.image("sha256:aaa", tag: "nginx:latest"),
                FakeDocker.image("sha256:bbb", tag: "postgres:16"),
                FakeDocker.image("sha256:ccc", tag: "legacy/app:1.0"),
            ],
            volumes: [FakeDocker.volume("db-data")],
            networks: [FakeDocker.network("bridge"), FakeDocker.network("app-net")],
            details: [
                "c-db": FakeDocker.details("c-db", name: "db", env: [
                    "POSTGRES_USER=app", "POSTGRES_PASSWORD=\(databasePassword)", "PGDATA=/var/lib/postgresql/data",
                ]),
                "c-web": FakeDocker.details("c-web", name: "web", env: ["NGINX_PORT=80"]),
                "c-worker": FakeDocker.details("c-worker", name: "worker", env: []),
                "c-search": FakeDocker.details("c-search", name: "search", env: ["discovery.type=single-node"]),
            ]
        )
        docker.state.withLock { s in
            s.architectures["sha256:ccc"] = "amd64"
            // Elasticsearch REST through `sh -c <script> sh METHOD PATH BODY`: the cluster has no path.repo.
            s.execHandler = { container, argv in
                guard container == "c-search", argv.count >= 7 else { return (Data(), Data(), 0) }
                let body = argv[6].hasPrefix("/_nodes/settings") ? #"{"nodes":{"n1":{"settings":{}}}}"# : "{}"
                return (Data("\(body)\n200".utf8), Data(), 0)
            }
        }

        let tools = prerequisites(for: scenario)
        return AppServices(
            colima: colima,
            makeDocker: { _ in docker },
            checkPrerequisites: { tools.report() },
            installPrerequisites: { formulae in tools.install(formulae) },
            watchesColimaDirectory: false,
            notify: { _, _ in },
            scannerTools: { [] }
        )
    }

    /// Installed tools for a scenario; `install` marks the formulae as installed.
    static func prerequisites(for scenario: UITestScenario) -> FakePrerequisites {
        let brew = "/opt/homebrew/bin/brew", colima = "/opt/homebrew/bin/colima", docker = "/opt/homebrew/bin/docker"
        switch scenario {
        case .noHomebrew:
            return FakePrerequisites(brew: nil, colima: nil, docker: nil, compose: false)
        case .missingTools:
            return FakePrerequisites(brew: brew, colima: colima, docker: nil, compose: false)
        case .composePlugin:
            return FakePrerequisites(brew: brew, colima: colima, docker: docker, compose: false, pluginDirectory: pluginDirectory)
        default:
            return FakePrerequisites(brew: brew, colima: colima, docker: docker, compose: true)
        }
    }
}

/// Tool presence for the Setup Assistant fixtures. With a plugin directory, `docker compose` counts as
/// working once that directory is listed in `cliPluginsExtraDirs` of the docker CLI config.
final class FakePrerequisites: @unchecked Sendable {
    private struct Tools {
        var brew, colima, docker: String?
        var compose: Bool
        var pluginDirectory: String?
    }
    private let tools: Locked<Tools>

    init(brew: String?, colima: String?, docker: String?, compose: Bool, pluginDirectory: String? = nil) {
        tools = Locked(Tools(brew: brew, colima: colima, docker: docker, compose: compose, pluginDirectory: pluginDirectory))
    }

    func report() -> PrerequisiteReport {
        let t = tools.current
        var compose = t.compose
        if !compose, let directory = t.pluginDirectory, t.docker != nil {
            let config = Prerequisites.dockerConfigDirectory.appendingPathComponent("config.json")
            let object = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            compose = (object?["cliPluginsExtraDirs"] as? [String])?.contains(directory) ?? false
        }
        return PrerequisiteReport(brewPath: t.brew, colimaPath: t.colima, dockerPath: t.docker,
                                  composeAvailable: compose, composePluginDirectory: compose ? nil : t.pluginDirectory)
    }

    /// Streams a short `brew install` log, then marks the formulae as installed.
    func install(_ formulae: [String]) -> AsyncThrowingStream<String, Error> {
        let tools = tools
        let installed = Prerequisites.installArguments(formulae).dropFirst()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for formula in installed {
                    continuation.yield("==> Installing \(formula)")
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                }
                tools.withLock { t in
                    if installed.contains("colima") { t.colima = "/opt/homebrew/bin/colima" }
                    if installed.contains("docker") { t.docker = "/opt/homebrew/bin/docker" }
                    if installed.contains("docker-compose") { t.compose = true }
                }
                continuation.yield("==> Done")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
