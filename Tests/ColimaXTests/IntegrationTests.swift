import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// Integration tests against real Colima + Docker. Run only when `COLIMAX_INTEGRATION=1`
/// (profile: `COLIMAX_PROFILE`, default `default`). Every resource created uses the
/// `colimax-test-<id>` prefix + the `dev.colimax.test` label and is removed in tearDown.
/// Never touches the user's existing containers / volumes / networks.
final class IntegrationTests: XCTestCase {
    private var client: DockerClient!
    private let prefix = "colimax-test-\(UUID().uuidString.prefix(6).lowercased())"
    private var createdContainers: [String] = []
    private var createdVolumes: [String] = []
    private var createdNetworks: [String] = []
    private var createdComposeProjects: [ComposeProject] = []
    /// Images created (commit) or newly pulled by tests; only images absent before the run are removed.
    private var createdImages: [String] = []
    private var profile = "default"
    private var dir: URL!
    /// Label unique to this run: any prune in tests must filter on it.
    private var runLabel: String { "\(Self.testLabel)=\(prefix)" }
    private static let testLabel = "dev.colimax.test"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["COLIMAX_INTEGRATION"] == "1" else {
            throw XCTSkip("Set COLIMAX_INTEGRATION=1 to run integration tests (requires a running Colima VM)")
        }
        profile = ProcessInfo.processInfo.environment["COLIMAX_PROFILE"] ?? "default"
        let status = try? await ColimaService.status(profile)
        client = DockerClient(socketPath: ColimaService.resolveDockerSocket(profile, status: status))
        do { try await client.ping() } catch {
            throw XCTSkip("Docker for profile \(profile) is not responding: \(error.localizedDescription)")
        }
        dir = TestSupport.tempRoot.appendingPathComponent(prefix)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        guard let client else { return }
        for project in createdComposeProjects {
            _ = try? await Shell.run("docker", ComposeService.baseArguments(project) + ["down", "--remove-orphans"],
                                     env: ComposeService.environment(socketPath: client.socketPath), timeout: 120)
        }
        for id in createdContainers { try? await client.removeContainer(id, force: true, volumes: false) }
        for name in createdNetworks { try? await client.removeNetwork(name) }
        for name in createdVolumes { try? await client.removeVolume(name, force: true) }
        for image in createdImages { try? await client.removeImage(image, force: false) }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Helpers

    private func ensureImage(_ reference: String) async throws {
        if await client.imageExists(reference) { return }
        for try await progress in client.pull(reference) {
            if let error = progress.error { throw DockerError.socket(error) }
        }
    }

    private func runContainer(image: String, name: String, cmd: [String]? = nil, binds: [String] = [], env: [String] = []) async throws -> String {
        try await createContainer(image: image, name: name, cmd: cmd, binds: binds, env: env)
    }

    /// Creates a test container (label `dev.colimax.test=<prefix>`), started by default.
    /// `ports`: "8080/tcp" → (host IP, host port).
    private func createContainer(image: String, name: String, cmd: [String]? = nil, binds: [String] = [], env: [String] = [],
                                 ports: [String: (ip: String, port: Int)] = [:], privileged: Bool = false,
                                 network: String? = nil, labels: [String: String] = [:], start: Bool = true) async throws -> String {
        try await ensureImage(image)
        struct Empty: Encodable, Sendable {}
        struct Binding: Encodable, Sendable { let HostIp: String; let HostPort: String }
        struct HostConfig: Encodable, Sendable {
            let Binds: [String]
            let PortBindings: [String: [Binding]]
            let Privileged: Bool
            let NetworkMode: String?
        }
        struct Body: Encodable, Sendable {
            let Image: String
            let Cmd: [String]?
            let Env: [String]
            let Labels: [String: String]
            let ExposedPorts: [String: Empty]
            let HostConfig: HostConfig
        }
        struct Created: Decodable { let Id: String }
        let body = Body(
            Image: image, Cmd: cmd, Env: env,
            Labels: labels.merging([Self.testLabel: prefix]) { current, _ in current },
            ExposedPorts: ports.mapValues { _ in Empty() },
            HostConfig: HostConfig(Binds: binds, PortBindings: ports.mapValues { [Binding(HostIp: $0.ip, HostPort: String($0.port))] },
                                   Privileged: privileged, NetworkMode: network))
        let data = try await client.json("POST", "/containers/create", query: ["name": name], body: body)
        let id = try JSONDecoder().decode(Created.self, from: data).Id
        createdContainers.append(id)
        if start { try await client.containerAction(id, "start") }
        return id
    }

    /// A free TCP port on the Mac (127.0.0.1), picked at random from a high range.
    private func freeHostPort() throws -> Int {
        for _ in 0..<50 {
            let port = Int.random(in: 20_000..<40_000)
            if !PortProbe.isInUse(port) { return port }
        }
        throw XCTSkip("Could not find a free port on the Mac")
    }

    /// Waits up to `seconds` for the container to reach state `exited`.
    private func waitForExit(_ id: String, seconds: Int = 30) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if try await container(id).state == "exited" { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTFail("Container \(id) did not exit")
    }

    /// Creates a test network with a random 10.231.x.0/24 subnet; retries if it overlaps another network.
    private func createTestNetwork(_ name: String) async throws -> (subnet: String, gateway: String) {
        var lastError: Error?
        for _ in 0..<8 {
            let octet = Int.random(in: 1...254)
            let subnet = "10.231.\(octet).0/24", gateway = "10.231.\(octet).1"
            do {
                try await client.createNetwork(name: name, driver: "bridge", subnet: subnet, gateway: gateway, isInternal: false,
                                               labels: [Self.testLabel: prefix])
                createdNetworks.append(name)
                return (subnet, gateway)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    private func container(_ id: String) async throws -> DockerContainer {
        let all = try await client.containers()
        return try XCTUnwrap(all.first { $0.id == id })
    }

    // MARK: Tests

    func testInfoAndListing() async throws {
        let info = try await client.info()
        XCTAssertFalse(info.serverVersion.isEmpty)
        _ = try await client.containers()
        _ = try await client.images()
        _ = try await client.volumes()
        let networks = try await client.networks()
        XCTAssertTrue(networks.contains { $0.name == "bridge" })
        _ = try await client.diskUsage()
    }

    func testContainerDetailsExecAndPlatform() async throws {
        let id = try await runContainer(image: "busybox:latest", name: "\(prefix)-c", cmd: ["sleep", "300"], env: ["APP_TOKEN=abc"])
        let details = try await client.containerDetails(id)
        XCTAssertEqual(details.state?.running, true)
        XCTAssertEqual(details.restartCount, 0)
        XCTAssertFalse(details.oomKilled)
        XCTAssertEqual(details.environment.first { $0.key == "APP_TOKEN" }?.isSensitive, true)

        let result = try await client.exec(id, command: "echo hi; echo err >&2; exit 3")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.output.contains("hi"))

        let images = try await client.images()
        let image = try XCTUnwrap(images.first { $0.tags.contains("busybox:latest") })
        let platform = try await client.imagePlatform(image.id)
        XCTAssertNotNil(platform.architecture)
        if HostPlatform.isAppleSilicon { XCTAssertTrue(platform.isNativeARM64, "multi-arch busybox should resolve to arm64") }
    }

    func testNetworkConnectDisconnect() async throws {
        let net = "\(prefix)-net"
        try await client.createNetwork(name: net, driver: "bridge", subnet: nil, gateway: nil, isInternal: false)
        createdNetworks.append(net)
        let id = try await runContainer(image: "busybox:latest", name: "\(prefix)-n", cmd: ["sleep", "300"])
        try await client.connect(network: net, container: id)
        let connected = try await container(id)
        XCTAssertTrue(connected.networkNames.contains(net))
        try await client.disconnect(network: net, container: id)
        let disconnected = try await container(id)
        XCTAssertFalse(disconnected.networkNames.contains(net))
    }

    func testVolumeBackupVerifyRestoreRoundTrip() async throws {
        let source = "\(prefix)-src"
        let target = "\(prefix)-dst"
        try await client.createVolume(name: source)
        createdVolumes += [source, target]
        let writer = try await runContainer(image: "busybox:latest", name: "\(prefix)-w", cmd: ["sleep", "300"], binds: ["\(source):/data"])
        let written = try await client.exec(writer, command: "echo colimax-payload > /data/hello.txt && mkdir -p /data/sub && echo nested > /data/sub/n.txt")
        XCTAssertEqual(written.exitCode, 0)

        let file = dir.appendingPathComponent("backup.tar")
        let manifest = try await VolumeBackup.backup(volume: source, to: file, client: client)
        XCTAssertGreaterThan(manifest.size, 0)
        guard case .verified = try await BackupVerifier.verify(file) else { return XCTFail("should match the manifest") }
        XCTAssertNoThrow(try TarInspector.validateVolumeArchive(file))

        try await VolumeBackup.restore(volume: target, from: file, client: client)
        let reader = try await runContainer(image: "busybox:latest", name: "\(prefix)-r", cmd: ["sleep", "300"], binds: ["\(target):/data:ro"])
        let read = try await client.exec(reader, command: "cat /data/hello.txt /data/sub/n.txt")
        XCTAssertEqual(read.output, "colimax-payload\nnested\n")

        // The helper container has been removed.
        let helpers = try await client.containers().filter { $0.labels?[VolumeBackup.helperLabel] != nil && $0.volumeNames.contains(source) }
        XCTAssertEqual(helpers.count, 0)
    }

    func testRedisLogicalBackup() async throws {
        let id = try await runContainer(image: "redis:7-alpine", name: "\(prefix)-redis")
        // Wait for redis to be ready.
        for _ in 0..<20 {
            if (try? await client.exec(id, command: "redis-cli ping"))?.output.contains("PONG") == true { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        _ = try await client.exec(id, command: "redis-cli set colimax ok")
        let file = dir.appendingPathComponent("redis.rdb")
        let manifest = try await DatabaseBackup.backup(container: try await container(id), engine: .redis, to: file, client: client)
        XCTAssertEqual(manifest.kind, .redis)
        let head = try FileHandle(forReadingFrom: file).read(upToCount: 5)
        XCTAssertEqual(head, Data("REDIS".utf8))
        guard case .verified = try await BackupVerifier.verify(file) else { return XCTFail() }
    }

    func testDatabaseBackupFailureLeavesNoFile() async throws {
        // busybox has no pg_dumpall: non-zero exit, and no destination file is created.
        let id = try await runContainer(image: "busybox:latest", name: "\(prefix)-fake", cmd: ["sleep", "300"])
        let file = dir.appendingPathComponent("fake.sql")
        do {
            try await DatabaseBackup.backup(container: try await container(id), engine: .postgres, to: file, client: client)
            XCTFail()
        } catch let error as BackupError {
            guard case .dumpFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackupManifest.url(for: file).path))
    }

    func testCancelledLogStreamClosesQuickly() async throws {
        let id = try await runContainer(image: "busybox:latest", name: "\(prefix)-log", cmd: ["sh", "-c", "while true; do echo tick; sleep 1; done"])
        let start = Date()
        let stream = client.logStream(id, tail: 10, follow: true, timestamps: false)
        let task = Task {
            var chunks = 0
            for try await _ in stream { chunks += 1 }
            return chunks
        }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: Database backup / restore (G9, G21)

    /// Waits up to `seconds` for `command` (run inside the container) to exit 0.
    private func waitUntil(_ id: String, _ command: String, seconds: Int = 120) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if let result = try? await client.exec(id, command: command), result.exitCode == 0 { return }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("Timed out waiting for: \(command)")
        throw CancellationError()
    }

    /// Create data -> back up -> delete data -> restore -> data is back.
    private func roundTrip(engine: DatabaseEngine, image: String, env: [String], ready: String,
                           seed: String, drop: String, check: String, expected: String) async throws {
        let id = try await runContainer(image: image, name: "\(prefix)-\(engine.rawValue)", env: env)
        try await waitUntil(id, ready, seconds: 180)
        let seeded = try await client.exec(id, command: seed)
        XCTAssertEqual(seeded.exitCode, 0, seeded.output)

        let file = dir.appendingPathComponent("\(engine.rawValue).\(engine.fileExtension)")
        let manifest = try await DatabaseBackup.backup(container: try await container(id), engine: engine, to: file, client: client)
        XCTAssertEqual(manifest.kind, engine.manifestKind)
        guard case .verified = try await BackupVerifier.verify(file) else { return XCTFail("should match the manifest") }
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("colimax_t"))

        let dropped = try await client.exec(id, command: drop)
        XCTAssertEqual(dropped.exitCode, 0, dropped.output)
        let missing = try await client.exec(id, command: check)
        XCTAssertFalse(missing.output.contains(expected), "data should be gone before restore")

        let outcome = try await DatabaseRestore.restore(file: file, into: try await container(id), engine: engine, client: client)
        XCTAssertEqual(outcome.warnings, [])
        let restored = try await client.exec(id, command: check)
        XCTAssertTrue(restored.output.contains(expected), restored.output)
        let staging = try await client.exec(id, command: "test -e \(DatabaseRestore.stagingDirectory)/\(DatabaseRestore.stagingName)")
        XCTAssertNotEqual(staging.exitCode, 0, "the temporary dump file inside the container should be removed")
    }

    func testMySQLBackupRestoreRoundTrip() async throws {
        let sql = #"mysql -h127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD""#
        try await roundTrip(
            engine: .mysql, image: "mysql:8.4", env: ["MYSQL_ROOT_PASSWORD=colimax-test"],
            ready: "\(sql) -e 'SELECT 1'",
            seed: "\(sql) -e \"CREATE DATABASE colimax_t; CREATE TABLE colimax_t.items (v VARCHAR(20)); INSERT INTO colimax_t.items VALUES ('restored-ok');\"",
            drop: "\(sql) -e 'DROP DATABASE colimax_t'",
            check: "\(sql) -N -e 'SELECT v FROM colimax_t.items' 2>&1 || true",
            expected: "restored-ok")
    }

    func testMariaDBBackupRestoreRoundTrip() async throws {
        let sql = #"mariadb -h127.0.0.1 -uroot -p"$MARIADB_ROOT_PASSWORD""#
        try await roundTrip(
            engine: .mariadb, image: "mariadb:11", env: ["MARIADB_ROOT_PASSWORD=colimax-test"],
            ready: "\(sql) -e 'SELECT 1'",
            seed: "\(sql) -e \"CREATE DATABASE colimax_t; CREATE TABLE colimax_t.items (v VARCHAR(20)); INSERT INTO colimax_t.items VALUES ('restored-ok');\"",
            drop: "\(sql) -e 'DROP DATABASE colimax_t'",
            check: "\(sql) -N -e 'SELECT v FROM colimax_t.items' 2>&1 || true",
            expected: "restored-ok")
    }

    func testPostgresBackupRestoreRoundTrip() async throws {
        try await roundTrip(
            engine: .postgres, image: "postgres:16-alpine", env: ["POSTGRES_PASSWORD=colimax-test"],
            ready: "pg_isready -h 127.0.0.1 -U postgres && psql -h 127.0.0.1 -U postgres -c 'SELECT 1'",
            seed: "psql -U postgres -c 'CREATE DATABASE colimax_t' && psql -U postgres -d colimax_t -c \"CREATE TABLE items (v text); INSERT INTO items VALUES ('restored-ok');\"",
            drop: "psql -U postgres -c 'DROP DATABASE colimax_t'",
            check: "psql -U postgres -d colimax_t -tA -c 'SELECT v FROM items' 2>&1 || true",
            expected: "restored-ok")
    }

    func testRedisRestoreRoundTrip() async throws {
        let id = try await runContainer(image: "redis:7-alpine", name: "\(prefix)-redis-rs")
        try await waitUntil(id, "redis-cli ping | grep -q PONG")
        _ = try await client.exec(id, command: "redis-cli set colimax restored-ok")
        let file = dir.appendingPathComponent("redis.rdb")
        try await DatabaseBackup.backup(container: try await container(id), engine: .redis, to: file, client: client)
        _ = try await client.exec(id, command: "redis-cli flushall && redis-cli save")
        try await DatabaseRestore.restore(file: file, into: try await container(id), engine: .redis, client: client)
        try await waitUntil(id, "redis-cli ping | grep -q PONG")
        let value = try await client.exec(id, command: "redis-cli get colimax")
        XCTAssertEqual(value.output.trimmed, "restored-ok")
    }

    // MARK: Compose (G15)

    func testComposeLifecycle() async throws {
        guard ComposeService.isAvailable,
              let version = try? await Shell.run("docker", ["compose", "version"], timeout: 20), version.ok
        else { throw XCTSkip("Requires the docker CLI + compose plugin") }
        try await ensureImage("busybox:latest")

        let projectDir = dir.appendingPathComponent("compose")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let yaml = """
        services:
          app:
            image: busybox:latest
            command: ["sh", "-c", "echo colimax-compose-log; sleep 300"]
            labels:
              dev.colimax.test: "1"
        """
        try yaml.write(to: projectDir.appendingPathComponent("compose.yaml"), atomically: false, encoding: .utf8)
        let found = try XCTUnwrap(ComposeDiscovery.scan(projectDir))
        let project = ComposeProject(name: prefix, workingDir: projectDir.path, configFiles: found.files.map(\.path))
        XCTAssertTrue(ComposeProject.isValidName(project.name))
        let socket = client.socketPath
        createdComposeProjects.append(project) // tearDown runs `down` even if the test fails midway

        let validation = try await ComposeService.validate(project: project, socketPath: socket)
        XCTAssertNil(validation)
        let services = try await ComposeService.services(project: project, socketPath: socket)
        XCTAssertEqual(services, ["app"])
        let config = try await ComposeService.config(project: project, socketPath: socket)
        XCTAssertTrue(config.contains("busybox"))

        for try await _ in ComposeService.run(.up, project: project, socketPath: socket) {}
        var running = try await client.containers().filter { $0.composeProject == prefix }
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.composeService, "app")
        XCTAssertEqual(running.first?.isRunning, true)

        for try await _ in ComposeService.run(.restart, service: "app", project: project, socketPath: socket) {}
        running = try await client.containers().filter { $0.composeProject == prefix }
        XCTAssertEqual(running.first?.isRunning, true)

        var sawLog = false
        for try await line in ComposeService.logs(project: project, service: "app", tail: 20, socketPath: socket) {
            if line.contains("colimax-compose-log") { sawLog = true; break }
        }
        XCTAssertTrue(sawLog)

        for try await _ in ComposeService.run(.down, project: project, socketPath: socket) {}
        let left = try await client.containers().filter { $0.composeProject == prefix }
        XCTAssertTrue(left.isEmpty)

        // Malformed compose file: validate reports an error instead of throwing.
        try "services: [".write(to: projectDir.appendingPathComponent("compose.yaml"), atomically: false, encoding: .utf8)
        let invalid = try await ComposeService.validate(project: project, socketPath: socket)
        XCTAssertNotNil(invalid)
    }

    // MARK: Elasticsearch snapshot (G25): heavy image, runs only with COLIMAX_INTEGRATION_ES=1

    func testElasticsearchSnapshotRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["COLIMAX_INTEGRATION_ES"] == "1" else {
            throw XCTSkip("Set COLIMAX_INTEGRATION_ES=1 to run (pulls a ~1 GB Elasticsearch image, needs ~1 GB RAM)")
        }
        let id = try await runContainer(
            image: "docker.elastic.co/elasticsearch/elasticsearch:8.15.3", name: "\(prefix)-es",
            env: ["discovery.type=single-node", "xpack.security.enabled=false", "ES_JAVA_OPTS=-Xms512m -Xmx512m",
                  "path.repo=/usr/share/elasticsearch/snapshots"])
        try await waitUntil(id, "curl -fsS localhost:9200/_cluster/health?wait_for_status=yellow", seconds: 240)
        _ = try await ElasticsearchSnapshot.request("PUT", "/colimax-docs/_doc/1?refresh=true", body: #"{"v":"restored-ok"}"#, container: id, client: client)

        let location = try await ElasticsearchSnapshot.ensureRepository(container: id, client: client)
        XCTAssertEqual(location, "/usr/share/elasticsearch/snapshots/colimax")
        try await ElasticsearchSnapshot.create("s1", container: id, client: client)
        let listed = try await ElasticsearchSnapshot.list(container: id, client: client)
        let snapshot = try XCTUnwrap(listed.first { $0.name == "s1" })
        XCTAssertEqual(snapshot.state, "SUCCESS")
        XCTAssertTrue(snapshot.indices.contains("colimax-docs"))

        try await ElasticsearchSnapshot.restore(snapshot, mode: .renamed, container: id, client: client)
        let copy = try await ElasticsearchSnapshot.request("GET", "/restored-colimax-docs/_doc/1", container: id, client: client)
        XCTAssertTrue(copy.contains("restored-ok"))

        _ = try await ElasticsearchSnapshot.request("DELETE", "/colimax-docs", container: id, client: client)
        try await ElasticsearchSnapshot.restore(snapshot, mode: .replace, container: id, client: client)
        let original = try await ElasticsearchSnapshot.request("GET", "/colimax-docs/_doc/1", container: id, client: client)
        XCTAssertTrue(original.contains("restored-ok"))

        let file = dir.appendingPathComponent("es.tar")
        let manifest = try await ElasticsearchSnapshot.export(location: location, container: try await container(id), to: file, client: client)
        XCTAssertEqual(manifest.kind, .elasticsearch)
        guard case .verified = try await BackupVerifier.verify(file) else { return XCTFail() }

        try await ElasticsearchSnapshot.delete("s1", container: id, client: client)
        let remaining = try await ElasticsearchSnapshot.list(container: id, client: client)
        XCTAssertFalse(remaining.contains { $0.name == "s1" })
    }

    // MARK: Local domain proxy (G23)

    func testLocalProxyRoutesByHost() async throws {
        let settings = ProxySettings(httpPort: 18_080, httpsPort: 18_443, https: false)
        for port in [settings.httpPort, settings.httpsPort] where PortProbe.isInUse(port) {
            throw XCTSkip("Port \(port) on the Mac is in use")
        }
        let web = try await runContainer(image: "busybox:latest", name: "\(prefix)-web",
                                         cmd: ["sh", "-c", "mkdir -p /www && echo colimax-proxy-ok > /www/index.html && httpd -f -p 8080 -h /www"])
        let proxyName = "\(prefix)-proxy"
        let volume = "\(prefix)-proxydata"
        createdVolumes.append(volume)
        let proxyID = try await LocalProxy.create(settings: settings, client: client, name: proxyName, volume: volume,
                                                  extraLabels: ["dev.colimax.test": "1"])
        createdContainers.insert(proxyID, at: 0)
        let status = try await LocalProxy.status(client: client, name: proxyName)
        XCTAssertTrue(status.exists)

        let routes = [ProxyRoute(subdomain: "web", container: "\(prefix)-web", port: 8080),
                      ProxyRoute(subdomain: "ghost", container: "\(prefix)-missing", port: 80)]
        let skipped = try await LocalProxy.apply(routes: routes, settings: settings, proxyID: proxyID, client: client)
        XCTAssertEqual(skipped.count, 1, "a route to a missing container is skipped without breaking the config")

        // Trong VM: proxy (host network) → IP container.
        try await waitUntil(proxyID, "wget -qO- --header 'Host: web.localhost' http://127.0.0.1:18080/ | grep -q colimax-proxy-ok", seconds: 30)

        // From the Mac, via Colima's port forwarding.
        var reached = false
        for _ in 0..<20 {
            if let result = try? await Shell.run("curl", ["-s", "--max-time", "2", "-H", "Host: web.localhost", "http://127.0.0.1:18080/"], timeout: 5),
               result.stdout.contains("colimax-proxy-ok") { reached = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(reached, "the Mac cannot reach the proxy at 127.0.0.1:18080")

        // The proxy joins none of the user's networks.
        let proxyNetworks = try await client.containerDetails(proxyID).networkSettings?.networks?.keys.sorted() ?? []
        XCTAssertEqual(proxyNetworks, ["host"])

        // HTTPS: Caddy creates an internal CA and its root cert can be fetched.
        let httpsSettings = ProxySettings(httpPort: 18_080, httpsPort: 18_443, https: true)
        try await LocalProxy.apply(routes: [routes[0]], settings: httpsSettings, proxyID: proxyID, client: client)
        var pem: Data?
        for _ in 0..<20 {
            pem = try? await LocalProxy.rootCertificate(proxyID: proxyID, client: client)
            if pem != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertNotNil(pem, "Caddy should generate a root CA when an HTTPS site exists")
        _ = web
    }

    // MARK: Manual checklist, automated (Diagnostics, Storage, Volumes/Networks, Images, Backups, Monitoring)

    /// Checklist: "privileged containers and 0.0.0.0 binds are reported; results contain no secret values".
    func testSecurityAuditOnRealContainer() async throws {
        let port = try freeHostPort()
        let secret = "colimax-secret-\(UUID().uuidString)"
        let id = try await createContainer(image: "busybox:latest", name: "\(prefix)-sec", cmd: ["sleep", "300"],
                                           env: ["APP_TOKEN=\(secret)", "PLAIN=visible"],
                                           ports: ["8080/tcp": ("0.0.0.0", port)], privileged: true)
        let details = try await client.containerDetails(id)

        for reachable in [false, true] {
            let items = SecurityAudit.check([details], vmReachableFromNetwork: reachable).filter { $0.containerID == id }
            XCTAssertTrue(items.contains { $0.severity == .critical && $0.title.hasSuffix(": privileged") }, "\(items)")
            let portItem = try XCTUnwrap(items.first { $0.detail.contains("\(port)→8080/tcp") }, "expected a 0.0.0.0 port bind finding: \(items)")
            XCTAssertEqual(portItem.severity, reachable ? .warning : .info)
            let secretItem = try XCTUnwrap(items.first { $0.detail.contains("APP_TOKEN") }, "expected a secret-in-env finding")
            XCTAssertFalse(secretItem.detail.contains("PLAIN"))
            for item in items {
                for text in [item.title, item.detail, item.recommendation ?? "", item.id] {
                    XCTAssertFalse(text.contains(secret), "secret value leaked: \(text)")
                }
            }
        }
    }

    /// Checklist: "ports held by a host process are reported": a real listening socket on the Mac + a (stopped) container declaring the same port.
    func testPortHeldByHostProcessIsReported() async throws {
        let port = try freeHostPort()
        let listener = try XCTUnwrap(HostListener(port: port), "could not open a listening socket on 127.0.0.1:\(port)")
        let id = try await createContainer(image: "busybox:latest", name: "\(prefix)-port", cmd: ["sleep", "300"],
                                           ports: ["80/tcp": ("127.0.0.1", port)], start: false)
        let details = try await client.containerDetails(id)
        XCTAssertEqual(details.declaredHostPorts.map(\.port), [port])

        let probed = await BlockingIOPortProbe.inUse(ports: Set(details.declaredHostPorts.map(\.port)))
        XCTAssertEqual(probed, [port])
        let items = PortDiagnostics.check([details]) { probed.contains($0) }.filter { $0.containerID == id }
        let item = try XCTUnwrap(items.first, "a port held by a Mac process should be reported")
        XCTAssertEqual(item.severity, .warning)
        XCTAssertTrue(item.title.contains(String(port)), item.title)
        XCTAssertEqual(item.detail, String(localized: "A process on the Mac is using this port; starting the container will fail."))

        listener.close()
        XCTAssertFalse(PortProbe.isInUse(port))
        XCTAssertTrue(PortDiagnostics.check([details], isInUse: PortProbe.isInUse).filter { $0.containerID == id }.isEmpty,
                      "port released: warning should clear")
    }

    /// Storage checklist: a real `/system/df` lists orphaned volumes, dangling images and stopped containers.
    func testStorageReportWithRealDiskUsage() async throws {
        let orphan = "\(prefix)-orphan", used = "\(prefix)-used"
        try await client.createVolume(name: orphan, labels: [Self.testLabel: prefix])
        try await client.createVolume(name: used, labels: [Self.testLabel: prefix])
        createdVolumes += [orphan, used]
        let runner = try await runContainer(image: "busybox:latest", name: "\(prefix)-user", cmd: ["sleep", "300"], binds: ["\(used):/data"])
        let exited = try await runContainer(image: "busybox:latest", name: "\(prefix)-exited", cmd: ["sh", "-c", "echo x > /marker"])
        try await waitForExit(exited)

        // Dangling image: commit a container without repo/tag.
        struct Commit: Encodable, Sendable { let Labels: [String: String] }
        struct Created: Decodable { let Id: String }
        let committed = try await client.json("POST", "/commit", query: ["container": exited], body: Commit(Labels: [Self.testLabel: prefix]))
        let imageID = try JSONDecoder().decode(Created.self, from: committed).Id
        createdImages.append(imageID)

        let report = StorageReport.analyze(try await client.diskUsage(), containers: try await client.containers())
        XCTAssertTrue(report.unusedVolumes.contains { $0.name == orphan }, "orphaned volume should be listed")
        XCTAssertFalse(report.unusedVolumes.contains { $0.name == used }, "a mounted volume must not count as orphaned")
        XCTAssertTrue(report.danglingImages.contains { $0.id == imageID }, "an untagged committed image should be dangling")
        XCTAssertFalse(report.unusedImages.contains { $0.id == imageID })
        let stopped = try XCTUnwrap(report.stoppedContainers.first { $0.id == exited }, "exited container should be listed")
        XCTAssertEqual(stopped.name, "\(prefix)-exited")
        XCTAssertEqual(stopped.detail, "exited")
        XCTAssertFalse(report.stoppedContainers.contains { $0.id == runner })
    }

    /// Volumes / Networks checklist: create / delete, subnet + gateway; prune filters **only** on this run's label.
    func testVolumeAndNetworkLifecycleWithScopedPrune() async throws {
        let labels = [Self.testLabel: prefix]
        let pruneMe = "\(prefix)-v-prune", keep = "\(prefix)-v-inuse", removeMe = "\(prefix)-v-rm"
        for name in [pruneMe, keep, removeMe] { try await client.createVolume(name: name, labels: labels) }
        createdVolumes += [pruneMe, keep, removeMe]
        try await client.removeVolume(removeMe)
        let volumes = try await client.volumes()
        XCTAssertFalse(volumes.contains { $0.name == removeMe })
        XCTAssertEqual(volumes.first { $0.name == pruneMe }?.labels?[Self.testLabel], prefix)

        let netA = "\(prefix)-net-a", netB = "\(prefix)-net-b"
        let (subnet, gateway) = try await createTestNetwork(netA)
        _ = try await createTestNetwork(netB)
        let networks = try await client.networks()
        let created = try XCTUnwrap(networks.first { $0.name == netA })
        XCTAssertEqual(created.ipam?.config?.first?.subnet, subnet)
        XCTAssertEqual(created.ipam?.config?.first?.gateway, gateway)
        XCTAssertEqual(created.labels?[Self.testLabel], prefix)

        // keep is mounted and netA has a container, so prune must not remove them.
        _ = try await createContainer(image: "busybox:latest", name: "\(prefix)-holder", cmd: ["sleep", "300"],
                                      binds: ["\(keep):/data"], network: netA)

        let volumesBefore = Set(try await client.volumes().map(\.name))
        _ = try await client.pruneVolumes(all: true, label: runLabel)
        let volumesAfter = Set(try await client.volumes().map(\.name))
        XCTAssertEqual(volumesBefore.subtracting(volumesAfter), [pruneMe], "prune should remove only the unused test volume")
        XCTAssertTrue(volumesAfter.contains(keep))

        let networksBefore = Set(try await client.networks().map(\.name))
        try await client.pruneNetworks(label: runLabel)
        let networksAfter = Set(try await client.networks().map(\.name))
        XCTAssertEqual(networksBefore.subtracting(networksAfter), [netB], "prune should remove only the unused test network")
        XCTAssertTrue(networksAfter.contains(netA))
    }

    /// Images checklist: pull reports progress; invalid references are rejected; pull failures are reported.
    func testPullImageReportsProgress() async throws {
        let reference = "busybox:1.36"
        XCTAssertTrue(ImageReference.isValid(reference))
        XCTAssertFalse(ImageReference.isValid("--help"))
        let existed = await client.imageExists(reference)
        var events = 0
        var statuses: [String] = []
        for try await progress in client.pull(reference) {
            XCTAssertNil(progress.error)
            events += 1
            if let status = progress.status { statuses.append(status) }
        }
        if !existed { createdImages.append(reference) }
        XCTAssertGreaterThan(events, 0, "pull should stream progress")
        XCTAssertTrue(statuses.contains { $0.contains("Digest") || $0.contains("Status") || $0.contains("up to date") || $0.contains("Downloaded") }, "\(statuses)")
        let pulled = await client.imageExists(reference)
        XCTAssertTrue(pulled)

        // Nonexistent image: fails (HTTP or in-stream) instead of hanging.
        var failed = false
        do {
            for try await progress in client.pull("colimax-test-missing/\(prefix):none") where progress.error != nil { failed = true }
        } catch {
            failed = true
        }
        XCTAssertTrue(failed, "pulling a nonexistent image should report an error")
    }

    /// Backups checklist "Run Now": volume + Redis produce file + manifest; keep = 2 leaves 2 after 3 runs;
    /// unrelated files are kept; a nonexistent container is an error.
    func testScheduledBackupRunNow() async throws {
        let source = "\(prefix)-sched"
        try await client.createVolume(name: source, labels: [Self.testLabel: prefix])
        createdVolumes.append(source)
        let writer = try await runContainer(image: "busybox:latest", name: "\(prefix)-sw", cmd: ["sleep", "300"], binds: ["\(source):/data"])
        let wrote = try await client.exec(writer, command: "echo scheduled > /data/s.txt")
        XCTAssertEqual(wrote.exitCode, 0)

        let target = dir.appendingPathComponent("schedules")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let strangers = [target.appendingPathComponent("notes.txt"), target.appendingPathComponent("\(source)-manual.tar")]
        for file in strangers { try Data("keep".utf8).write(to: file) }

        let schedule = BackupSchedule(profile: profile, target: .volume(name: source), interval: .daily, directory: target.path, keep: 2)
        XCTAssertTrue(schedule.isValid)
        let base = Date()
        var files: [URL] = []
        for run in 0..<3 {
            files.append(try await ScheduledBackupRunner.run(schedule, client: client, at: base.addingTimeInterval(TimeInterval(run * 60))))
        }
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: files[0].path), "oldest backup should be removed by retention")
        XCTAssertFalse(fm.fileExists(atPath: BackupManifest.url(for: files[0]).path))
        for file in files.dropFirst() {
            XCTAssertTrue(fm.fileExists(atPath: file.path))
            guard case .verified(let manifest) = try await BackupVerifier.verify(file) else { return XCTFail("manifest should match") }
            XCTAssertEqual(manifest.kind, .volume)
            XCTAssertEqual(manifest.source, source)
        }
        XCTAssertEqual(BackupRetention.entries(in: target, for: schedule).count, 2)
        for file in strangers { XCTAssertTrue(fm.fileExists(atPath: file.path), "unrelated file \(file.lastPathComponent) should be kept") }

        // Database (Redis), container identified by name.
        let redisName = "\(prefix)-sredis"
        let redis = try await runContainer(image: "redis:7-alpine", name: redisName)
        try await waitUntil(redis, "redis-cli ping | grep -q PONG")
        _ = try await client.exec(redis, command: "redis-cli set colimax scheduled")
        let dbSchedule = BackupSchedule(profile: profile, target: .database(container: redisName, engine: "redis"), interval: .hourly,
                                        directory: target.path, keep: 1)
        let dump = try await ScheduledBackupRunner.run(dbSchedule, client: client, at: Date())
        XCTAssertEqual(dump.pathExtension, "rdb")
        XCTAssertEqual(try FileHandle(forReadingFrom: dump).read(upToCount: 5), Data("REDIS".utf8))
        guard case .verified(let dbManifest) = try await BackupVerifier.verify(dump) else { return XCTFail() }
        XCTAssertEqual(dbManifest.kind, .redis)

        // Nonexistent container: error, no file created.
        let missing = BackupSchedule(profile: profile, target: .database(container: "\(prefix)-nope", engine: "redis"), interval: .hourly,
                                     directory: target.path, keep: 1)
        do {
            try await ScheduledBackupRunner.run(missing, client: client, at: Date())
            XCTFail("expected an error for a nonexistent container")
        } catch {
            XCTAssertEqual(error as? BackupError, .containerNotRunning("\(prefix)-nope"))
        }
        XCTAssertTrue(BackupRetention.entries(in: target, for: missing).isEmpty)
    }

    /// Monitoring checklist: one-shot `stats` on a real container + history write / read.
    func testStatsOneShotAndMetricsHistory() async throws {
        let name = "\(prefix)-stats"
        let id = try await runContainer(image: "busybox:latest", name: name, cmd: ["sleep", "300"])
        let stats = try await client.stats(id)
        XCTAssertGreaterThan(stats.memory_stats.usage ?? 0, 0, "memory usage should be > 0")
        XCTAssertGreaterThan(stats.memoryLimit, 0)
        XCTAssertGreaterThanOrEqual(stats.cpuPercent, 0)
        XCTAssertTrue((0...100).contains(stats.cpuPercentOfVM), "\(stats.cpuPercentOfVM)")

        let history = MetricsHistory.forProfile(prefix, in: dir.appendingPathComponent("metrics"))
        let sample = ResourceSample(date: .now, container: name, cpu: stats.cpuPercentOfVM, memory: stats.memoryUsed, memoryLimit: stats.memoryLimit)
        try history.append([sample])
        let loaded = history.load(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.container, name)
        XCTAssertEqual(loaded.first?.memory, sample.memory)
        XCTAssertEqual(loaded.first?.memoryLimit, sample.memoryLimit)
    }

    /// `cleanupStaleHelpers` removes only `created` helpers carrying the test label; other containers (including running helpers) are kept.
    func testCleanupStaleHelpersOnlyRemovesTestHelpers() async throws {
        let helper = [VolumeBackup.helperLabel: "volume-backup"]
        let stale = try await createContainer(image: "busybox:latest", name: "\(prefix)-helper", cmd: ["true"], labels: helper, start: false)
        let plain = try await createContainer(image: "busybox:latest", name: "\(prefix)-plain", cmd: ["true"], start: false)
        let running = try await createContainer(image: "busybox:latest", name: "\(prefix)-helper-run", cmd: ["sleep", "300"], labels: helper)
        try await Task.sleep(for: .seconds(2))
        // Negative olderThan absorbs clock skew between the VM and the Mac; scope is still only helpers with the test label.
        let removed = await VolumeBackup.cleanupStaleHelpers(client: client, olderThan: -300, requiredLabel: Self.testLabel)
        XCTAssertTrue(removed.contains(stale))
        XCTAssertFalse(removed.contains(plain))
        XCTAssertFalse(removed.contains(running))
        let remaining = Set(try await client.containers().map(\.id))
        XCTAssertFalse(remaining.contains(stale))
        XCTAssertTrue(remaining.isSuperset(of: [plain, running]))
        let userHelpers = try await client.containers().filter { $0.labels?[VolumeBackup.helperLabel] != nil && $0.labels?[Self.testLabel] == nil }
        XCTAssertTrue(Set(userHelpers.map(\.id)).isDisjoint(with: removed), "helpers without the test label must not be removed")
    }

    // MARK: Proxy: target container restart, compose down

    private func waitForRoute(_ proxyID: String, host: String, expect: String) async throws {
        try await waitUntil(proxyID, "wget -qO- --header 'Host: \(host)' http://127.0.0.1:18080/ | grep -q \(expect)", seconds: 30)
    }

    private func proxySettingsOrSkip() throws -> ProxySettings {
        let settings = ProxySettings(httpPort: 18_080, httpsPort: 18_443, https: false)
        for port in [settings.httpPort, settings.httpsPort] where PortProbe.isInUse(port) {
            throw XCTSkip("Port \(port) on the Mac is in use")
        }
        return settings
    }

    private func startTestProxy(_ settings: ProxySettings) async throws -> String {
        let volume = "\(prefix)-proxydata"
        createdVolumes.append(volume)
        let id = try await LocalProxy.create(settings: settings, client: client, name: "\(prefix)-proxy", volume: volume,
                                             extraLabels: [Self.testLabel: prefix])
        createdContainers.insert(id, at: 0)
        return id
    }

    /// Local Domains checklist: "target stays reachable after restart": IP changes -> config re-applied -> still routed.
    func testLocalProxyFollowsTargetRestart() async throws {
        let settings = try proxySettingsOrSkip()
        let net = "\(prefix)-pnet"
        _ = try await createTestNetwork(net)
        let webName = "\(prefix)-pweb"
        let web = try await createContainer(image: "busybox:latest", name: webName,
                                            cmd: ["sh", "-c", "mkdir -p /www && echo colimax-restart-ok > /www/index.html && httpd -f -p 8080 -h /www"],
                                            network: net)
        let proxyID = try await startTestProxy(settings)
        let route = ProxyRoute(subdomain: "web", container: webName, port: 8080)
        let skippedRoutes = try await LocalProxy.apply(routes: [route], settings: settings, proxyID: proxyID, client: client)
        XCTAssertEqual(skippedRoutes, [])
        try await waitForRoute(proxyID, host: "web.localhost", expect: "colimax-restart-ok")
        let ipBefore = try await client.containerDetails(web).networkSettings?.networks?[net]?.ipAddress

        // Stop the target, let another container take its old IP, start it again: the target gets a new IP.
        try await client.containerAction(web, "stop")
        _ = try await createContainer(image: "busybox:latest", name: "\(prefix)-pfill", cmd: ["sleep", "300"], network: net)
        try await client.containerAction(web, "start")
        let ipAfter = try await client.containerDetails(web).networkSettings?.networks?[net]?.ipAddress
        XCTAssertNotNil(ipAfter)
        if ipBefore == ipAfter { print("Note: IP unchanged after restart (\(ipAfter ?? "-"))") }

        // The app re-applies the config when the target starts (ProxyStore.containerStarted -> LocalProxy.apply).
        let skippedAfterRestart = try await LocalProxy.apply(routes: [route], settings: settings, proxyID: proxyID, client: client)
        XCTAssertEqual(skippedAfterRestart, [])
        try await waitForRoute(proxyID, host: "web.localhost", expect: "colimax-restart-ok")
    }

    /// Local Domains checklist: "`docker compose down` of the target project has no network errors": the proxy does not join compose networks.
    func testComposeDownWithProxyRouteSucceeds() async throws {
        guard ComposeService.isAvailable,
              let version = try? await Shell.run("docker", ["compose", "version"], timeout: 20), version.ok
        else { throw XCTSkip("Requires the docker CLI + compose plugin") }
        let settings = try proxySettingsOrSkip()
        try await ensureImage("busybox:latest")

        let projectDir = dir.appendingPathComponent("compose-proxy")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let yaml = """
        services:
          web:
            image: busybox:latest
            command: ["sh", "-c", "mkdir -p /www && echo colimax-compose-proxy > /www/index.html && httpd -f -p 8080 -h /www"]
            labels:
              dev.colimax.test: "\(prefix)"
        """
        try yaml.write(to: projectDir.appendingPathComponent("compose.yaml"), atomically: false, encoding: .utf8)
        let project = ComposeProject(name: prefix, workingDir: projectDir.path, configFiles: [projectDir.appendingPathComponent("compose.yaml").path])
        createdComposeProjects.append(project)
        let socket = client.socketPath
        for try await _ in ComposeService.run(.up, project: project, socketPath: socket) {}
        let composeContainers = try await client.containers()
        let webName = try XCTUnwrap(composeContainers.first { $0.composeProject == prefix && $0.composeService == "web" }?.name)

        let proxyID = try await startTestProxy(settings)
        let route = ProxyRoute(subdomain: "app", container: webName, port: 8080)
        let skippedRoutes = try await LocalProxy.apply(routes: [route], settings: settings, proxyID: proxyID, client: client)
        XCTAssertEqual(skippedRoutes, [])
        try await waitForRoute(proxyID, host: "app.localhost", expect: "colimax-compose-proxy")

        // down must be able to remove the project network (the proxy is not an endpoint on it).
        for try await _ in ComposeService.run(.down, project: project, socketPath: socket) {}
        let networksAfterDown = try await client.networks()
        XCTAssertFalse(networksAfterDown.contains { $0.name == "\(prefix)_default" }, "compose network should be removed")
        let status = try await LocalProxy.status(client: client, name: "\(prefix)-proxy")
        XCTAssertTrue(status.running, "proxy should still run after compose down")
        let skipped = try await LocalProxy.apply(routes: [route], settings: settings, proxyID: proxyID, client: client)
        XCTAssertEqual(skipped.count, 1, "a route to a removed container is skipped, not an error")
    }

    // MARK: Real Trivy (G24): skipped if not installed

    func testTrivyScanParsesRealOutput() async throws {
        guard Shell.which("trivy") != nil else { throw XCTSkip("trivy is not installed (brew install trivy)") }
        let image = "busybox:latest"
        try await ensureImage(image)
        let (command, args) = VulnerabilityScanner.arguments(.trivy, image: image, socketPath: client.socketPath)
        let raw = try await Shell.run(command, args, env: ["DOCKER_HOST": "unix://\(client.socketPath)"], timeout: 900)
        if !raw.ok, raw.stderr.lowercased().contains("download") {
            throw XCTSkip("Trivy could not download its vulnerability database: \(raw.stderr.suffix(300))")
        }
        XCTAssertTrue(raw.ok, raw.stderr)
        let data = Data(raw.stdout.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "Trivy output should be a JSON object")
        XCTAssertNotNil(object["ArtifactName"], "Trivy JSON format changed? keys: \(object.keys.sorted())")
        let rawCount = ((object["Results"] as? [[String: Any]]) ?? []).reduce(0) { $0 + (($1["Vulnerabilities"] as? [Any])?.count ?? 0) }
        let parsed = try VulnerabilityScanner.parseTrivy(data)
        XCTAssertEqual(parsed.count, rawCount, "parser should read every vulnerability in real output")
        XCTAssertTrue(parsed.allSatisfy { !$0.cve.isEmpty })

        let report = try await VulnerabilityScanner.scan(image: image, tool: .trivy, socketPath: client.socketPath)
        XCTAssertEqual(report.image, image)
        XCTAssertLessThanOrEqual(report.vulnerabilities.count, rawCount)
    }
}

/// A TCP socket listening on the Mac's 127.0.0.1, simulating another process holding the port.
final class HostListener {
    private var fd: Int32

    init?(port: Int) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); return nil }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }
}
