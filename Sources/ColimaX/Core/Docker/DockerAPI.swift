import Foundation

/// Typed Docker endpoints built on DockerClient. IDs/names are always percent-encoded.
extension DockerClient {
    private func seg(_ value: String) -> String { Self.escape(value) }

    // MARK: System

    func info() async throws -> DockerInfo { try await decode(DockerInfo.self, "/info") }
    func diskUsage() async throws -> DiskUsage { try await decode(DiskUsage.self, "/system/df") }

    func inspectJSON(_ path: String) async throws -> String {
        let data = try await data("GET", path)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// Real-time events for the object types the GUI cares about.
    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        let filters = #"{"type":["container","image","volume","network"]}"#
        return jsonLines(DockerEvent.self, "GET", "/events", query: ["filters": filters])
    }

    // MARK: Containers

    func containers() async throws -> [DockerContainer] {
        try await decode([DockerContainer].self, "/containers/json", query: ["all": "1"])
    }

    func containerAction(_ id: String, _ action: String) async throws {
        _ = try await data("POST", "/containers/\(seg(id))/\(action)", timeout: 90)
    }

    func removeContainer(_ id: String, force: Bool = true, volumes: Bool = false) async throws {
        _ = try await data("DELETE", "/containers/\(seg(id))", query: ["force": force ? "1" : "0", "v": volumes ? "1" : "0"], timeout: 90)
    }

    func inspectContainer(_ id: String) async throws -> String { try await inspectJSON("/containers/\(seg(id))/json") }

    func isTTY(_ id: String) async throws -> Bool {
        struct Inspect: Decodable {
            struct Config: Decodable { let Tty: Bool? }
            let Config: Config?
        }
        let data = try await data("GET", "/containers/\(seg(id))/json")
        return (try JSONDecoder().decode(Inspect.self, from: data)).Config?.Tty ?? false
    }

    /// Container logs (optionally following) as raw byte chunks; split them with LogDemuxer.
    func logStream(_ id: String, tail: Int, follow: Bool, timestamps: Bool) -> AsyncThrowingStream<Data, Error> {
        stream("GET", "/containers/\(seg(id))/logs", query: [
            "stdout": "1", "stderr": "1",
            "follow": follow ? "1" : "0",
            "tail": String(tail),
            "timestamps": timestamps ? "1" : "0",
        ])
    }

    func statsStream(_ id: String) -> AsyncThrowingStream<ContainerStats, Error> {
        jsonLines(ContainerStats.self, "GET", "/containers/\(seg(id))/stats", query: ["stream": "1"])
    }

    /// A single stats sample (Docker takes two readings to fill `precpu_stats`, about 1–2 s).
    func stats(_ id: String) async throws -> ContainerStats {
        try await decode(ContainerStats.self, "/containers/\(seg(id))/stats", query: ["stream": "0"])
    }

    /// Decoded container details (`GET /containers/{id}/json`).
    func containerDetails(_ id: String) async throws -> ContainerDetails {
        try await decode(ContainerDetails.self, "/containers/\(seg(id))/json")
    }

    /// Runs a command in the container (no TTY) and returns its output and exit code.
    /// The command runs inside the container via `sh -c`, never on the host.
    func exec(_ id: String, command: String, timeout: Int = 300) async throws -> (output: String, exitCode: Int) {
        try await exec(id, argv: ["sh", "-c", command], timeout: timeout)
    }

    /// Like `exec(_:command:)` but takes an argument array: user data travels via argv
    /// (e.g. `sh -c <constant script> sh <arg1> <arg2>`) and is never concatenated into a shell string.
    func exec(_ id: String, argv: [String], timeout: Int = 300) async throws -> (output: String, exitCode: Int) {
        let execID = try await createExec(id, command: argv)
        struct StartBody: Encodable, Sendable { let Detach = false; let Tty = false }
        let raw = try await json("POST", "/exec/\(seg(execID))/start", body: StartBody(), timeout: timeout)
        var demuxer = LogDemuxer(tty: false)
        let output = demuxer.feed(raw)
        return (output, try await execExitCode(execID) ?? -1)
    }

    /// Creates an exec instance (stdout + stderr attached, no TTY). Returns the exec ID.
    func createExec(_ id: String, command: [String]) async throws -> String {
        struct CreateBody: Encodable, Sendable {
            let Cmd: [String]
            let AttachStdout = true
            let AttachStderr = true
            let Tty = false
        }
        struct Created: Decodable { let Id: String }
        let data = try await json("POST", "/containers/\(seg(id))/exec", body: CreateBody(Cmd: command))
        return try JSONDecoder().decode(Created.self, from: data).Id
    }

    func execExitCode(_ execID: String) async throws -> Int? {
        struct ExecInspect: Decodable { let ExitCode: Int?; let Running: Bool? }
        let inspect = try JSONDecoder().decode(ExecInspect.self, from: try await data("GET", "/exec/\(seg(execID))/json"))
        return inspect.ExitCode
    }

    /// Starts the exec and writes its **stdout** to a file (atomically, with SHA-256); stderr goes to `onStderr`.
    func execToFile(
        _ execID: String,
        to destination: URL,
        timeout: Int,
        onStderr: @escaping @Sendable (Data) -> Void
    ) async throws -> FileTransfer {
        struct StartBody: Encodable, Sendable { let Detach = false; let Tty = false }
        let body = try JSONEncoder().encode(StartBody())
        let request = Self.buildRequest("POST", "/exec/\(seg(execID))/start", query: [:], contentType: "application/json", contentLength: body.count)
        return try await receiveToFile(request: request, body: body, destination: destination, timeout: timeout) { head, fd, sink in
            if !(200..<300).contains(head.status) {
                var payload = head.leftover
                try? Self.readAll(fd) { payload.append($0) }
                try Self.check(status: head.status, body: payload)
            }
            var parser = MultiplexedStreamParser()
            func route(_ data: Data) throws {
                for frame in parser.feed(data) {
                    if frame.stream == 1 { try sink(frame.payload) } else { onStderr(frame.payload) }
                }
            }
            try route(head.leftover)
            try Self.readAll(fd) { try route($0) }
            if parser.pendingCount > 0 { throw DockerError.socket(String(localized: "Exec stream was cut off midway")) }
        }
    }

    /// `POST /containers/create` with a JSON body; returns the new container ID. `name` is optional.
    func createContainer<Body: Encodable & Sendable>(name: String?, body: Body) async throws -> String {
        let data = try await json("POST", "/containers/create", query: name.map { ["name": $0] } ?? [:], body: body)
        return try JSONDecoder().decode(CreatedContainer.self, from: data).Id
    }

    /// Downloads `path` from a container as a tar (`GET /containers/{id}/archive`) into `destination`
    /// atomically, with SHA-256.
    func downloadArchive(container id: String, path: String, to destination: URL, timeout: Int) async throws -> FileTransfer {
        try await download("/containers/\(seg(id))/archive", query: ["path": path], to: destination, timeout: timeout)
    }

    /// Small archive (a few files) read into memory.
    func archiveData(container id: String, path: String) async throws -> Data {
        try await data("GET", "/containers/\(seg(id))/archive", query: ["path": path])
    }

    /// Extracts a tar file into a container at `path` (`PUT /containers/{id}/archive`).
    func uploadArchive(container id: String, path: String, tarFile: URL, timeout: Int) async throws {
        try await upload("PUT", "/containers/\(seg(id))/archive", query: ["path": path], file: tarFile, contentType: "application/x-tar", timeout: timeout)
    }

    // MARK: Images

    func images() async throws -> [DockerImage] { try await decode([DockerImage].self, "/images/json") }

    func removeImage(_ id: String, force: Bool) async throws {
        _ = try await data("DELETE", "/images/\(seg(id))", query: ["force": force ? "1" : "0"], timeout: 120)
    }

    func inspectImage(_ id: String) async throws -> String { try await inspectJSON("/images/\(seg(id))/json") }

    func imagePlatform(_ id: String) async throws -> ImagePlatform {
        try await decode(ImagePlatform.self, "/images/\(seg(id))/json")
    }

    /// Pulls an image, streaming progress. `reference` like `nginx`, `nginx:1.27`, `ghcr.io/x/y:tag` or `name@sha256:…`.
    func pull(_ reference: String) -> AsyncThrowingStream<PullProgress, Error> {
        var image = reference.trimmed
        var tag = "latest"
        if let at = image.firstIndex(of: "@") {
            tag = String(image[image.index(after: at)...])
            image = String(image[..<at])
        } else if let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") {
            tag = String(image[image.index(after: colon)...])
            image = String(image[..<colon])
        }
        return jsonLines(PullProgress.self, "POST", "/images/create", query: ["fromImage": image, "tag": tag])
    }

    /// `all = false`: dangling images only. `all = true`: every image not used by any container.
    func pruneImages(all: Bool) async throws -> PruneReport {
        let filters = all ? #"{"dangling":["false"]}"# : #"{"dangling":["true"]}"#
        return try JSONDecoder().decode(PruneReport.self, from: try await data("POST", "/images/prune", query: ["filters": filters], timeout: 300))
    }

    func imageExists(_ reference: String) async -> Bool {
        (try? await data("GET", "/images/\(seg(reference))/json")) != nil
    }

    // MARK: Volumes

    func volumes() async throws -> [DockerVolume] {
        try await decode(VolumeList.self, "/volumes").volumes ?? []
    }

    func createVolume(name: String, labels: [String: String] = [:]) async throws {
        struct Body: Encodable, Sendable { let Name: String; let Labels: [String: String] }
        _ = try await json("POST", "/volumes/create", body: Body(Name: name, Labels: labels))
    }

    func removeVolume(_ name: String, force: Bool = false) async throws {
        _ = try await data("DELETE", "/volumes/\(seg(name))", query: ["force": force ? "1" : "0"])
    }

    func inspectVolume(_ name: String) async throws -> String { try await inspectJSON("/volumes/\(seg(name))") }

    /// `all = true`: also removes named volumes (API ≥ 1.42); by default only anonymous volumes.
    /// `label`: prune only volumes with this label (`key` or `key=value`).
    func pruneVolumes(all: Bool, label: String? = nil) async throws -> PruneReport {
        let query = Self.pruneFilters(all: all, label: label).map { ["filters": $0] } ?? [:]
        return try JSONDecoder().decode(PruneReport.self, from: try await data("POST", "/volumes/prune", query: query, timeout: 300))
    }

    /// JSON `filters` for the prune endpoints; nil when no filter is needed.
    static func pruneFilters(all: Bool = false, label: String? = nil) -> String? {
        var filters: [String: [String]] = [:]
        if all { filters["all"] = ["true"] }
        if let label, !label.isEmpty { filters["label"] = [label] }
        guard !filters.isEmpty, let data = try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Networks

    func networks() async throws -> [DockerNetwork] { try await decode([DockerNetwork].self, "/networks") }

    func createNetwork(name: String, driver: String, subnet: String?, gateway: String?, isInternal: Bool,
                       labels: [String: String] = [:]) async throws {
        struct IPAMConfig: Encodable, Sendable { let Subnet: String; let Gateway: String? }
        struct IPAM: Encodable, Sendable { let Config: [IPAMConfig] }
        struct Body: Encodable, Sendable {
            let Name: String
            let Driver: String
            let Internal: Bool
            let IPAM: IPAM?
            let Labels: [String: String]
        }
        let ipam = subnet.map { IPAM(Config: [IPAMConfig(Subnet: $0, Gateway: gateway)]) }
        _ = try await json("POST", "/networks/create", body: Body(Name: name, Driver: driver, Internal: isInternal, IPAM: ipam, Labels: labels))
    }

    func removeNetwork(_ id: String) async throws { _ = try await data("DELETE", "/networks/\(seg(id))") }
    func inspectNetwork(_ id: String) async throws -> String { try await inspectJSON("/networks/\(seg(id))") }

    func connect(network: String, container: String) async throws {
        struct Body: Encodable, Sendable { let Container: String }
        _ = try await json("POST", "/networks/\(seg(network))/connect", body: Body(Container: container))
    }

    func disconnect(network: String, container: String) async throws {
        struct Body: Encodable, Sendable { let Container: String; let Force = false }
        _ = try await json("POST", "/networks/\(seg(network))/disconnect", body: Body(Container: container))
    }

    // MARK: Storage

    func pruneBuildCache() async throws -> PruneReport {
        try JSONDecoder().decode(PruneReport.self, from: try await data("POST", "/build/prune", timeout: 600))
    }

    func pruneStoppedContainers() async throws -> PruneReport {
        try JSONDecoder().decode(PruneReport.self, from: try await data("POST", "/containers/prune", timeout: 300))
    }

    /// `label`: prune only networks with this label (`key` or `key=value`).
    func pruneNetworks(label: String? = nil) async throws {
        let query = Self.pruneFilters(label: label).map { ["filters": $0] } ?? [:]
        _ = try await data("POST", "/networks/prune", query: query, timeout: 120)
    }
}

/// Response of `POST /containers/create`.
private struct CreatedContainer: Decodable { let Id: String }
