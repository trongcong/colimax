import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class BackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestSupport.tempRoot.appendingPathComponent("colimax-bk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Minimal tar: a ustar header for the `volume/` directory plus 2 empty blocks.
    static func volumeTar(name: String = "volume/") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        for (i, byte) in name.utf8.enumerated() { header[i] = byte }
        for (i, byte) in "ustar".utf8.enumerated() { header[257 + i] = byte }
        header[156] = UInt8(ascii: "5")
        return Data(header + [UInt8](repeating: 0, count: 1024))
    }

    private func writeBackup(_ data: Data, manifest: Bool = true) async throws -> URL {
        let file = dir.appendingPathComponent("vol.tar")
        try data.write(to: file)
        if manifest {
            let hash = try await FileHasher.hash(file: file)
            try BackupManifest(kind: .volume, source: "pgdata", image: nil, createdAt: .now, fileName: "vol.tar", size: hash.size, sha256: hash.sha256)
                .write(for: file)
        }
        return file
    }

    func testManifestRoundTripAndVerify() async throws {
        let file = try await writeBackup(Self.volumeTar())
        let manifest = try XCTUnwrap(try BackupManifest.read(for: file))
        XCTAssertEqual(manifest.source, "pgdata")
        XCTAssertEqual(manifest.format, BackupManifest.currentFormat)
        guard case .verified(let verified) = try await BackupVerifier.verify(file) else { return XCTFail() }
        XCTAssertEqual(verified, manifest)
    }

    func testTamperedFileIsRejected() async throws {
        let file = try await writeBackup(Self.volumeTar())
        var data = try Data(contentsOf: file)
        data[600] ^= 0xFF
        try data.write(to: file)
        do {
            _ = try await BackupVerifier.verify(file)
            XCTFail("tampering should be detected")
        } catch let error as BackupError {
            guard case .integrity(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("SHA-256"))
        }
    }

    func testTruncatedFileIsRejected() async throws {
        let file = try await writeBackup(Self.volumeTar())
        try Self.volumeTar().prefix(700).write(to: file)
        do {
            _ = try await BackupVerifier.verify(file)
            XCTFail()
        } catch let error as BackupError {
            guard case .integrity(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("size"))
        }
    }

    func testNoManifest() async throws {
        let file = try await writeBackup(Self.volumeTar(), manifest: false)
        guard case .noManifest(let transfer) = try await BackupVerifier.verify(file) else { return XCTFail() }
        XCTAssertEqual(transfer.size, 1536)
    }

    func testCorruptManifestAndFutureFormat() async throws {
        let file = try await writeBackup(Self.volumeTar())
        var manifest = try XCTUnwrap(try BackupManifest.read(for: file))
        manifest.format = 99
        try manifest.write(for: file)
        do { _ = try await BackupVerifier.verify(file); XCTFail() } catch {}
        try Data("{not json".utf8).write(to: BackupManifest.url(for: file))
        do { _ = try await BackupVerifier.verify(file); XCTFail() } catch {
            XCTAssertTrue((error as? BackupError).map { if case .integrity = $0 { true } else { false } } ?? false)
        }
    }

    func testMissingFile() async {
        do { _ = try await BackupVerifier.verify(dir.appendingPathComponent("nope.tar")); XCTFail() } catch {}
    }

    func testTarValidation() throws {
        XCTAssertNoThrow(try TarInspector.validateVolumeHeader(Self.volumeTar().prefix(512)))
        XCTAssertNoThrow(try TarInspector.validateVolumeHeader(Self.volumeTar(name: "volume/data.txt").prefix(512)))
        XCTAssertThrowsError(try TarInspector.validateVolumeHeader(Self.volumeTar(name: "etc/passwd").prefix(512)))
        XCTAssertThrowsError(try TarInspector.validateVolumeHeader(Data(repeating: 0, count: 512)))
        XCTAssertThrowsError(try TarInspector.validateVolumeHeader(Data(repeating: 0, count: 10)))
    }

    /// Restore must verify integrity BEFORE any Docker call: a corrupted file yields a BackupError,
    /// not a socket error (proving the daemon / volume was never touched).
    func testRestoreVerifiesBeforeTouchingDocker() async throws {
        let file = try await writeBackup(Self.volumeTar())
        var data = try Data(contentsOf: file)
        data[700] ^= 0x01
        try data.write(to: file)
        let client = DockerClient(socketPath: dir.appendingPathComponent("missing.sock").path)
        do {
            try await VolumeBackup.restore(volume: "pgdata", from: file, client: client)
            XCTFail()
        } catch {
            XCTAssertTrue(error is BackupError, "\(error)")
        }

        let wrongKind = dir.appendingPathComponent("db.tar")
        try Self.volumeTar().write(to: wrongKind)
        let hash = try await FileHasher.hash(file: wrongKind)
        try BackupManifest(kind: .postgres, source: "db", image: nil, createdAt: .now, fileName: "db.tar", size: hash.size, sha256: hash.sha256).write(for: wrongKind)
        do {
            try await VolumeBackup.restore(volume: "pgdata", from: wrongKind, client: client)
            XCTFail()
        } catch {
            XCTAssertTrue(error is BackupError, "\(error)")
        }
    }

    func testDatabaseDetection() {
        let cases: [(String, DatabaseEngine?)] = [
            ("mysql:8.4", .mysql), ("mariadb", .mariadb), ("bitnami/mariadb:11", .mariadb),
            ("docker.io/library/postgres:16-alpine", .postgres), ("postgis/postgis", .postgres),
            ("redis:7-alpine", .redis), ("valkey/valkey:8", .redis),
            ("postgres@sha256:abcdef", .postgres), ("localhost:5000/team/redis:dev", .redis),
            ("nginx", nil), ("myredis-ui", nil), ("elasticsearch:8", nil),
        ]
        for (image, expected) in cases {
            XCTAssertEqual(DatabaseEngine.detect(image: image), expected, image)
        }
    }

    func testDumpScriptsAreConstantAndKeepSecretsInContainer() {
        for engine in DatabaseEngine.allCases {
            let script = engine.script
            XCTAssertFalse(script.isEmpty)
            XCTAssertFalse(script.contains("\\("), "no Swift interpolation")
            XCTAssertTrue(script.contains("set -e"))
        }
        XCTAssertTrue(DatabaseEngine.mysql.script.contains("MYSQL_PWD"), "password passed via environment, not argv")
        XCTAssertFalse(DatabaseEngine.mysql.script.contains("-p$"))
        XCTAssertEqual(DatabaseEngine.redis.fileExtension, "rdb")
        XCTAssertEqual(DatabaseEngine.postgres.fileExtension, "sql")
    }

    func testDumpValidation() {
        XCTAssertNoThrow(try DatabaseEngine.mysql.validate(head: Data("--".utf8), tail: "...\n-- Dump completed on 2026-11-19\n"))
        XCTAssertThrowsError(try DatabaseEngine.mariadb.validate(head: Data(), tail: "INSERT INTO"))
        XCTAssertNoThrow(try DatabaseEngine.postgres.validate(head: Data(), tail: "--\n-- PostgreSQL database cluster dump complete\n--\n"))
        XCTAssertThrowsError(try DatabaseEngine.postgres.validate(head: Data(), tail: "COPY public.x"))
        XCTAssertNoThrow(try DatabaseEngine.redis.validate(head: Data("REDIS0011".utf8), tail: ""))
        XCTAssertThrowsError(try DatabaseEngine.redis.validate(head: Data("ERR".utf8), tail: ""))
    }

    func testDatabaseBackupRefusesStoppedContainer() async throws {
        let container = try JSONDecoder().decode(DockerContainer.self, from: Data(#"{"Id":"a","Names":["/db"],"Image":"postgres","Created":0,"State":"exited","Status":"Exited (0)"}"#.utf8))
        let client = DockerClient(socketPath: dir.appendingPathComponent("missing.sock").path)
        do {
            try await DatabaseBackup.backup(container: container, engine: .postgres, to: dir.appendingPathComponent("x.sql"), client: client)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? BackupError, .containerNotRunning("db"))
        }
    }

    func testEdges() throws {
        let file = dir.appendingPathComponent("dump.sql")
        try Data(("HEADER" + String(repeating: "x", count: 10_000) + "-- Dump completed").utf8).write(to: file)
        let (head, tail) = try DatabaseBackup.edges(of: file)
        XCTAssertEqual(String(decoding: head.prefix(6), as: UTF8.self), "HEADER")
        XCTAssertTrue(tail.hasSuffix("-- Dump completed"))
        XCTAssertLessThanOrEqual(tail.utf8.count, 4096)
    }

    func testStaleHelperSelection() throws {
        func container(_ id: String, state: String, created: Int, labels: [String: String]) throws -> DockerContainer {
            let labelJSON = String(decoding: try JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]), as: UTF8.self)
            let json = #"{"Id":"\#(id)","Names":["/\#(id)"],"Image":"busybox","Created":\#(created),"State":"\#(state)","Status":"","Labels":\#(labelJSON)}"#
            return try JSONDecoder().decode(DockerContainer.self, from: Data(json.utf8))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = 1_800_000_000 - 3600
        let all = [
            try container("stale", state: "created", created: old, labels: [VolumeBackup.helperLabel: "volume-backup"]),
            try container("stale-test", state: "created", created: old, labels: [VolumeBackup.helperLabel: "volume-backup", "dev.colimax.test": "x"]),
            try container("fresh", state: "created", created: 1_800_000_000 - 10, labels: [VolumeBackup.helperLabel: "volume-backup"]),
            try container("running", state: "running", created: old, labels: [VolumeBackup.helperLabel: "volume-backup"]),
            try container("user", state: "created", created: old, labels: ["app": "x"]),
        ]
        XCTAssertEqual(VolumeBackup.staleHelpers(all, now: now, olderThan: 600).map(\.id), ["stale", "stale-test"])
        XCTAssertEqual(VolumeBackup.staleHelpers(all, now: now, olderThan: 600, requiredLabel: "dev.colimax.test").map(\.id), ["stale-test"])
    }

    /// G3: a finished backup replaces an existing file with mode 0600, even if the old file was 0644.
    func testBackupInstallPermissionsAfterOverwrite() throws {
        let destination = dir.appendingPathComponent("db.sql")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        let temp = dir.appendingPathComponent(".db.sql.partial-test")
        let handle = try AtomicFile.createExclusive(temp)
        try handle.write(contentsOf: Data("new dump".utf8))
        try handle.close()

        try AtomicFile.install(temp, at: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new dump")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))

        // First backup to a new path is also 0600.
        let fresh = dir.appendingPathComponent("fresh.tar")
        let temp2 = dir.appendingPathComponent(".fresh.tar.partial-test")
        try AtomicFile.createExclusive(temp2).close()
        try AtomicFile.install(temp2, at: fresh)
        let freshAttributes = try FileManager.default.attributesOfItem(atPath: fresh.path)
        XCTAssertEqual((freshAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// G7: exported log files get mode 0600, even when overwriting an existing 0644 file.
    func testLogExportPermissionsAfterOverwrite() throws {
        let file = dir.appendingPathComponent(LogExport.fileName(container: "web", at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertTrue(file.lastPathComponent.hasPrefix("web-2027-01-15"), file.lastPathComponent)
        XCTAssertTrue(file.lastPathComponent.hasSuffix(".log"))
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try LogExport.write("APP_TOKEN=secret\n", to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "APP_TOKEN=secret\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [], "no temporary files left behind")
    }
}
