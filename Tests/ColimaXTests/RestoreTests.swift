import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class RestoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestSupport.tempRoot.appendingPathComponent("colimax-rs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: TarWriter

    func testTarHeaderFieldsAndChecksum() throws {
        let header = try TarWriter.header(name: "dump.rdb", size: 1234, mode: 0o644, mtime: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(header.count, 512)
        let bytes = [UInt8](header)
        XCTAssertEqual(String(decoding: bytes[0..<8], as: UTF8.self), "dump.rdb")
        XCTAssertEqual(String(decoding: bytes[124..<135], as: UTF8.self), String(1234, radix: 8).leftPadded(11))
        XCTAssertEqual(String(decoding: bytes[257..<262], as: UTF8.self), "ustar")
        XCTAssertEqual(bytes[156], UInt8(ascii: "0"))
        // Checksum: byte sum with the checksum field itself counted as 8 spaces.
        var copy = bytes
        for i in 148..<156 { copy[i] = 0x20 }
        let expected = copy.reduce(0) { $0 + Int($1) }
        let stored = Int(String(decoding: bytes[148..<154], as: UTF8.self), radix: 8)
        XCTAssertEqual(stored, expected)
    }

    func testTarSizes() {
        XCTAssertEqual(TarWriter.paddedSize(0), 0)
        XCTAssertEqual(TarWriter.paddedSize(1), 512)
        XCTAssertEqual(TarWriter.paddedSize(512), 512)
        XCTAssertEqual(TarWriter.archiveSize(contentSize: 513), 512 + 1024 + 1024)
    }

    func testTarRejectsUnsafeNames() {
        for name in ["../etc/passwd", "a/b", "", ".hidden", "x y"] {
            XCTAssertThrowsError(try TarWriter.header(name: name, size: 1), name)
        }
        XCTAssertThrowsError(try TarWriter.header(name: "ok", size: TarWriter.maxSize + 1))
    }

    // MARK: Redis config / warnings

    func testParseRedisConfig() throws {
        let config = try DatabaseRestore.parseRedisConfig("dir\n/data\ndbfilename\ndump.rdb\nappendonly\nno\n")
        XCTAssertEqual(config, .init(dir: "/data", dbfilename: "dump.rdb", appendOnly: false))
        XCTAssertTrue(try DatabaseRestore.parseRedisConfig("dir\n/data\ndbfilename\ndump.rdb\nappendonly\nyes").appendOnly)
        XCTAssertThrowsError(try DatabaseRestore.parseRedisConfig("dir\nrelative\ndbfilename\ndump.rdb"))
        XCTAssertThrowsError(try DatabaseRestore.parseRedisConfig("dir\n/data\ndbfilename\n../x"))
    }

    func testWarningsIgnoreExpectedPsqlErrors() {
        let output = """
        psql:/tmp/x:14: ERROR:  role "postgres" already exists
        psql:/tmp/x:20: ERROR:  current user cannot be dropped
        psql:/tmp/x:99: ERROR:  relation "t" does not exist
        NOTICE: something
        """
        XCTAssertEqual(DatabaseRestore.warnings(in: output), [#"psql:/tmp/x:99: ERROR:  relation "t" does not exist"#])
    }

    func testScriptsAreConstantAndCleanUp() {
        for engine in [DatabaseEngine.mysql, .mariadb, .postgres] {
            let script = try! XCTUnwrap(DatabaseRestore.script(engine))
            XCTAssertTrue(script.contains("trap 'rm -f \"$F\"' EXIT"))
            XCTAssertTrue(script.contains(DatabaseRestore.stagingName))
        }
        XCTAssertNil(DatabaseRestore.script(.redis))
    }

    // MARK: Preflight

    private func dump(_ text: String, name: String, kind: BackupManifest.Kind?) async throws -> URL {
        let file = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        if let kind {
            let hash = try await FileHasher.hash(file: file)
            try BackupManifest(kind: kind, source: "db", image: nil, createdAt: .now, fileName: name, size: hash.size, sha256: hash.sha256).write(for: file)
        }
        return file
    }

    func testPreflightAcceptsMatchingDump() async throws {
        let file = try await dump("CREATE TABLE t;\n-- Dump completed on 2026-11-19\n", name: "a.sql", kind: .mariadb)
        guard case .verified = try await DatabaseRestore.preflight(file, engine: .mysql) else { return XCTFail("mysql and mariadb dumps are compatible") }
    }

    func testPreflightRejectsWrongEngine() async throws {
        let file = try await dump("-- PostgreSQL database cluster dump complete\n", name: "b.sql", kind: .postgres)
        do {
            _ = try await DatabaseRestore.preflight(file, engine: .mysql)
            XCTFail()
        } catch let error as BackupError {
            guard case .invalidArchive = error else { return XCTFail("\(error)") }
        }
    }

    func testPreflightRejectsTruncatedDumpWithoutManifest() async throws {
        let file = try await dump("CREATE TABLE t;\nINSERT", name: "c.sql", kind: nil)
        do {
            _ = try await DatabaseRestore.preflight(file, engine: .mysql)
            XCTFail()
        } catch let error as BackupError {
            guard case .incompleteDump = error else { return XCTFail("\(error)") }
        }
    }
}

private extension String {
    func leftPadded(_ length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}
