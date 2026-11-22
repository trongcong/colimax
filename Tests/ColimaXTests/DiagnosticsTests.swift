import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class DiagnosticsTests: XCTestCase {
    private func profile(_ json: String) throws -> ColimaProfile {
        try JSONDecoder().decode(ColimaProfile.self, from: Data(json.utf8))
    }

    private func snapshot(profile: ColimaProfile?, config: RuntimeConfig? = RuntimeConfig(), ping: String? = nil) -> RuntimeSnapshot {
        RuntimeSnapshot(
            colimaPath: "/opt/homebrew/bin/colima", dockerCLIPath: nil, profile: profile, config: config, status: nil,
            socketPath: "/Users/me/.colima/default/docker.sock", socketPermissions: nil, pingError: ping,
            dockerContext: DockerContextInfo(name: "desktop-linux", endpoint: "unix:///Users/me/.docker/run/docker.sock"),
            hostCPUs: 8, hostMemory: 16 * 1_073_741_824, hostIsAppleSilicon: true, appTranslated: false, vmDiskUsedFraction: 0.9
        )
    }

    func testRuntimeChecks() throws {
        let running = try profile(#"{"name":"default","status":"Running","arch":"aarch64","cpus":2,"memory":2147483648,"disk":107374182400,"runtime":"docker"}"#)
        let items = RuntimeDiagnostics.check(snapshot(profile: running, ping: "timeout"))
        XCTAssertTrue(items.contains { $0.title == "docker CLI not found" && $0.severity == .warning })
        XCTAssertTrue(items.contains { $0.title == "Docker daemon not responding" && $0.severity == .critical })
        XCTAssertTrue(items.contains { $0.title == "docker context differs from profile" })
        XCTAssertTrue(items.contains { $0.title == "VM disk almost full" })
        XCTAssertTrue(items.contains { $0.title == "Configuration matches" })
    }

    func testNoProfile() {
        let items = RuntimeDiagnostics.check(snapshot(profile: nil))
        XCTAssertTrue(items.contains { $0.title == "No profile" })
    }

    func testConfigDrift() throws {
        let running = try profile(#"{"name":"default","status":"Running","arch":"aarch64","cpus":2,"memory":2147483648,"disk":107374182400,"runtime":"docker"}"#)
        var config = RuntimeConfig()
        config.cpus = 4
        config.memoryGiB = 8
        let items = RuntimeDiagnostics.drift(config: config, profile: running)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Config drift")
        XCTAssertTrue(items[0].detail.contains("CPU 2 → 4"))
        XCTAssertTrue(items[0].detail.contains("RAM 2 → 8 GiB"))
        let stopped = try profile(#"{"name":"default","status":"Stopped"}"#)
        XCTAssertEqual(RuntimeDiagnostics.drift(config: config, profile: stopped), [])
    }

    func testResourceAndVirtualizationRecommendations() {
        var config = RuntimeConfig()
        config.memoryGiB = 14
        config.cpus = 8
        let resources = RuntimeDiagnostics.resources(config: config, hostCPUs: 8, hostMemory: 16 * 1_073_741_824)
        XCTAssertEqual(Set(resources.map(\.title)), ["VM memory too large", "VM uses all CPUs"])

        config.vmType = "qemu"
        config.mountType = "sshfs"
        let virt = RuntimeDiagnostics.virtualization(config: config, isAppleSilicon: true, status: nil)
        XCTAssertTrue(virt.contains { $0.title == "VM type qemu" })
        XCTAssertTrue(RuntimeDiagnostics.virtualization(config: config, isAppleSilicon: false, status: nil).isEmpty)
    }

    func testSocketPermissionChecks() throws {
        let file = TestSupport.tempRoot.appendingPathComponent("perm-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        let open = try XCTUnwrap(SocketPermissions.read(file.path))
        XCTAssertTrue(open.accessibleByOthers)
        XCTAssertEqual(open.octal, "666")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertFalse(try XCTUnwrap(SocketPermissions.read(file.path)).accessibleByOthers)
        XCTAssertNil(SocketPermissions.read("/nonexistent/\(UUID())"))
    }

    func testSecurityAuditFindingsAndNoSecretLeak() throws {
        let details = try ContainerDetailsTests().decode()
        let items = SecurityAudit.check([details], vmReachableFromNetwork: false)
        let titles = Set(items.map(\.title))
        XCTAssertTrue(titles.contains("db: privileged"))
        XCTAssertTrue(titles.contains("db: dangerous capability"))
        XCTAssertTrue(titles.contains("db: Docker socket mounted"))
        XCTAssertTrue(titles.contains("db: network host"))
        XCTAssertTrue(titles.contains("db: protection disabled"))
        XCTAssertTrue(titles.contains("db: secret in env"))
        let port = try XCTUnwrap(items.first { $0.title == "db: port bind 0.0.0.0" })
        XCTAssertEqual(port.severity, .info)
        XCTAssertTrue(port.detail.contains("5432"))
        XCTAssertFalse(port.detail.contains("9000"), "a port bound to 127.0.0.1 is not exposed")
        // Secret values must never appear in the results.
        for item in items {
            XCTAssertFalse(item.detail.contains("supersecret"))
            XCTAssertFalse((item.recommendation ?? "").contains("supersecret"))
        }
        let reachable = SecurityAudit.check([details], vmReachableFromNetwork: true)
        XCTAssertEqual(reachable.first { $0.title == "db: port open on all interfaces" }?.severity, .warning)
    }

    func testPortConflicts() throws {
        func details(_ name: String, running: Bool, port: Int) throws -> ContainerDetails {
            try JSONDecoder().decode(ContainerDetails.self, from: Data("""
            {"Id":"\(name)","Name":"/\(name)","State":{"Running":\(running)},
             "HostConfig":{"PortBindings":{"80/tcp":[{"HostIp":"","HostPort":"\(port)"}]}}}
            """.utf8))
        }
        let all = [try details("web", running: true, port: 8080), try details("old", running: false, port: 8080), try details("api", running: false, port: 3000)]
        let items = PortDiagnostics.check(all) { $0 == 8080 || $0 == 3000 }
        XCTAssertTrue(items.contains { $0.title == "Port 8080 declared more than once" })
        XCTAssertTrue(items.contains { $0.title == "old: port 8080 is in use" && $0.detail.contains("web") })
        XCTAssertTrue(items.contains { $0.title == "api: port 3000 is in use" && $0.detail.contains("process on the Mac") })
        XCTAssertFalse(items.contains { $0.title.hasPrefix("web:") }, "a running container holding its own port is not a conflict")
        XCTAssertEqual(PortDiagnostics.check([], isInUse: { _ in true }), [])
    }

    func testPortProbeDetectsListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw XCTSkip("Environment does not allow TCP bind (sandbox)") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertTrue(PortProbe.isInUse(port))
        XCTAssertFalse(PortProbe.isInUse(0))
        XCTAssertFalse(PortProbe.isInUse(70_000))
    }

    func testDockerContextReader() throws {
        let dir = TestSupport.tempRoot.appendingPathComponent("docker-\(UUID().uuidString.prefix(8))")
        let meta = dir.appendingPathComponent("contexts/meta/abc")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"currentContext":"colima"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(#"{"Name":"colima","Endpoints":{"docker":{"Host":"unix:///Users/me/.colima/default/docker.sock"}}}"#.utf8)
            .write(to: meta.appendingPathComponent("meta.json"))
        XCTAssertEqual(DockerContextReader.current(dockerConfigDir: dir), DockerContextInfo(name: "colima", endpoint: "unix:///Users/me/.colima/default/docker.sock"))

        let empty = TestSupport.tempRoot.appendingPathComponent("docker-empty-\(UUID().uuidString.prefix(8))")
        XCTAssertEqual(DockerContextReader.current(dockerConfigDir: empty)?.name, "default")
    }

    func testImageArchWarnings() throws {
        let container = try JSONDecoder().decode(DockerContainer.self, from: Data(#"{"Id":"c1","Names":["/legacy"],"Image":"oldapp","ImageID":"sha256:amd","Created":0,"State":"running","Status":"Up"}"#.utf8))
        let images = try JSONDecoder().decode([DockerImage].self, from: Data(#"[{"Id":"sha256:amd","RepoTags":["oldapp:latest"],"Created":0,"Size":1},{"Id":"sha256:arm","RepoTags":["nginx:latest"],"Created":0,"Size":1},{"Id":"sha256:amd2","RepoTags":["x:1"],"Created":0,"Size":1}]"#.utf8))
        let platforms = [
            "sha256:amd": ImagePlatform(id: "sha256:amd", architecture: "amd64", os: "linux", variant: nil),
            "sha256:arm": ImagePlatform(id: "sha256:arm", architecture: "arm64", os: "linux", variant: nil),
            "sha256:amd2": ImagePlatform(id: "sha256:amd2", architecture: "amd64", os: "linux", variant: nil),
        ]
        let items = ImageArchDiagnostics.check(images: images, platforms: platforms, containers: [container], rosettaEnabled: false, vmArch: "aarch64")
        let warning = try XCTUnwrap(items.first { $0.containerID == "c1" })
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertTrue(warning.detail.contains("QEMU"))
        XCTAssertTrue(items.contains { $0.title == "Non-arm64 images: 1" })
        XCTAssertTrue(ImageArchDiagnostics.check(images: images, platforms: platforms, containers: [container], rosettaEnabled: true, vmArch: "x86_64").isEmpty)
    }
}

final class StorageReportTests: XCTestCase {
    func testAnalyze() throws {
        let json = #"""
        {"LayersSize": 1000,
         "Images": [{"Id":"i1","RepoTags":["used:1"],"Created":0,"Size":100,"Containers":1},
                    {"Id":"i2","RepoTags":["<none>:<none>"],"Created":0,"Size":50,"Containers":0},
                    {"Id":"i3","RepoTags":["unused:1"],"Created":0,"Size":300,"Containers":0}],
         "Containers": [{"Id":"c1","Names":["/run"],"State":"running","SizeRw":5},
                        {"Id":"c2","Names":["/dead"],"State":"exited","SizeRw":70}],
         "Volumes": [{"Name":"keep","Driver":"local","Mountpoint":"/x","UsageData":{"Size":10,"RefCount":1}},
                     {"Name":"orphan","Driver":"local","Mountpoint":"/y","Labels":{"com.docker.compose.project":"shop"},"UsageData":{"Size":999,"RefCount":0}}],
         "BuildCache": [{"Size": 40, "InUse": true}, {"Size": 60, "InUse": false}]}
        """#
        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data(json.utf8))
        let container = try JSONDecoder().decode(DockerContainer.self, from: Data(#"{"Id":"c1","Names":["/run"],"Image":"used:1","ImageID":"i1","Created":0,"State":"running","Status":"Up","Mounts":[{"Type":"volume","Name":"keep"}]}"#.utf8))
        let report = StorageReport.analyze(usage, containers: [container])
        XCTAssertEqual(report.unusedVolumes.map(\.name), ["orphan"])
        XCTAssertEqual(report.unusedVolumes.first?.detail, "project shop")
        XCTAssertEqual(report.danglingImages.map(\.id), ["i2"])
        XCTAssertEqual(report.unusedImages.map(\.id), ["i3"])
        XCTAssertEqual(report.stoppedContainers.map(\.name), ["dead"])
        XCTAssertEqual(report.buildCacheTotal, 100)
        XCTAssertEqual(report.buildCacheReclaimable, 60)
    }

    func testEmpty() throws {
        let usage = try JSONDecoder().decode(DiskUsage.self, from: Data("{}".utf8))
        let report = StorageReport.analyze(usage, containers: [])
        XCTAssertTrue(report.unusedVolumes.isEmpty && report.unusedImages.isEmpty && report.stoppedContainers.isEmpty)
        XCTAssertEqual(report.buildCacheTotal, 0)
    }
}
