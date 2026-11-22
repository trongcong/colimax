import Foundation

/// The Docker Engine operations the stores and screens use. `DockerClient` is the real implementation;
/// tests and the UI-test build substitute a fake so stores can run without a VM.
///
/// Requirements spell out every parameter (no defaults): call sites through `any DockerEngine` pass them
/// explicitly. Every service (backup, restore, proxy, Elasticsearch included) takes `any DockerEngine`, so
/// the whole app, file and archive transfers included, can run against `FakeDocker`.
protocol DockerEngine: Sendable {
    // System
    func ping(timeout: Int) async throws
    func info() async throws -> DockerInfo
    func diskUsage() async throws -> DiskUsage
    func events() -> AsyncThrowingStream<DockerEvent, Error>

    // Containers
    func containers() async throws -> [DockerContainer]
    func containerAction(_ id: String, _ action: String) async throws
    func removeContainer(_ id: String, force: Bool, volumes: Bool) async throws
    func inspectContainer(_ id: String) async throws -> String
    func containerDetails(_ id: String) async throws -> ContainerDetails
    func isTTY(_ id: String) async throws -> Bool
    func logStream(_ id: String, tail: Int, follow: Bool, timestamps: Bool) -> AsyncThrowingStream<Data, Error>
    func statsStream(_ id: String) -> AsyncThrowingStream<ContainerStats, Error>
    func stats(_ id: String) async throws -> ContainerStats
    func exec(_ id: String, command: String, timeout: Int) async throws -> (output: String, exitCode: Int)
    func pruneStoppedContainers() async throws -> PruneReport
    func createContainer<Body: Encodable & Sendable>(name: String?, body: Body) async throws -> String

    // Exec
    func exec(_ id: String, argv: [String], timeout: Int) async throws -> (output: String, exitCode: Int)
    func createExec(_ id: String, command: [String]) async throws -> String
    func execExitCode(_ execID: String) async throws -> Int?
    /// Starts an exec and writes its stdout to a file (atomically, with SHA-256); stderr goes to `onStderr`.
    func execToFile(_ execID: String, to destination: URL, timeout: Int,
                    onStderr: @escaping @Sendable (Data) -> Void) async throws -> DockerClient.FileTransfer

    // Archives (file transfer)
    func downloadArchive(container id: String, path: String, to destination: URL, timeout: Int) async throws -> DockerClient.FileTransfer
    func archiveData(container id: String, path: String) async throws -> Data
    func uploadArchive(container id: String, path: String, tarFile: URL, timeout: Int) async throws
    /// Uploads one file into `directory` of the container, wrapped as a single-entry tar on the fly.
    func uploadAsTar(container id: String, directory: String, file: URL, entryName: String, mode: Int, timeout: Int) async throws

    // Images
    func images() async throws -> [DockerImage]
    func removeImage(_ id: String, force: Bool) async throws
    func inspectImage(_ id: String) async throws -> String
    func imagePlatform(_ id: String) async throws -> ImagePlatform
    func pull(_ reference: String) -> AsyncThrowingStream<PullProgress, Error>
    func pruneImages(all: Bool) async throws -> PruneReport
    func pruneBuildCache() async throws -> PruneReport
    func imageExists(_ reference: String) async -> Bool

    // Volumes
    func volumes() async throws -> [DockerVolume]
    func createVolume(name: String, labels: [String: String]) async throws
    func removeVolume(_ name: String, force: Bool) async throws
    func inspectVolume(_ name: String) async throws -> String
    func pruneVolumes(all: Bool, label: String?) async throws -> PruneReport

    // Networks
    func networks() async throws -> [DockerNetwork]
    func createNetwork(name: String, driver: String, subnet: String?, gateway: String?, isInternal: Bool,
                       labels: [String: String]) async throws
    func removeNetwork(_ id: String) async throws
    func inspectNetwork(_ id: String) async throws -> String
    func connect(network: String, container: String) async throws
    func disconnect(network: String, container: String) async throws
    func pruneNetworks(label: String?) async throws
}

extension DockerClient: DockerEngine {}
