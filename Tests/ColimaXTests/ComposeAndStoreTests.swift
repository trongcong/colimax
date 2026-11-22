import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ComposeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestSupport.tempRoot.appendingPathComponent("colimax-compose-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDiscoveryPriorityOverrideAndEnv() throws {
        for name in ["docker-compose.yml", "compose.yaml", "compose.override.yml"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        do {
            try Data("A=1".utf8).write(to: dir.appendingPathComponent(".env"))
        } catch {
            throw XCTSkip("Environment blocks creating .env files (sandbox): \(error.localizedDescription)")
        }
        let result = try XCTUnwrap(ComposeDiscovery.scan(dir))
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["compose.yaml", "compose.override.yml"])
        XCTAssertEqual(result.envFile?.lastPathComponent, ".env")
    }

    func testDiscoveryEmptyDirectory() {
        XCTAssertNil(ComposeDiscovery.scan(dir))
    }

    func testServiceNameValidation() {
        XCTAssertTrue(ComposeService.isValidServiceName("web"))
        XCTAssertTrue(ComposeService.isValidServiceName("api_v2.worker-1"))
        for bad in ["", "-x", "a;rm -rf", "$(id)", "a b", "../x"] {
            XCTAssertFalse(ComposeService.isValidServiceName(bad), bad)
        }
    }

    func testArgumentsAreArrays() {
        let project = ComposeProject(name: "shop", workingDir: "/tmp/shop dir", configFiles: ["/tmp/shop dir/compose.yaml"])
        XCTAssertEqual(ComposeService.baseArguments(project), ["compose", "--project-name", "shop", "--project-directory", "/tmp/shop dir", "--file", "/tmp/shop dir/compose.yaml"])
        XCTAssertEqual(ComposeService.ServiceCommand.rebuild.arguments("web"), ["up", "-d", "--build", "--no-deps", "--force-recreate", "web"])
        XCTAssertEqual(ComposeService.environment(socketPath: "/s.sock"), ["DOCKER_HOST": "unix:///s.sock"])
    }

    func testMissingFileFailsBeforeRunning() async {
        let project = ComposeProject(name: "gone", workingDir: dir.path, configFiles: [dir.appendingPathComponent("compose.yaml").path])
        XCTAssertEqual(ComposeService.missingFiles(project).count, 1)
        do {
            for try await _ in ComposeService.run(.up, project: project, socketPath: "/nope.sock") {}
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer exists"))
        }
    }

    func testInvalidServiceRejected() async {
        let project = ComposeProject(name: "p", workingDir: nil, configFiles: [])
        do {
            for try await _ in ComposeService.run(.restart, service: "x; rm -rf /", project: project, socketPath: "/nope.sock") {}
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid service name"))
        }
    }

    func testProjectNames() {
        XCTAssertEqual(ComposeProject.defaultName(for: URL(fileURLWithPath: "/x/My App!")), "my-app")
        XCTAssertTrue(ComposeProject.isValidName("my-app_1"))
        XCTAssertFalse(ComposeProject.isValidName("My App"))
    }
}

@MainActor
final class OperationTests: XCTestCase {
    func testSuccess() async {
        let store = OperationCenter()
        let stream = AsyncThrowingStream<String, Error> { c in
            c.yield("line 1")
            c.yield(#"time=x level=info msg="starting""#)
            c.finish()
        }
        let ok = await store.runOperation("op", stream)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.operation?.status, .succeeded)
        XCTAssertEqual(store.operation?.lines, ["line 1", "starting"])
    }

    func testFailureSetsError() async {
        let store = OperationCenter()
        let stream = AsyncThrowingStream<String, Error> { $0.finish(throwing: ShellError.failed("boom")) }
        let ok = await store.runOperation("op", stream)
        XCTAssertFalse(ok)
        XCTAssertEqual(store.operation?.status, .failed("boom"))
        XCTAssertEqual(store.errorMessage, "boom")
    }

    func testCancellationMarksCancelledNotSucceeded() async {
        let store = OperationCenter()
        let stream = AsyncThrowingStream<String, Error> { $0.yield("waiting") } // never finishes
        let task = Task { await store.runOperation("op", stream) }
        try? await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(store.operation?.status, .cancelled)
        XCTAssertNil(store.errorMessage)
    }

    func testShortcutOrderHasNineUniqueScreens() {
        XCTAssertEqual(Screen.shortcutOrder.count, 9)
        XCTAssertEqual(Set(Screen.shortcutOrder).count, 9)
        XCTAssertEqual(Screen.shortcutOrder.first, .dashboard)
    }
}

@MainActor
final class StoreDerivedTests: XCTestCase {
    private func container(_ id: String, project: String?, service: String = "web", workingDir: String? = nil, files: String? = nil) throws -> DockerContainer {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service
        }
        if let workingDir { labels["com.docker.compose.project.working_dir"] = workingDir }
        if let files { labels["com.docker.compose.project.config_files"] = files }
        let labelJSON = String(decoding: try JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]), as: UTF8.self)
        let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"Image":"busybox","Created":0,"State":"running","Status":"Up","Labels":\#(labelJSON)}"#
        return try JSONDecoder().decode(DockerContainer.self, from: Data(json.utf8))
    }

    /// Compose projects are derived from container labels (no docker CLI needed).
    func testComposeProjectsFromLabels() throws {
        let store = AppStore(settings: AppSettings())
        let a = "colimax-unit-\(UUID().uuidString.prefix(6).lowercased())"
        let b = a + "-b"
        store.containers = [
            try container("1", project: a, service: "web"),
            try container("2", project: a, service: "db", workingDir: "/srv/a", files: "/srv/a/compose.yaml, /srv/a/compose.override.yaml"),
            try container("3", project: b, service: "api", workingDir: "/srv/b"),
            try container("4", project: nil),
        ]
        let projects = store.composeModel.projects.filter { $0.name == a || $0.name == b }
        XCTAssertEqual(projects.map(\.name), [a, b])
        XCTAssertEqual(projects[0].workingDir, "/srv/a", "working_dir comes from whichever container has the label")
        XCTAssertEqual(projects[0].configFiles, ["/srv/a/compose.yaml", "/srv/a/compose.override.yaml"])
        XCTAssertEqual(projects[1].workingDir, "/srv/b")
        XCTAssertEqual(projects[1].configFiles, [])
        XCTAssertEqual(store.composeModel.containers(in: a).map(\.composeService), ["web", "db"], "sorted by container name")
        XCTAssertEqual(Set(store.composeModel.containers(in: a).map(\.id)), ["1", "2"])
        XCTAssertFalse(store.composeModel.projects.contains { $0.name.isEmpty })
    }
}
