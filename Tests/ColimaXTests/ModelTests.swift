import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ColimaModelTests: XCTestCase {
    func testColimaStatusDecodeAndSocket() throws {
        let json = #"{"display_name":"colima","driver":"macOS Virtualization.Framework","arch":"aarch64","runtime":"docker","mount_type":"virtiofs","docker_socket":"unix:///Users/me/.colima/default/docker.sock","containerd_socket":"unix:///Users/me/.colima/default/containerd.sock","kubernetes":false,"cpu":4,"memory":6442450944,"disk":107374182400}"#
        let status = try JSONDecoder().decode(ColimaStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.dockerSocketPath, "/Users/me/.colima/default/docker.sock")
        XCTAssertEqual(status.mountType, "virtiofs")
        XCTAssertNil(status.ipAddress)
        XCTAssertEqual(ColimaService.resolveDockerSocket("default", status: status), "/Users/me/.colima/default/docker.sock")
    }

    func testSocketFallbackWhenStatusMissing() {
        XCTAssertTrue(ColimaService.resolveDockerSocket("work", status: nil).hasSuffix("/work/docker.sock"))
    }

    func testUnixPathParsing() {
        XCTAssertEqual(ColimaStatus.unixPath(from: "unix:///a/b.sock"), "/a/b.sock")
        XCTAssertEqual(ColimaStatus.unixPath(from: "/a/b.sock"), "/a/b.sock")
        XCTAssertNil(ColimaStatus.unixPath(from: "tcp://127.0.0.1:2375"))
        XCTAssertNil(ColimaStatus.unixPath(from: "unix://relative.sock"))
    }

    func testProfileNameValidation() {
        XCTAssertTrue(ColimaService.isValidProfileName("work-1"))
        for bad in ["../x", "a;rm", "-x", "", "a b", String(repeating: "a", count: 40), "$(id)"] {
            XCTAssertFalse(ColimaService.isValidProfileName(bad), bad)
        }
    }

    func testParseConfigFixture() {
        let yaml = """
        # comment
        cpu: 4
        disk: 100
        memory: 6
        arch: aarch64
        runtime: docker
        kubernetes:
          enabled: true
          version: v1.30
        vmType: vz
        rosetta: true
        nestedVirtualization: false
        mountType: virtiofs # inline comment
        """
        let config = ColimaService.parseConfig(yaml)
        XCTAssertEqual(config.cpus, 4)
        XCTAssertEqual(config.memoryGiB, 6)
        XCTAssertEqual(config.diskGiB, 100)
        XCTAssertEqual(config.mountType, "virtiofs")
        XCTAssertTrue(config.kubernetes)
        XCTAssertTrue(config.rosetta)
        XCTAssertTrue(config.startArguments.contains("--vz-rosetta=true"))
        var changed = config
        changed.runtime = "containerd"
        XCTAssertTrue(changed.requiresRecreate(from: config))
        var cpuOnly = config
        cpuOnly.cpus = 2
        XCTAssertFalse(cpuOnly.requiresRecreate(from: config))
    }

    func testParseConfigEmpty() {
        XCTAssertEqual(ColimaService.parseConfig(""), RuntimeConfig())
    }

    func testVMUsageParse() {
        let sample = "cpu  100 0 50 800 50 0 0 0 0 0\n---\nMemTotal:  4000000 kB\nMemAvailable:  1000000 kB\n---\n0.52 0.40 0.30 1/100 123\n---\n4\n---\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vdb1 100000 25000 75000 25% /var/lib/docker\n"
        let usage = VMUsage.parse(sample)
        XCTAssertEqual(usage.memUsed, 3_072_000_000)
        XCTAssertEqual(usage.cpuCount, 4)
        XCTAssertEqual(usage.diskUsed, 25_600_000)
        var later = usage
        later.cpuTotalTicks += 100
        later.cpuIdleTicks += 25
        XCTAssertEqual(later.cpuPercent(since: usage) ?? 0, 75, accuracy: 0.01)
        XCTAssertNil(usage.cpuPercent(since: nil))
    }

    func testFormatDateHandlesNanoseconds() {
        XCTAssertNotNil(Format.date(iso: "2026-11-19T10:00:00.123456789Z"))
        XCTAssertNotNil(Format.date(iso: "2026-11-19T10:00:00Z"))
        XCTAssertNil(Format.date(iso: "0001-01-01T00:00:00Z"))
        XCTAssertNil(Format.date(iso: ""))
    }
}

final class ContainerDetailsTests: XCTestCase {
    static let fixture = #"""
    {
      "Id": "abc123", "Name": "/db", "Created": "2026-11-19T10:00:00.1Z", "Platform": "linux", "RestartCount": 3,
      "State": {"Status": "exited", "Running": false, "OOMKilled": true, "ExitCode": 137, "Error": "",
                "StartedAt": "2026-11-19T10:00:01.123456789Z", "FinishedAt": "2026-11-19T10:05:00.1Z",
                "Health": {"Status": "unhealthy", "FailingStreak": 4, "Log": [{"Start": "x", "ExitCode": 1, "Output": "conn refused"}]}},
      "Config": {"Env": ["POSTGRES_PASSWORD=supersecret", "PATH=/usr/bin", "PWD=/", "DB_PASSWORD_FILE=/run/secrets/db", "NOVALUE"],
                 "User": "", "Image": "postgres:16", "Cmd": "postgres", "Entrypoint": null, "Labels": {"a": "b"}},
      "HostConfig": {"Privileged": true, "CapAdd": ["CAP_SYS_ADMIN", "NET_BIND_SERVICE"], "NetworkMode": "host",
                     "Memory": 536870912, "NanoCpus": 1500000000, "PidsLimit": 0, "SecurityOpt": ["seccomp=unconfined"],
                     "RestartPolicy": {"Name": "on-failure", "MaximumRetryCount": 5},
                     "PortBindings": {"5432/tcp": [{"HostIp": "", "HostPort": "5432"}], "9000/tcp": [{"HostIp": "127.0.0.1", "HostPort": "9000"}], "8000/tcp": null}},
      "Mounts": [{"Type": "bind", "Source": "/var/run/docker.sock", "Destination": "/var/run/docker.sock", "RW": true},
                 {"Type": "volume", "Name": "pgdata", "Source": "/var/lib/docker/volumes/pgdata/_data", "Destination": "/var/lib/postgresql/data", "RW": true}],
      "NetworkSettings": {"Networks": {"bridge": {"IPAddress": "172.17.0.2", "Gateway": "172.17.0.1"}}, "Ports": {}}
    }
    """#

    func decode() throws -> ContainerDetails {
        try JSONDecoder().decode(ContainerDetails.self, from: Data(Self.fixture.utf8))
    }

    func testDecode() throws {
        let d = try decode()
        XCTAssertEqual(d.displayName, "db")
        XCTAssertEqual(d.restartCount, 3)
        XCTAssertTrue(d.oomKilled)
        XCTAssertEqual(d.state?.exitCode, 137)
        XCTAssertEqual(d.healthStatus, "unhealthy")
        XCTAssertEqual(d.config?.cmd, ["postgres"]) // Cmd given as a plain string
        XCTAssertEqual(d.memoryLimit, 536_870_912)
        XCTAssertEqual(d.cpuLimit ?? 0, 1.5, accuracy: 0.001)
        XCTAssertNil(d.pidsLimit)
        XCTAssertEqual(d.declaredHostPorts.map(\.port), [5432, 9000])
        XCTAssertEqual(d.networkSettings?.networks?["bridge"]?.ipAddress, "172.17.0.2")
    }

    func testMinimalJSONDecodes() throws {
        let d = try JSONDecoder().decode(ContainerDetails.self, from: Data(#"{"Id":"x","Name":"/y"}"#.utf8))
        XCTAssertEqual(d.displayName, "y")
        XCTAssertNil(d.memoryLimit)
        XCTAssertEqual(d.environment, [])
    }

    func testEnvSensitivity() throws {
        let env = try decode().environment
        XCTAssertEqual(env.first { $0.key == "POSTGRES_PASSWORD" }?.isSensitive, true)
        XCTAssertEqual(env.first { $0.key == "POSTGRES_PASSWORD" }?.maskedValue, "••••••••")
        XCTAssertEqual(env.first { $0.key == "PATH" }?.isSensitive, false)
        XCTAssertEqual(env.first { $0.key == "PWD" }?.isSensitive, false)
        XCTAssertEqual(env.first { $0.key == "DB_PASSWORD_FILE" }?.isSensitive, false)
        XCTAssertEqual(env.first { $0.key == "NOVALUE" }?.value, "")
        for key in ["GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "api_key", "REDIS_PASS", "STRIPE_KEY", "DATABASE_DSN"] {
            XCTAssertTrue(EnvVar.isSensitive(key: key), key)
        }
        for key in ["HOME", "LANG", "NODE_ENV", "PORT"] {
            XCTAssertFalse(EnvVar.isSensitive(key: key), key)
        }
    }

    func testHealthFromStatusString() throws {
        func container(_ status: String) throws -> DockerContainer {
            try JSONDecoder().decode(DockerContainer.self, from: Data(#"{"Id":"a","Names":["/a"],"Image":"x","Created":0,"State":"running","Status":"\#(status)"}"#.utf8))
        }
        XCTAssertEqual(try container("Up 2 minutes (healthy)").health, "healthy")
        XCTAssertEqual(try container("Up 1 second (health: starting)").health, "starting")
        XCTAssertEqual(try container("Up 5 minutes (unhealthy)").health, "unhealthy")
        XCTAssertNil(try container("Up 5 minutes").health)
    }

    func testImagePlatform() {
        XCTAssertTrue(ImagePlatform(id: "a", architecture: "arm64", os: "linux", variant: "v8").isNativeARM64)
        XCTAssertFalse(ImagePlatform(id: "b", architecture: "amd64", os: "linux", variant: nil).isNativeARM64)
        XCTAssertEqual(HostPlatform.normalize("aarch64"), "arm64")
        XCTAssertEqual(HostPlatform.normalize("x86_64"), "amd64")
    }

}

final class ImageReferenceTests: XCTestCase {
    func testValidReferences() {
        for ok in ["nginx", "nginx:1.27", "busybox:1.36", "ghcr.io/org/app:1.0", "localhost:5000/x/y", "app@sha256:0123abcd", "my_repo/a-b.c"] {
            XCTAssertTrue(ImageReference.isValid(ok), ok)
        }
    }

    func testInvalidReferences() {
        for bad in ["", " nginx", "nginx ", "-x", "--config=/etc/x", "a b", "a;rm -rf /", "$(id)", "a|b", "`id`", "x\ny",
                    String(repeating: "a", count: 513)] {
            XCTAssertFalse(ImageReference.isValid(bad), bad)
        }
        XCTAssertTrue(ImageReference.isValid(" nginx:1 ".trimmed), "PullSheet trims before validating")
    }

    func testScannerUsesSameRule() {
        XCTAssertEqual(VulnerabilityScanner.isValidReference("busybox:latest"), ImageReference.isValid("busybox:latest"))
        XCTAssertFalse(VulnerabilityScanner.isValidReference("-q"))
    }
}
