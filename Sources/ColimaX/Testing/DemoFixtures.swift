#if COLIMAX_UI_TESTING
import Foundation

// Demo workload for the landing page screenshots (`COLIMAX_UI_TEST_SCENARIO=demo`, see
// scripts/site-screenshots.sh). Everything is made up: two Compose projects (`shop`, `blog`), a few
// standalone containers, moving resource charts, disk usage and some security findings. Compiled only
// with `-D COLIMAX_UI_TESTING`, like the other fixtures.
enum DemoFixtures {
    private struct Spec: Sendable {
        let id: String
        let name: String
        let image: String
        var state = "running"
        var status = "Up 3 hours"
        var project: String?
        var service: String?
        var ports: [(container: Int, host: Int, ip: String)] = []
        var network: String = "bridge"
        var ip: String
        var volumes: [(name: String, path: String)] = []
        var binds: [(source: String, path: String)] = []
        var env: [String] = []
        var health: String?
        var memoryLimit: Int64?
        var restartPolicy = "unless-stopped"
        var hoursAgo = 3
        var load: FakeLoad?
        var logs = ""
    }

    private static let mib: Int64 = 1 << 20

    private static let specs: [Spec] = [
        Spec(id: id("web"), name: "shop-web-1", image: "nginx:1.27-alpine", project: "shop", service: "web",
             ports: [(80, 8080, "0.0.0.0")], network: "shop_default", ip: "172.20.0.5",
             load: FakeLoad(cpu: 1.8, memory: 14 * mib, network: 180_000, disk: 2_000),
             logs: nginxLog),
        Spec(id: id("api"), name: "shop-api-1", image: "ghcr.io/acme/shop-api:2.4.1", project: "shop", service: "api",
             ports: [(3000, 3000, "127.0.0.1")], network: "shop_default", ip: "172.20.0.4",
             env: ["NODE_ENV=production", "PORT=3000", "DATABASE_URL=postgres://shop:s3cr3t-demo@db:5432/shop",
                   "STRIPE_SECRET_KEY=sk_test_51DemoOnlyNotARealKey", "LOG_LEVEL=info"],
             health: "healthy", memoryLimit: 512 * mib,
             load: FakeLoad(cpu: 14, memory: 168 * mib, memoryLimit: 512 * mib, network: 95_000, disk: 6_000),
             logs: apiLog),
        Spec(id: id("db"), name: "shop-db-1", image: "postgres:16", project: "shop", service: "db",
             network: "shop_default", ip: "172.20.0.2", volumes: [("shop_pgdata", "/var/lib/postgresql/data")],
             env: ["POSTGRES_USER=shop", "POSTGRES_PASSWORD=s3cr3t-demo", "POSTGRES_DB=shop",
                   "PGDATA=/var/lib/postgresql/data"],
             health: "healthy", memoryLimit: 1024 * mib,
             load: FakeLoad(cpu: 6.5, memory: 236 * mib, memoryLimit: 1024 * mib, network: 40_000, disk: 220_000),
             logs: postgresLog),
        Spec(id: id("cache"), name: "shop-cache-1", image: "redis:7-alpine", project: "shop", service: "cache",
             network: "shop_default", ip: "172.20.0.3", volumes: [("shop_redis", "/data")],
             load: FakeLoad(cpu: 0.9, memory: 9 * mib, network: 22_000, disk: 800),
             logs: redisLog),
        Spec(id: id("wordpress"), name: "blog-wordpress-1", image: "wordpress:6.6", status: "Up 26 hours",
             project: "blog", service: "wordpress", ports: [(80, 8081, "127.0.0.1")], network: "blog_default", ip: "172.21.0.3",
             volumes: [("blog_wp-content", "/var/www/html/wp-content")],
             env: ["WORDPRESS_DB_HOST=mysql", "WORDPRESS_DB_USER=wp", "WORDPRESS_DB_PASSWORD=wp-demo-pass"],
             hoursAgo: 26, load: FakeLoad(cpu: 3.2, memory: 96 * mib, network: 30_000, disk: 4_000)),
        Spec(id: id("mysql"), name: "blog-mysql-1", image: "mysql:8.4", status: "Up 26 hours",
             project: "blog", service: "mysql", network: "blog_default", ip: "172.21.0.2",
             volumes: [("blog_mysql", "/var/lib/mysql")],
             env: ["MYSQL_DATABASE=wordpress", "MYSQL_USER=wp", "MYSQL_PASSWORD=wp-demo-pass", "MYSQL_ROOT_PASSWORD=root-demo"],
             health: "healthy", hoursAgo: 26, load: FakeLoad(cpu: 2.4, memory: 382 * mib, network: 12_000, disk: 60_000)),
        Spec(id: id("mailpit"), name: "mailpit", image: "axllent/mailpit:latest", status: "Up 2 days",
             ports: [(8025, 8025, "127.0.0.1"), (1025, 1025, "127.0.0.1")], ip: "172.17.0.2",
             restartPolicy: "always", hoursAgo: 50, load: FakeLoad(cpu: 0.3, memory: 21 * mib, network: 2_000)),
        Spec(id: id("agent"), name: "ops-agent", image: "ghcr.io/acme/ops-agent:1.2", status: "Up 2 days",
             ip: "172.17.0.3", binds: [("/var/run/docker.sock", "/var/run/docker.sock")],
             restartPolicy: "always", hoursAgo: 50, load: FakeLoad(cpu: 0.6, memory: 34 * mib, network: 4_000)),
        Spec(id: id("billing"), name: "legacy-billing", image: "acme/billing:1.9", status: "Up 5 hours",
             ports: [(9000, 9000, "127.0.0.1")], ip: "172.17.0.4", hoursAgo: 5,
             load: FakeLoad(cpu: 9, memory: 142 * mib, network: 8_000, disk: 1_500)),
        Spec(id: id("report"), name: "nightly-report", image: "python:3.12-slim", state: "exited",
             status: "Exited (0) 6 hours ago", ip: "", restartPolicy: "no", hoursAgo: 30),
    ]

    static func services(prerequisites tools: FakePrerequisites) -> AppServices {
        let colima = FakeColima(profiles: [
            decode(ColimaProfile.self, ["name": "default", "status": "Running", "arch": "aarch64", "cpus": 4,
                                        "memory": 8 << 30, "disk": 100 << 30, "runtime": "docker"]),
            decode(ColimaProfile.self, ["name": "k8s", "status": "Stopped", "arch": "aarch64", "cpus": 6,
                                        "memory": 12 << 30, "disk": 120 << 30, "runtime": "docker"]),
        ])
        colima.state.withLock { s in
            s.vmLoad = 0.24
            // A made-up home folder: nothing from the Mac taking the screenshots may appear on them.
            s.status = decode(ColimaStatus.self, [
                "display_name": "colima", "driver": "macOS Virtualization.Framework", "arch": "aarch64",
                "runtime": "docker", "mount_type": "virtiofs", "docker_socket": demoSocket,
                "ip_address": "192.168.106.2", "kubernetes": false, "cpu": 4, "memory": 8 << 30, "disk": 100 << 30,
            ])
            s.config = RuntimeConfig(cpus: 4, memoryGiB: 8, diskGiB: 100)
            s.vmUsage = VMUsage(cpuTotalTicks: 1_000_000, cpuIdleTicks: 760_000, memTotal: 8 << 30,
                                memAvailable: 5_150 * mib, load1: 0.86, cpuCount: 4,
                                diskTotal: 100 << 30, diskUsed: 31_400 * mib)
        }

        let images: [(id: String, tag: String, size: Int64, arch: String)] = [
            (sha("nginx"), "nginx:1.27-alpine", 48 * mib, "arm64"),
            (sha("shop-api"), "ghcr.io/acme/shop-api:2.4.1", 186 * mib, "arm64"),
            (sha("postgres"), "postgres:16", 438 * mib, "arm64"),
            (sha("redis"), "redis:7-alpine", 41 * mib, "arm64"),
            (sha("wordpress"), "wordpress:6.6", 702 * mib, "arm64"),
            (sha("mysql"), "mysql:8.4", 603 * mib, "arm64"),
            (sha("mailpit"), "axllent/mailpit:latest", 33 * mib, "arm64"),
            (sha("ops-agent"), "ghcr.io/acme/ops-agent:1.2", 72 * mib, "arm64"),
            (sha("billing"), "acme/billing:1.9", 254 * mib, "amd64"),
            (sha("python"), "python:3.12-slim", 152 * mib, "arm64"),
        ]
        let now = Int(Date().timeIntervalSince1970)
        var imageModels = images.enumerated().map { index, image in
            decode(DockerImage.self, ["Id": image.id, "RepoTags": [image.tag], "Created": now - 86_400 * (3 + index * 4),
                                      "Size": image.size, "Containers": -1])
        }
        imageModels.append(decode(DockerImage.self, ["Id": sha("dangling"), "RepoTags": ["<none>:<none>"],
                                                     "RepoDigests": ["acme/billing@sha256:5f1c"],
                                                     "Created": now - 86_400 * 40, "Size": 231 * mib]))

        let volumeSizes: [(name: String, size: Int64, project: String?, refs: Int)] = [
            ("shop_pgdata", 412 * mib, "shop", 1), ("shop_redis", 18 * mib, "shop", 1),
            ("blog_mysql", 296 * mib, "blog", 1), ("blog_wp-content", 87 * mib, "blog", 1),
            ("old-project_data", 1_240 * mib, nil, 0),
        ]
        let volumes = volumeSizes.map { volume in
            var object: [String: Any] = ["Name": volume.name, "Driver": "local",
                                         "Mountpoint": "/var/lib/docker/volumes/\(volume.name)/_data",
                                         "CreatedAt": "2026-10-02T09:14:00Z",
                                         "UsageData": ["Size": volume.size, "RefCount": volume.refs]]
            if let project = volume.project { object["Labels"] = ["com.docker.compose.project": project] }
            return decode(DockerVolume.self, object)
        }

        let networks = [
            network("bridge", subnet: "172.17.0.0/16"), network("host"), network("none"),
            network("shop_default", subnet: "172.20.0.0/16", project: "shop"),
            network("blog_default", subnet: "172.21.0.0/16", project: "blog"),
        ]

        let docker = FakeDocker(
            containers: specs.map { container($0, now: now) },
            images: imageModels,
            volumes: volumes,
            networks: networks,
            details: Dictionary(uniqueKeysWithValues: specs.map { ($0.id, details($0, now: now)) })
        )
        docker.state.withLock { s in
            s.engine = FakeEngineInfo(serverVersion: "27.3.1", operatingSystem: "Ubuntu 24.04.1 LTS",
                                      kernelVersion: "6.8.0-48-generic", cpus: 4, memory: 8 << 30)
            for image in images { s.architectures[image.id] = image.arch }
            for spec in specs {
                if let load = spec.load, spec.state == "running" { s.load[spec.id] = load }
                if !spec.logs.isEmpty { s.logs[spec.id] = spec.logs }
            }
            s.diskUsage = decode(DiskUsage.self, [
                "LayersSize": imageModels.reduce(Int64(0)) { $0 + $1.size },
                "Images": imageModels.map { ["Id": $0.id, "RepoTags": $0.repoTags ?? [], "Created": $0.created,
                                             "Size": $0.size, "Containers": $0.isDangling ? 0 : 1] },
                "Containers": specs.map { ["Id": $0.id, "Names": ["/\($0.name)"], "State": $0.state,
                                           "SizeRw": $0.state == "running" ? 6 * mib : 48 * mib] },
                "Volumes": volumeSizes.map { ["Name": $0.name, "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/\($0.name)/_data",
                                              "UsageData": ["Size": $0.size, "RefCount": $0.refs]] },
                "BuildCache": [["Size": 820 * mib, "InUse": false], ["Size": 390 * mib, "InUse": false],
                               ["Size": 64 * mib, "InUse": true]],
            ])
        }

        return AppServices(
            colima: colima,
            makeDocker: { _ in docker },
            checkPrerequisites: { tools.report() },
            installPrerequisites: { formulae in tools.install(formulae) },
            watchesColimaDirectory: false,
            notify: { _, _ in },
            scannerTools: { [] },
            dockerContext: { DockerContextInfo(name: "colima", endpoint: demoSocket) }
        )
    }

    private static let demoSocket = "unix:///Users/demo/.colima/default/docker.sock"

    /// ID of a demo container by its key ("web", "api", "db", "cache", "wordpress", "mysql", …), for
    /// `COLIMAX_UI_TEST_FOCUS`.
    static func containerID(_ key: String) -> String { id(key) }

    // MARK: Builders

    /// A stable 64-character hex ID derived from a name.
    private static func id(_ name: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        var hex = ""
        while hex.count < 64 {
            for byte in (name + String(hex.count)).utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            hex += String(format: "%016llx", hash)
        }
        return String(hex.prefix(64))
    }

    private static func sha(_ name: String) -> String { "sha256:" + id("image-" + name) }

    private static func composeLabels(_ spec: Spec) -> [String: String] {
        guard let project = spec.project, let service = spec.service else { return [:] }
        let dir = "/Users/demo/Projects/\(project)"
        return ["com.docker.compose.project": project, "com.docker.compose.service": service,
                "com.docker.compose.project.working_dir": dir,
                "com.docker.compose.project.config_files": "\(dir)/compose.yaml",
                "com.docker.compose.container-number": "1"]
    }

    private static func container(_ spec: Spec, now: Int) -> DockerContainer {
        var networks: [String: Any] = [:]
        if spec.state == "running" { networks[spec.network] = ["IPAddress": spec.ip] }
        let mounts: [[String: Any]] = spec.volumes.map { ["Type": "volume", "Name": $0.name, "Destination": $0.path] }
            + spec.binds.map { ["Type": "bind", "Source": $0.source, "Destination": $0.path] }
        // Docker appends the health to the status; the app derives the heart icon from it.
        let status = spec.health.map { spec.status + " (\($0))" } ?? spec.status
        return decode(DockerContainer.self, [
            "Id": spec.id, "Names": ["/\(spec.name)"], "Image": spec.image, "ImageID": sha(spec.name),
            "Command": "", "Created": now - spec.hoursAgo * 3_600, "State": spec.state,
            "Status": status,
            "Ports": spec.ports.map { ["PrivatePort": $0.container, "PublicPort": $0.host, "IP": $0.ip, "Type": "tcp"] },
            "Labels": composeLabels(spec), "Mounts": mounts,
            "NetworkSettings": ["Networks": networks],
        ])
    }

    private static func details(_ spec: Spec, now: Int) -> ContainerDetails {
        let started = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(now - spec.hoursAgo * 3_600)))
        var state: [String: Any] = [
            "Status": spec.state, "Running": spec.state == "running", "Paused": false, "Restarting": false,
            "OOMKilled": false, "Dead": false, "Pid": spec.state == "running" ? 1_200 + spec.name.count : 0,
            "ExitCode": 0, "Error": "", "StartedAt": started, "FinishedAt": "0001-01-01T00:00:00Z",
        ]
        if let health = spec.health {
            state["Health"] = ["Status": health, "FailingStreak": 0, "Log": [
                ["Start": started, "ExitCode": 0, "Output": spec.image.hasPrefix("postgres") ? "/var/run/postgresql:5432 - accepting connections\n" : "OK\n"],
            ]]
        }
        var portBindings: [String: Any] = [:]
        for port in spec.ports { portBindings["\(port.container)/tcp"] = [["HostIp": port.ip == "0.0.0.0" ? "" : port.ip, "HostPort": String(port.host)]] }
        var hostConfig: [String: Any] = [
            "Privileged": false, "NetworkMode": spec.network, "RestartPolicy": ["Name": spec.restartPolicy, "MaximumRetryCount": 0],
            "PortBindings": portBindings, "Binds": spec.binds.map { "\($0.source):\($0.path)" },
        ]
        if let limit = spec.memoryLimit { hostConfig["Memory"] = limit; hostConfig["NanoCpus"] = 1_000_000_000 }
        let mounts: [[String: Any]] = spec.volumes.map { ["Type": "volume", "Name": $0.name, "Source": "/var/lib/docker/volumes/\($0.name)/_data", "Destination": $0.path, "RW": true] }
            + spec.binds.map { ["Type": "bind", "Source": $0.source, "Destination": $0.path, "RW": true] }
        var networks: [String: Any] = [:]
        if spec.state == "running" {
            let gateway = spec.ip.split(separator: ".").prefix(3).joined(separator: ".") + ".1"
            networks[spec.network] = ["IPAddress": spec.ip, "Gateway": gateway, "MacAddress": "02:42:ac:14:00:0\(spec.name.count % 9)",
                                      "Aliases": spec.service.map { [$0] } ?? []]
        }
        return decode(ContainerDetails.self, [
            "Id": spec.id, "Name": "/\(spec.name)", "Created": started, "Platform": "linux",
            "RestartCount": spec.name == "shop-api-1" ? 1 : 0,
            "State": state,
            "Config": ["Env": spec.env + ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                       "Image": spec.image, "Labels": composeLabels(spec)],
            "HostConfig": hostConfig, "Mounts": mounts,
            "NetworkSettings": ["Networks": networks, "Ports": [:]],
        ])
    }

    private static func network(_ name: String, subnet: String? = nil, project: String? = nil) -> DockerNetwork {
        var object: [String: Any] = ["Id": id("net-" + name), "Name": name,
                                     "Driver": name == "host" ? "host" : name == "none" ? "null" : "bridge",
                                     "Scope": "local", "Created": "2026-10-02T09:14:00Z", "Internal": false]
        if let subnet {
            let gateway = subnet.split(separator: ".").prefix(3).joined(separator: ".") + ".1"
            object["IPAM"] = ["Config": [["Subnet": subnet, "Gateway": gateway]]]
        }
        if let project { object["Labels"] = ["com.docker.compose.project": project, "com.docker.compose.network": "default"] }
        return decode(DockerNetwork.self, object)
    }

    // MARK: Logs

    private static let nginxLog = """
        172.20.0.1 - - [22/Nov/2026:09:41:02 +0000] "GET / HTTP/1.1" 200 4127 "-" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        172.20.0.1 - - [22/Nov/2026:09:41:02 +0000] "GET /assets/app-3f9c.js HTTP/1.1" 200 81234 "http://localhost:8080/" "Mozilla/5.0"
        172.20.0.1 - - [22/Nov/2026:09:41:03 +0000] "GET /api/products?page=1 HTTP/1.1" 200 1893 "http://localhost:8080/" "Mozilla/5.0"
        172.20.0.1 - - [22/Nov/2026:09:41:07 +0000] "POST /api/cart HTTP/1.1" 201 312 "http://localhost:8080/products/42" "Mozilla/5.0"
        172.20.0.1 - - [22/Nov/2026:09:41:09 +0000] "GET /api/cart HTTP/1.1" 200 644 "http://localhost:8080/cart" "Mozilla/5.0"

        """

    private static let apiLog = """
        {"level":"info","time":"2026-11-22T09:38:12Z","msg":"server listening","port":3000}
        {"level":"info","time":"2026-11-22T09:38:12Z","msg":"connected to postgres","host":"db","pool":10}
        {"level":"info","time":"2026-11-22T09:41:03Z","msg":"GET /products","status":200,"ms":12}
        {"level":"info","time":"2026-11-22T09:41:07Z","msg":"POST /cart","status":201,"ms":34}
        {"level":"warn","time":"2026-11-22T09:41:08Z","msg":"slow query","ms":412,"query":"select * from orders where user_id = $1"}
        {"level":"info","time":"2026-11-22T09:41:09Z","msg":"GET /cart","status":200,"ms":9}

        """

    private static let postgresLog = """
        PostgreSQL init process complete; ready for start up.
        2026-11-22 06:41:00.512 UTC [1] LOG:  starting PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2) on aarch64-unknown-linux-gnu
        2026-11-22 06:41:00.513 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
        2026-11-22 06:41:00.520 UTC [1] LOG:  database system is ready to accept connections
        2026-11-22 09:36:00.104 UTC [27] LOG:  checkpoint complete: wrote 412 buffers (2.5%); write=41.2 s

        """

    private static let redisLog = """
        1:M 22 Nov 2026 06:41:01.220 * Server initialized
        1:M 22 Nov 2026 06:41:01.221 * Ready to accept connections tcp
        1:M 22 Nov 2026 09:11:02.004 * 100 changes in 300 seconds. Saving...
        1:M 22 Nov 2026 09:11:02.031 * Background saving terminated with success

        """
}
#endif
