import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class DockerClientTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = TestSupport.tempRoot.appendingPathComponent("colimax-dc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRequestLineAndEscaping() {
        let request = String(decoding: DockerClient.buildRequest("GET", "/x", query: ["f": "{\"a\":1}"], contentType: nil, contentLength: 0), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /x?f=%7B%22a%22%3A1%7D HTTP/1.0\r\n"))
        XCTAssertTrue(request.hasSuffix("Content-Length: 0\r\n\r\n"))
        XCTAssertEqual(DockerClient.escape("a b/c&d"), "a%20b%2Fc%26d")
        // Path traversal in an ID cannot change the endpoint.
        XCTAssertEqual(DockerClient.escape("../../info"), "..%2F..%2Finfo")
    }

    func testDechunk() {
        XCTAssertEqual(DockerClient.dechunk(Data("5\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n".utf8)), Data("helloabc".utf8))
    }

    func testHTTPErrorMapping() {
        XCTAssertThrowsError(try DockerClient.check(status: 404, body: Data(#"{"message":"No such container: x"}"#.utf8))) { error in
            guard case DockerError.http(404, "No such container: x") = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try DockerClient.check(status: 304, body: Data()))
    }

    func testSocketUnavailable() async {
        let client = DockerClient(socketPath: tempDir.appendingPathComponent("missing.sock").path)
        do {
            try await client.ping()
            XCTFail("expected an error")
        } catch DockerError.socket(let message) {
            XCTAssertTrue(message.contains("not found"), message)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNotASocket() async throws {
        let file = tempDir.appendingPathComponent("plain")
        try Data("x".utf8).write(to: file)
        let client = DockerClient(socketPath: file.path)
        do {
            _ = try await client.containers()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is DockerError, "\(error)")
        }
    }

    func testSocketPathTooLong() async {
        let client = DockerClient(socketPath: "/" + String(repeating: "a", count: 200))
        do {
            try await client.ping()
            XCTFail("expected an error")
        } catch DockerError.socket(let message) {
            XCTAssertTrue(message.contains("too long"))
        } catch {
            XCTFail("\(error)")
        }
    }

    /// A failed download must leave the existing destination file untouched and no temporary file behind.
    func testFailedDownloadKeepsExistingFileAndLeavesNoPartial() async throws {
        let destination = tempDir.appendingPathComponent("backup.tar")
        try Data("old backup".utf8).write(to: destination)
        let client = DockerClient(socketPath: tempDir.appendingPathComponent("missing.sock").path)
        do {
            _ = try await client.download("/containers/x/archive", to: destination)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old backup")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains("partial") }
        XCTAssertEqual(leftovers, [])
    }

    func testMultiplexedParserSeparatesStreamsAcrossChunks() {
        let f1: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 6] + Array("hello\n".utf8)
        let f2: [UInt8] = [2, 0, 0, 0, 0, 0, 0, 5] + Array("oops\n".utf8)
        let all = f1 + f2
        var parser = MultiplexedStreamParser()
        var frames: [MultiplexedStreamParser.Frame] = []
        for cut in stride(from: 0, to: all.count, by: 3) {
            frames += parser.feed(Data(all[cut..<min(cut + 3, all.count)]))
        }
        XCTAssertEqual(frames, [
            .init(stream: 1, payload: Data("hello\n".utf8)),
            .init(stream: 2, payload: Data("oops\n".utf8)),
        ])
        XCTAssertEqual(parser.pendingCount, 0)
    }

    func testLogDemuxer() {
        var demuxer = LogDemuxer(tty: false)
        let frame: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 3] + Array("ab\n".utf8)
        XCTAssertEqual(demuxer.feed(Data(frame)), "ab\n")
        var tty = LogDemuxer(tty: true)
        XCTAssertEqual(tty.feed(Data("raw\n".utf8)), "raw\n")
    }

    func testLineSplitter() {
        let splitter = LineSplitter()
        var lines = splitter.feed(Data("a\r\nb".utf8))
        lines += splitter.feed(Data("c\n".utf8))
        XCTAssertEqual(lines, ["a", "bc"])
        XCTAssertEqual(splitter.flush(), [])
    }

    func testFileHasherKnownVector() async throws {
        let file = tempDir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        let result = try await FileHasher.hash(file: file)
        XCTAssertEqual(result.size, 3)
        XCTAssertEqual(result.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPruneFilters() {
        XCTAssertNil(DockerClient.pruneFilters())
        XCTAssertEqual(DockerClient.pruneFilters(all: true), #"{"all":["true"]}"#)
        XCTAssertEqual(DockerClient.pruneFilters(all: true, label: "dev.colimax.test=abc"),
                       #"{"all":["true"],"label":["dev.colimax.test=abc"]}"#)
        XCTAssertEqual(DockerClient.pruneFilters(label: "dev.colimax.test"), #"{"label":["dev.colimax.test"]}"#)
        XCTAssertNil(DockerClient.pruneFilters(label: ""), "an empty label must not turn into a global prune with a bogus filter")
    }
}
