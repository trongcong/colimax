import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// Backup, restore, proxy and scheduled-backup services against `FakeDocker`: the file / archive
/// transfer path without a VM. Integration tests still cover the real Docker behavior.
final class TransferFakeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = TestSupport.tempRoot.appendingPathComponent("colimax-fake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func postgres(_ docker: FakeDocker) -> DockerContainer {
        let container = FakeDocker.container("c-pg", name: "pg", image: "postgres:16")
        docker.state.withLock { $0.containers.append(container) }
        return container
    }

    // MARK: - Volumes

    func testVolumeBackupRestoreRoundTripThroughHelpers() async throws {
        let docker = FakeDocker(images: [FakeDocker.image("sha256:bb", tag: VolumeBackup.helperImage)], volumes: [FakeDocker.volume("data")])
        let archive = FakeDocker.tar([("volume/hello.txt", Data("hello\n".utf8))])
        docker.state.withLock { $0.volumeArchives["data"] = archive }

        let file = directory.appendingPathComponent("data.tar")
        let manifest = try await VolumeBackup.backup(volume: "data", to: file, client: docker)
        XCTAssertEqual(try Data(contentsOf: file), archive)
        XCTAssertEqual(manifest.size, Int64(archive.count))
        XCTAssertTrue(docker.state.current.containers.isEmpty, "the helper container is removed")

        let verification = try await VolumeBackup.restore(volume: "copy", from: file, client: docker)
        guard case .verified = verification else { return XCTFail("manifest should verify: \(verification)") }
        XCTAssertEqual(docker.state.current.volumeArchives["copy"], archive)
        XCTAssertTrue(docker.state.current.volumes.contains { $0.name == "copy" }, "missing volume is created")
        XCTAssertTrue(docker.state.current.containers.isEmpty)
    }

    func testVolumeRestoreRejectsTamperedFileBeforeTouchingDocker() async throws {
        let docker = FakeDocker(images: [FakeDocker.image("sha256:bb", tag: VolumeBackup.helperImage)], volumes: [FakeDocker.volume("data")])
        docker.state.withLock { $0.volumeArchives["data"] = FakeDocker.tar([("volume/a", Data("a".utf8))]) }
        let file = directory.appendingPathComponent("data.tar")
        try await VolumeBackup.backup(volume: "data", to: file, client: docker)
        let callsAfterBackup = docker.calls

        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: file)

        do {
            try await VolumeBackup.restore(volume: "data", from: file, client: docker)
            XCTFail("tampered backup must be rejected")
        } catch {}
        XCTAssertEqual(docker.calls, callsAfterBackup, "nothing is sent to Docker")
    }

    func testFailedDownloadRemovesHelperAndKeepsExistingFile() async throws {
        let docker = FakeDocker(images: [FakeDocker.image("sha256:bb", tag: VolumeBackup.helperImage)], volumes: [FakeDocker.volume("data")])
        docker.fail("downloadArchive", "connection reset")
        let file = directory.appendingPathComponent("data.tar")
        try Data("previous backup".utf8).write(to: file)
        do {
            try await VolumeBackup.backup(volume: "data", to: file, client: docker)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "connection reset")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "previous backup")
        XCTAssertTrue(docker.state.current.containers.isEmpty, "helper removed after a failure")
    }

    func testStaleHelperCleanupOnlyRemovesOldUnstartedHelpers() async {
        let old = FakeDocker.container("h1", name: "h1", image: VolumeBackup.helperImage, state: "created",
                                       labels: [VolumeBackup.helperLabel: "volume-backup"])
        let user = FakeDocker.container("u1", name: "app", state: "created")
        let docker = FakeDocker(containers: [old, user])
        let removed = await VolumeBackup.cleanupStaleHelpers(client: docker)
        XCTAssertEqual(removed, ["h1"])
        XCTAssertEqual(docker.state.current.containers.map(\.id), ["u1"])
    }

    // MARK: - Databases

    func testDatabaseDumpWritesFileAndManifest() async throws {
        let docker = FakeDocker()
        let container = postgres(docker)
        let dump = "-- dump\nCREATE TABLE t();\n--\n-- PostgreSQL database cluster dump complete\n--\n"
        docker.state.withLock { $0.execHandler = { _, _ in (Data(dump.utf8), Data(), 0) } }
        let file = directory.appendingPathComponent("pg.sql")
        let manifest = try await DatabaseBackup.backup(container: container, engine: .postgres, to: file, client: docker)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), dump)
        XCTAssertEqual(manifest.kind, .postgres)
        XCTAssertNoThrow(try BackupManifest.read(for: file))
    }

    func testDatabaseDumpFailureDeletesFileAndReportsStderr() async throws {
        let docker = FakeDocker()
        let container = postgres(docker)
        docker.state.withLock { $0.execHandler = { _, _ in (Data("partial".utf8), Data("pg_dumpall: permission denied".utf8), 1) } }
        let file = directory.appendingPathComponent("pg.sql")
        do {
            try await DatabaseBackup.backup(container: container, engine: .postgres, to: file, client: docker)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission denied"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDatabaseRestoreStagesFileThenRunsClient() async throws {
        let docker = FakeDocker()
        let container = postgres(docker)
        let dump = "SELECT 1;\n--\n-- PostgreSQL database cluster dump complete\n--\n"
        docker.state.withLock { $0.execHandler = { _, _ in (Data(dump.utf8), Data(), 0) } }
        let file = directory.appendingPathComponent("pg.sql")
        try await DatabaseBackup.backup(container: container, engine: .postgres, to: file, client: docker)

        docker.state.withLock { $0.execHandler = { _, _ in (Data(), Data(), 0) } }
        let outcome = try await DatabaseRestore.restore(file: file, into: container, engine: .postgres, client: docker)
        XCTAssertTrue(outcome.warnings.isEmpty)
        let staged = "c-pg:\(DatabaseRestore.stagingDirectory)/\(DatabaseRestore.stagingName)"
        XCTAssertEqual(docker.state.current.uploads[staged], Data(dump.utf8), "the dump is copied into the container")
        XCTAssertTrue(docker.calls.contains { $0.hasPrefix("exec c-pg sh -c") }, "the client runs inside the container")
    }

    // MARK: - Scheduled backups

    func testScheduledVolumeBackupWritesNamedFile() async throws {
        let docker = FakeDocker(images: [FakeDocker.image("sha256:bb", tag: VolumeBackup.helperImage)], volumes: [FakeDocker.volume("data")])
        let schedule = BackupSchedule(profile: "default", target: .volume(name: "data"), interval: .daily,
                                      directory: directory.path, keep: 3)
        let file = try await ScheduledBackupRunner.run(schedule, client: docker, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(file.lastPathComponent.hasPrefix("data-20231114-"), file.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testScheduledDatabaseBackupFailsWhenContainerMissing() async {
        let docker = FakeDocker()
        let schedule = BackupSchedule(profile: "default", target: .database(container: "gone", engine: "postgres"),
                                      interval: .daily, directory: directory.path, keep: 3)
        do {
            _ = try await ScheduledBackupRunner.run(schedule, client: docker, at: .now)
            XCTFail("expected failure")
        } catch {}
    }

    // MARK: - Local proxy

    func testProxyCreateWritesCaddyfileBeforeStarting() async throws {
        // LocalProxy stages the Caddyfile in the system temporary directory (blocked in some sandboxes).
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("colimax-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw XCTSkip("system temporary directory is not writable here")
        }
        try? FileManager.default.removeItem(at: probe)
        let docker = FakeDocker(images: [FakeDocker.image("sha256:cc", tag: LocalProxy.image)])
        docker.state.withLock { $0.execHandler = { _, _ in (Data(), Data(), 0) } }
        let id = try await LocalProxy.create(settings: ProxySettings(), client: docker)
        let calls = docker.calls
        let upload = try XCTUnwrap(calls.firstIndex { $0 == "upload \(id):\(LocalProxy.caddyfilePath)/Caddyfile" })
        let start = try XCTUnwrap(calls.firstIndex { $0 == "action \(id) start" })
        XCTAssertLessThan(upload, start, "the app's Caddyfile is in place before Caddy starts")
        let status = try await LocalProxy.status(client: docker)
        XCTAssertEqual(status, .init(exists: true, running: true, id: id))
    }
}
