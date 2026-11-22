import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class TopologyTests: XCTestCase {
    private func container(_ id: String, _ name: String, state: String = "running", networks: [String], project: String? = nil) throws -> DockerContainer {
        var labels: [String: String] = [:]
        if let project { labels["com.docker.compose.project"] = project }
        let nets = Dictionary(uniqueKeysWithValues: networks.map { ($0, ["IPAddress": "10.0.0.2"]) })
        let object: [String: Any] = [
            "Id": id, "Names": ["/\(name)"], "Image": "busybox", "Created": 0, "State": state, "Status": "",
            "Labels": labels, "NetworkSettings": ["Networks": nets],
        ]
        return try JSONDecoder().decode(DockerContainer.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func network(_ name: String) throws -> DockerNetwork {
        let object: [String: Any] = ["Id": name + "-id", "Name": name, "Driver": "bridge", "Scope": "local"]
        return try JSONDecoder().decode(DockerNetwork.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testNetworkTopology() throws {
        let containers = [
            try container("1", "web", networks: ["app_default", "proxy"], project: "app"),
            try container("2", "db", networks: ["app_default"], project: "app"),
            try container("3", "old", state: "exited", networks: ["legacy"]),
        ]
        let networks = try ["bridge", "host", "none", "app_default", "proxy", "legacy", "empty"].map(network)
        let running = NetworkTopology.build(containers: containers, networks: networks, includeStopped: false)
        XCTAssertEqual(running.containers.map(\.name), ["db", "web"])
        XCTAssertEqual(running.networks, ["app_default", "empty", "legacy", "proxy"], "unused default networks are hidden")
        XCTAssertEqual(running.edges.count, 3)
        let all = NetworkTopology.build(containers: containers, networks: networks, includeStopped: true)
        XCTAssertTrue(all.edges.contains(.init(network: "legacy", container: "3")))
    }

    func testComposeDependencyParsingBothForms() throws {
        let json = """
        {"services":{
          "web":{"depends_on":{"api":{"condition":"service_healthy"},"ghost":{}}},
          "api":{"depends_on":["db","cache"]},
          "db":{}, "cache":{}
        }}
        """
        let graph = try ComposeDependencyGraph.parse(configJSON: Data(json.utf8))
        XCTAssertEqual(graph.dependencies["web"], ["api"], "unknown services are dropped")
        XCTAssertEqual(graph.dependencies["api"], ["cache", "db"])
        XCTAssertEqual(graph.levels(), ["db": 0, "cache": 0, "api": 1, "web": 2])
        XCTAssertFalse(graph.hasCycle)
    }

    func testCycleDoesNotHang() {
        let graph = ComposeDependencyGraph(dependencies: ["a": ["b"], "b": ["a"], "c": []])
        XCTAssertTrue(graph.hasCycle)
        XCTAssertEqual(graph.levels().count, 3)
    }
}
