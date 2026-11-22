import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ElasticsearchTests: XCTestCase {
    func testDetect() {
        XCTAssertTrue(ElasticsearchSnapshot.detect(image: "docker.elastic.co/elasticsearch/elasticsearch:8.15.0"))
        XCTAssertTrue(ElasticsearchSnapshot.detect(image: "opensearchproject/opensearch:2"))
        XCTAssertTrue(ElasticsearchSnapshot.detect(image: "elasticsearch@sha256:abc"))
        XCTAssertFalse(ElasticsearchSnapshot.detect(image: "kibana:8"))
    }

    func testNames() {
        XCTAssertTrue(ElasticsearchSnapshot.isValidName("snapshot-20261119-101010"))
        XCTAssertFalse(ElasticsearchSnapshot.isValidName("Snap"))
        XCTAssertFalse(ElasticsearchSnapshot.isValidName("a/b"))
        XCTAssertFalse(ElasticsearchSnapshot.isValidName("_all"))
        XCTAssertTrue(ElasticsearchSnapshot.isValidName(ElasticsearchSnapshot.defaultName()))
    }

    func testParseResponse() {
        XCTAssertEqual(ElasticsearchSnapshot.parseResponse("{\"a\":1}\n200")?.status, 200)
        XCTAssertEqual(ElasticsearchSnapshot.parseResponse("{\"a\":1}\n200")?.body, "{\"a\":1}")
        XCTAssertEqual(ElasticsearchSnapshot.parseResponse("404")?.status, 404)
        XCTAssertNil(ElasticsearchSnapshot.parseResponse("garbage\nnot-a-code"))
    }

    func testParsePathRepo() {
        let array = #"{"nodes":{"n1":{"settings":{"path":{"repo":["/snapshots","/b"]}}}}}"#
        XCTAssertEqual(ElasticsearchSnapshot.parsePathRepo(array), ["/b", "/snapshots"])
        let string = #"{"nodes":{"n1":{"settings":{"path":{"repo":"/snapshots"}}}}}"#
        XCTAssertEqual(ElasticsearchSnapshot.parsePathRepo(string), ["/snapshots"])
        XCTAssertEqual(ElasticsearchSnapshot.parsePathRepo("{}"), [])
        XCTAssertEqual(ElasticsearchSnapshot.parsePathRepo(#"{"nodes":{"n":{"settings":{"path":{"repo":["relative"]}}}}}"#), [])
    }

    func testParseSnapshots() throws {
        let body = """
        {"snapshots":[
          {"snapshot":"old","state":"SUCCESS","indices":["logs",".kibana"],"start_time_in_millis":1000},
          {"snapshot":"new","state":"PARTIAL","indices":["b","a"],"start_time_in_millis":5000}
        ]}
        """
        let items = try ElasticsearchSnapshot.parseSnapshots(body)
        XCTAssertEqual(items.map(\.name), ["new", "old"])
        XCTAssertEqual(items.first?.indices, ["a", "b"])
        XCTAssertEqual(ElasticsearchSnapshot.userIndices(items[1].indices), ["logs"])
    }

    func testRestoreBody() throws {
        let snapshot = ElasticsearchSnapshot.Snapshot(name: "s", state: "SUCCESS", indices: ["logs", ".sys", "app"], start: nil)
        let renamed = try ElasticsearchSnapshot.restoreBody(snapshot, mode: .renamed)
        XCTAssertTrue(renamed.contains(#""indices":"logs,app""#) || renamed.contains(#""indices":"app,logs""#))
        XCTAssertTrue(renamed.contains("restored-$1"))
        XCTAssertFalse(try ElasticsearchSnapshot.restoreBody(snapshot, mode: .replace).contains("rename_pattern"))
    }

    func testErrorReason() {
        XCTAssertEqual(ElasticsearchSnapshot.errorReason(#"{"error":{"reason":"repository missing"},"status":404}"#), "repository missing")
        XCTAssertEqual(ElasticsearchSnapshot.errorReason("plain"), "plain")
    }
}
